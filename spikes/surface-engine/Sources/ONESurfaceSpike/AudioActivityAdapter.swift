import AppKit
import CoreAudio

/// Public audio-output activity only. No audio capture, track metadata or transport.
@MainActor final class AudioActivityAdapter: AmbientMediaAdapter {
    var onSnapshot: ((AmbientMediaSnapshot) -> Void)?
    private struct Source: Sendable {
        let pid: pid_t?
        let bundleID: String?
    }
    private struct Reading: Sendable {
        var sources: [Source] = []
        var failed = false
    }
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var lastState: AmbientPlaybackState?
    private var lastSource: String?
    private var lastSourceIDs: [String] = []
    private let queue = DispatchQueue(label: "local.one.audio-observation", qos: .utility)

    func start() {
        guard timer == nil else { return }
        generation += 1
        let token = generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Listener re-registration caused a notification feedback loop on this Mac.
        // Bounded background observation keeps HAL work completely off the UI thread.
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(250))
        let handler: @Sendable () -> Void = { [weak self] in
            let reading = Self.readSources()
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.publish(reading)
            }
        }
        timer.setEventHandler(handler: handler)
        self.timer = timer
        timer.resume()
    }

    func stop() {
        generation += 1
        timer?.cancel()
        timer = nil
        lastState = nil
        lastSource = nil
        lastSourceIDs = []
    }

    func togglePlayback() {}
    func skipForward() {}
    func skipBackward() {}

    nonisolated private static func readSources() -> Reading {
        guard let objects = processes() else { return Reading(failed: true) }
        var reading = Reading()
        for object in objects {
            guard let active = number(object, kAudioProcessPropertyIsRunningOutput) else {
                reading.failed = true
                continue
            }
            guard active != 0 else { continue }
            reading.sources.append(Source(
                pid: number(object, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) },
                bundleID: bundleID(object)))
        }
        return reading
    }

    private func publish(_ reading: Reading) {
        var sources = Set<String>()
        var bundleIDs = Set<String>()
        let apps = NSWorkspace.shared.runningApplications
        for source in reading.sources {
            let app = apps.first { $0.processIdentifier == source.pid && $0.activationPolicy == .regular }
                ?? apps.filter { app in
                    guard let id = app.bundleIdentifier, let bundle = source.bundleID else { return false }
                    return app.activationPolicy == .regular && (id == bundle || bundle.hasPrefix(id + "."))
                }.max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            sources.insert(app?.localizedName ?? source.bundleID ?? "Неизвестный источник")
            if let id = app?.bundleIdentifier ?? source.bundleID { bundleIDs.insert(id) }
        }
        var next = Self.snapshot(sources: sources.sorted(), failed: reading.failed)
        next.audioSourceBundleIdentifiers = bundleIDs.sorted()
        publish(snapshot: next)
    }

    private func publish(snapshot next: AmbientMediaSnapshot) {
        guard next.state != lastState || next.sourceName != lastSource
                || next.audioSourceBundleIdentifiers != lastSourceIDs else { return }
        lastState = next.state
        lastSource = next.sourceName
        lastSourceIDs = next.audioSourceBundleIdentifiers
        onSnapshot?(next)
    }

    static func checkSourceIdentityUpdates() {
        let adapter = AudioActivityAdapter()
        var updates: [AmbientMediaSnapshot] = []
        adapter.onSnapshot = { updates.append($0) }
        var first = snapshot(sources: ["Player"], failed: false)
        first.audioSourceBundleIdentifiers = ["test.player.one"]
        var second = first
        second.audioSourceBundleIdentifiers = ["test.player.two"]
        adapter.publish(snapshot: first)
        adapter.publish(snapshot: first)
        adapter.publish(snapshot: second)
        precondition(updates.count == 2 && updates.last?.audioSourceBundleIdentifiers == ["test.player.two"])
    }

    static func snapshot(sources: [String], failed: Bool) -> AmbientMediaSnapshot {
        if !sources.isEmpty {
            return AmbientMediaSnapshot(state: .audioActive,
                title: sources.count == 1 ? "Аудиовыход активен" : "Несколько источников",
                subtitle: "Название трека недоступно",
                sourceName: sources.joined(separator: " · "), artwork: nil)
        }
        if failed { return .unavailable }
        return AmbientMediaSnapshot(state: .audioIdle, title: "Аудио не обнаружено",
            subtitle: "Нет активных аудиопотоков", sourceName: nil, artwork: nil)
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func processes() -> [AudioObjectID]? {
        var address = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        if size == 0 { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    nonisolated private static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector), size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    nonisolated private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        let text = value?.takeRetainedValue() as String?
        return text?.isEmpty == false ? text : nil
    }
}

@MainActor func checkMediaStates() {
    AudioActivityAdapter.checkSourceIdentityUpdates()
    let active = AudioActivityAdapter.snapshot(sources: ["Player"], failed: false)
    precondition(active.state == .audioActive && active.sourceName == "Player" && active.artwork == nil)
    let idle = AudioActivityAdapter.snapshot(sources: [], failed: false)
    precondition(idle.state == .audioIdle && idle.title != "Shh…" && idle.sourceName == nil)
    precondition(AudioActivityAdapter.snapshot(sources: [], failed: true).state == .unavailable)
    let multiple = AudioActivityAdapter.snapshot(sources: ["Browser", "Player"], failed: false)
    precondition(multiple.sourceName == "Browser · Player" && multiple.artwork == nil)
    print("Media checks passed: activity is not track playback, no stale artwork, multiple sources, errors are unavailable.")
}
