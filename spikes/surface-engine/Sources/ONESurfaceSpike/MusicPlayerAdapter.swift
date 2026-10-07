import AppKit
import CoreServices

/// Independent, public Apple Events for the two installed music players. No
/// background permission prompts, scripts, artwork downloads or app launches.
@MainActor final class MusicPlayerAdapter {
    var onSnapshots: (([AmbientMediaSnapshot]) -> Void)?
    var onDiagnostic: ((String?) -> Void)?
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private let queue = DispatchQueue(label: "local.one.music-player", qos: .utility)

    func start() {
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { @Sendable [weak self] in
            let result = MusicPlayerEvents.readPlayers()
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onSnapshots?(result.snapshots.map(\.snapshot))
                self.onDiagnostic?(result.diagnostic)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        generation += 1
        timer?.cancel(); timer = nil
        onSnapshots?([])
    }

    func requestPermissions() {
        queue.async {
            for player in MusicPlayerEvents.Player.allCases {
                guard let process = MusicPlayerEvents.running(player) else { continue }
                let address = NSAppleEventDescriptor(processIdentifier: process.processIdentifier)
                _ = AEDeterminePermissionToAutomateTarget(address.aeDesc,
                    AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
            }
        }
    }

    func send(_ command: MusicPlayerEvents.Command, target: AmbientMediaSnapshot) {
        guard let source = target.sourceBundleIdentifier,
              let player = MusicPlayerEvents.Player(rawValue: source),
              let process = MusicPlayerEvents.running(player),
              let id = target.trackIdentifier else { return }
        let pid = process.processIdentifier
        queue.async { [weak self] in
            do {
                try MusicPlayerEvents.send(command, player: player, pid: pid, expectedTrackID: id)
            } catch {
                Task { @MainActor [weak self] in self?.onDiagnostic?("Плеер не принял команду — попробуйте снова") }
            }
        }
    }
}

enum MusicPlayerEvents {
    enum Player: String, CaseIterable, Sendable {
        case spotify = "com.spotify.client"
        case music = "com.apple.Music"
        var name: String { self == .spotify ? "Spotify" : "Music" }
        var commandClass: OSType { code(self == .spotify ? "spfy" : "hook") }
        var idProperty: OSType { code(self == .spotify ? "ID  " : "pPIS") }
    }
    enum Command: String, Sendable { case toggle = "PlPs", next = "Next", previous = "Prev" }
    struct Track: Sendable {
        let player: Player
        let id: String
        let title: String
        let artist: String
        let playing: Bool
        let readAt: TimeInterval
        @MainActor var snapshot: AmbientMediaSnapshot {
            AmbientMediaSnapshot(state: playing ? .playing : .paused, title: title,
                subtitle: artist, sourceName: player.name, artwork: nil,
                sourceBundleIdentifier: player.rawValue, hasTrackMetadata: true,
                canSkip: true, trackIdentifier: id, isMusicSource: true,
                independentlyRead: true, independentReadAt: readAt)
        }
    }
    struct Reading: Sendable { var snapshots: [Track] = []; var diagnostic: String? }

    static func running(_ player: Player) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first
    }

    static func readPlayers() -> Reading {
        var result = Reading()
        for player in Player.allCases {
            guard let process = running(player) else { continue }
            do {
                if let track = try read(player, pid: process.processIdentifier) { result.snapshots.append(track) }
            } catch {
                let error = error as NSError
                result.diagnostic = error.code == errAEEventNotPermitted || error.code == errAEEventWouldRequireUserConsent
                    ? "Для независимого приоритета музыки: ПКМ → Разрешить Spotify и Music…"
                    : "Не удалось обновить \(player.name); используются системные данные"
            }
        }
        return result
    }

    static func read(_ player: Player, pid: pid_t) throws -> Track? {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == player.rawValue else { return nil }
        let address = NSAppleEventDescriptor(processIdentifier: pid)
        let permission = AEDeterminePermissionToAutomateTarget(address.aeDesc,
            AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        guard permission == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(permission)) }
        let readAt = ProcessInfo.processInfo.systemUptime
        let state = try get(property(code("pPlS")), address: address)
        guard let stateCode = state.coerce(toDescriptorType: typeEnumerated)?.enumCodeValue,
              stateCode == code("kPSP") || stateCode == code("kPSp") else { return nil }
        let track = try get(property(code("pTrk")), address: address)
        guard track.descriptorType == typeObjectSpecifier else { return nil }
        // Fixed property reads match both players' public scripting dictionaries.
        // Resolve against the same track object, then revalidate the current ID.
        guard let id = try get(property(player.idProperty, of: track), address: address).stringValue,
              !id.isEmpty else { return nil }
        guard let title = try get(property(code("pnam"), of: track), address: address)
            .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let artist = try get(property(code("pArt"), of: track), address: address).stringValue ?? ""
        // A source switching tracks mid-read cannot supply a mismatched target.
        let currentID = try get(property(player.idProperty, of: property(code("pTrk"))), address: address).stringValue
        guard currentID == id else { return nil }
        return Track(player: player, id: id, title: title,
            artist: artist, playing: stateCode == code("kPSP"), readAt: readAt)
    }

    static func send(_ command: Command, player: Player, pid: pid_t, expectedTrackID: String) throws {
        guard let current = try read(player, pid: pid), current.id == expectedTrackID else { return }
        let address = NSAppleEventDescriptor(processIdentifier: pid)
        _ = try event(player.commandClass, id: code(command.rawValue), address: address)
    }

    static func code(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
    static func property(_ id: OSType, of container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(.init(typeCode: id), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
        }
        return result
    }
    private static func get(_ direct: NSAppleEventDescriptor, address: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try event(kAECoreSuite, id: kAEGetData, direct: direct, address: address)
    }
    private static func event(_ eventClass: AEEventClass, id: AEEventID,
                              direct: NSAppleEventDescriptor? = nil,
                              address: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: id,
            targetDescriptor: address, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        let options = NSAppleEventDescriptor.SendOptions(rawValue:
            UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent))
        let reply = try event.sendEvent(options: options, timeout: 1)
        let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
        guard error == 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(error)) }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    static func checkDescriptors() {
        for player in Player.allCases {
            let track = try! property(code("pTrk"))
            let id = try! property(player.idProperty, of: track)
            precondition(track.descriptorType == typeObjectSpecifier && id.descriptorType == typeObjectSpecifier)
            let state = NSAppleEventDescriptor(enumCode: code("kPSP"))
            precondition(state.coerce(toDescriptorType: typeEnumerated)?.enumCodeValue == code("kPSP"))
        }
        precondition(Player.spotify.commandClass == code("spfy") && Player.music.commandClass == code("hook"))
        print("Music player descriptors passed: running-player object specifiers, state coercion and separate command suites; no events sent.")
    }
}
