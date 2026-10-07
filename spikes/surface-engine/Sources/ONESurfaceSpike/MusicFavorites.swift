import AppKit
import CoreServices
import SwiftUI

struct MusicFavoriteTarget: Equatable, Sendable {
    let processID: pid_t
    let title: String
    let artist: String

    init?(snapshot: AmbientMediaSnapshot, processID: pid_t) {
        guard snapshot.sourceBundleIdentifier == "com.apple.Music",
              snapshot.hasTrackMetadata, !snapshot.metadataIsRetained,
              snapshot.state == .playing || snapshot.state == .paused,
              processID > 0 else { return nil }
        let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        self.processID = processID
        self.title = title
        artist = snapshot.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum MusicFavoriteReply: Sendable {
    case confirmed(id: String, saved: Bool)
    case needsPermission
    case failed(String)
}

struct MusicFavoriteOperation: Sendable {
    let target: MusicFavoriteTarget
    let expectedID: String?
    let saving: Bool
    let generation: UInt
}

/// Writes and late replies belong to a specific displayed track, never raw audio.
struct MusicFavoriteState {
    private(set) var target: MusicFavoriteTarget?
    private(set) var saved: Bool?
    private(set) var trackID: String?
    private(set) var busy = false
    private(set) var diagnostic: String?
    private var generation: UInt = 0

    mutating func present(_ value: MusicFavoriteTarget?) {
        generation &+= 1
        target = value
        saved = nil; trackID = nil; busy = false; diagnostic = nil
    }

    mutating func begin(saving: Bool) -> MusicFavoriteOperation? {
        guard let target, !busy, !saving || saved != true else { return nil }
        generation &+= 1
        busy = true; diagnostic = nil
        return MusicFavoriteOperation(target: target, expectedID: trackID,
            saving: saving, generation: generation)
    }

    mutating func receive(_ reply: MusicFavoriteReply, for operation: MusicFavoriteOperation) {
        guard generation == operation.generation, target == operation.target else { return }
        busy = false
        switch reply {
        case let .confirmed(id, value):
            guard !id.isEmpty, !operation.saving || value else {
                saved = nil; trackID = nil
                diagnostic = "Music не подтвердил сохранение трека"
                return
            }
            trackID = id; saved = value
        case .needsPermission:
            saved = nil; trackID = nil
        case let .failed(message):
            saved = nil; trackID = nil; diagnostic = message
        }
    }
}

@MainActor final class MusicFavoritesController: ObservableObject {
    @Published private(set) var state = MusicFavoriteState()

    func present(_ target: MusicFavoriteTarget?, active: Bool) {
        state.present(active ? target : nil)
        if state.target != nil { perform(saving: false) }
    }

    func save() { perform(saving: true) }

    private func perform(saving: Bool) {
        guard let operation = state.begin(saving: saving) else { return }
        MusicFavoriteWorker.queue.async { [weak self] in
            let reply = MusicFavoriteWorker.perform(operation)
            Task { @MainActor [weak self] in self?.state.receive(reply, for: operation) }
        }
    }
}

/// Public, fixed Apple Events to the already-running Music PID. No script/shell,
/// provider login, network, or automatic permission prompt on a background read.
private enum MusicFavoriteWorker {
    static let queue = DispatchQueue(label: "local.one.music-favorites", qos: .userInitiated)

    private struct Failure: Error { let message: String }

    static func perform(_ operation: MusicFavoriteOperation) -> MusicFavoriteReply {
        guard NSRunningApplication(processIdentifier: operation.target.processID)?.bundleIdentifier == "com.apple.Music"
        else { return .failed("Music сейчас недоступен") }
        let address = NSAppleEventDescriptor(processIdentifier: operation.target.processID)
        let permission = AEDeterminePermissionToAutomateTarget(address.aeDesc,
            AEEventClass(typeWildCard), AEEventID(typeWildCard), operation.saving)
        if permission == errAEEventWouldRequireUserConsent { return .needsPermission }
        guard permission == noErr else {
            return .failed(permission == errAEEventNotPermitted
                ? "Разрешите SPIKE управлять Music в настройках macOS → Автоматизация"
                : "Music сейчас недоступен")
        }
        do {
            let track = try get(property(code("pTrk")), address: address)
            guard track.descriptorType == typeObjectSpecifier else {
                throw Failure(message: "Этот источник Music не поддерживает избранное")
            }
            let id = try get(property(code("pPIS"), of: track), address: address).stringValue ?? ""
            let title = try get(property(code("pnam"), of: track), address: address).stringValue ?? ""
            let artist = try get(property(code("pArt"), of: track), address: address).stringValue ?? ""
            guard !id.isEmpty, title.trimmingCharacters(in: .whitespacesAndNewlines) == operation.target.title,
                  operation.target.artist.isEmpty || artist.trimmingCharacters(in: .whitespacesAndNewlines) == operation.target.artist,
                  operation.expectedID == nil || operation.expectedID == id else {
                throw Failure(message: "Трек сменился — откройте SPIKE снова")
            }
            let favorite = try property(code("pLov"), of: track)
            var saved = try boolean(get(favorite, address: address))
            if operation.saving && !saved {
                // Revalidate immediately before writing, then use the resolved
                // track object, never the dynamic 'current track' as write target.
                let current = try get(property(code("pTrk")), address: address)
                let currentID = try get(property(code("pPIS"), of: current), address: address).stringValue
                guard currentID == id else { throw Failure(message: "Трек сменился — попробуйте снова") }
                _ = try send(kAESetData, direct: favorite, value: .init(boolean: true), address: address)
                saved = try boolean(get(favorite, address: address))
            }
            return .confirmed(id: id, saved: saved)
        } catch let error as Failure { return .failed(error.message) }
        catch {
            return .failed((error as NSError).code == errAETimeout
                ? "Music не ответил вовремя — попробуйте снова"
                : "Не удалось получить или сохранить избранное в Music")
        }
    }

    private static func code(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private static func property(_ id: OSType, of container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(typeCode: id), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw Failure(message: "Не удалось обратиться к треку Music")
        }
        return result
    }

    private static func get(_ direct: NSAppleEventDescriptor, address: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send(kAEGetData, direct: direct, address: address)
    }

    private static func boolean(_ descriptor: NSAppleEventDescriptor) throws -> Bool {
        guard let result = descriptor.coerce(toDescriptorType: typeBoolean) else {
            throw Failure(message: "Этот трек Music не поддерживает избранное")
        }
        return result.booleanValue
    }

    private static func send(_ id: AEEventID, direct: NSAppleEventDescriptor,
                             value: NSAppleEventDescriptor? = nil,
                             address: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kAECoreSuite,
            eventID: id, targetDescriptor: address, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: keyDirectObject)
        if let value { event.setParam(value, forKeyword: keyAEData) }
        let options = NSAppleEventDescriptor.SendOptions(rawValue:
            UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent))
        let reply = try event.sendEvent(options: options, timeout: 3)
        let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
        guard error == 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(error)) }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    static func checkDescriptors() {
        // Check Foundation's real object-specifier coercion, without sending an event.
        let current = try! property(code("pTrk"))
        let favorite = try! property(code("pLov"), of: current)
        precondition(current.descriptorType == typeObjectSpecifier)
        precondition(favorite.descriptorType == typeObjectSpecifier)
        precondition(try! boolean(.init(boolean: true)))
        precondition(try! !boolean(.init(boolean: false)))
    }
}

struct MusicFavoriteButton: View {
    @ObservedObject var controller: MusicFavoritesController
    let target: MusicFavoriteTarget
    let active: Bool
    @Environment(\.surfaceAppearance) private var appearance

    var body: some View {
        HStack(spacing: 0) {
            if controller.state.saved == true {
                Image(systemName: "star.fill")
                    .foregroundStyle(appearance.primary)
                    .surfaceInkLegibility()
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("В избранном Apple Music")
            } else {
                Button(action: controller.save) {
                    Image(systemName: "star")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SurfaceButtonStyle())
                .disabled(controller.state.busy || !active)
                .accessibilityLabel("Добавить в избранное Apple Music")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .help(controller.state.diagnostic ?? (controller.state.saved == true
            ? "В избранном Apple Music" : "Добавить в избранное Apple Music"))
        .accessibilityValue(controller.state.busy ? "Проверяю Music" : controller.state.diagnostic ?? "")
        .onAppear { controller.present(target, active: active) }
        .onChange(of: target) { _, value in controller.present(value, active: active) }
        .onChange(of: active) { _, value in controller.present(target, active: value) }
        .onDisappear { controller.present(nil, active: false) }
    }
}

struct MusicFavoriteDiagnostic: View {
    @ObservedObject var controller: MusicFavoritesController
    @Environment(\.surfaceAppearance) private var appearance

    var body: some View {
        if let message = controller.state.diagnostic {
            Text(message).font(.system(size: 9)).foregroundStyle(appearance.secondary).surfaceInkLegibility()
        }
    }
}

func checkMusicFavorites() {
    MusicFavoriteWorker.checkDescriptors()
    var snapshot = AmbientMediaSnapshot(state: .playing, title: "Track", subtitle: "Artist",
        sourceName: "Music", artwork: nil, sourceBundleIdentifier: "com.apple.Music", hasTrackMetadata: true)
    let target = MusicFavoriteTarget(snapshot: snapshot, processID: 123)!
    snapshot.sourceBundleIdentifier = "com.spotify.client"
    precondition(MusicFavoriteTarget(snapshot: snapshot, processID: 123) == nil)
    snapshot.sourceBundleIdentifier = "com.apple.Music"; snapshot.metadataIsRetained = true
    precondition(MusicFavoriteTarget(snapshot: snapshot, processID: 123) == nil)
    snapshot.metadataIsRetained = false; snapshot.hasTrackMetadata = false
    precondition(MusicFavoriteTarget(snapshot: snapshot, processID: 123) == nil)
    snapshot.hasTrackMetadata = true; snapshot.state = .audioActive
    precondition(MusicFavoriteTarget(snapshot: snapshot, processID: 123) == nil)
    snapshot.state = .paused
    precondition(MusicFavoriteTarget(snapshot: snapshot, processID: 123) != nil)

    var state = MusicFavoriteState()
    state.present(target)
    let read = state.begin(saving: false)!
    state.receive(.needsPermission, for: read)
    precondition(state.saved == nil && !state.busy && state.diagnostic == nil)
    let save = state.begin(saving: true)!
    state.receive(.confirmed(id: "AAA", saved: false), for: save)
    precondition(state.saved == nil && state.diagnostic != nil)
    let retry = state.begin(saving: true)!
    state.receive(.confirmed(id: "AAA", saved: true), for: retry)
    precondition(state.saved == true && state.trackID == "AAA" && state.begin(saving: true) == nil)
    let late = state.begin(saving: false)!
    state.present(nil)
    state.receive(.confirmed(id: "OLD", saved: true), for: late)
    precondition(state.target == nil && state.saved == nil && !state.busy)
    state.present(target)
    let failed = state.begin(saving: true)!
    state.receive(.failed("Permission denied"), for: failed)
    precondition(state.saved == nil && !state.busy && state.diagnostic != nil)
    print("Music favorite checks passed: native object descriptors, Music-only gating, pause/retained/raw guards, permission, confirmed read-back, stale reply and denial. No Apple Events sent or library writes.")
}
