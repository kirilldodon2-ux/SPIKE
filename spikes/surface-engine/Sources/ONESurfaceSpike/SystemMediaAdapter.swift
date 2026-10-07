import AppKit
import ImageIO

/// Optional user-approved experiment. Fixed bundled helper, no shell or network.
@MainActor final class SystemMediaAdapter: AmbientMediaAdapter {
    var onSnapshot: ((AmbientMediaSnapshot) -> Void)?
    var onFailure: ((String) -> Void)?
    var supportsTransport: Bool { process?.isRunning == true }
    private var process: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var buffer = Data()
    private var generation = 0
    private var received = false
    private var commands: [Process] = []
    private let maximumLine = 12 * 1024 * 1024

    private func configuredProcess(_ arguments: [String]) throws -> Process {
        guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.appendingPathComponent("MediaRemoteAdapter").path)
        else { throw CocoaError(.fileNoSuchFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path] + arguments
        // No inherited Perl injection/custom module paths or helper configuration.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                               "TMPDIR": NSTemporaryDirectory()]
        return process
    }

    func start() {
        guard process == nil else { return }
        generation += 1
        let token = generation
        received = false
        do {
            let child = try configuredProcess(["stream", "--no-diff", "--debounce=100", "--allow-missing-title"])
            let stdout = Pipe(), stderr = Pipe()
            output = stdout; errors = stderr; process = child
            child.standardOutput = stdout; child.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if data.isEmpty { self.fail("Поток данных плеера закрыт") }
                    else { self.receive(data) }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    NSLog("ONE media helper: %@", String(decoding: data.prefix(2048), as: UTF8.self))
                }
            }
            child.terminationHandler = { [weak self] child in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.fail("Данные плеера недоступны (код \(child.terminationStatus))")
                }
            }
            try child.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.generation == token, !self.received else { return }
                self.fail("Плеер не ответил вовремя")
            }
        } catch { fail("Не удалось запустить наблюдение плеера: \(error.localizedDescription)") }
    }

    func stop() {
        generation += 1
        output?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        if let process { Self.terminate(process) }
        for command in commands { Self.terminate(command) }
        commands.removeAll()
        process = nil; output = nil; errors = nil
        buffer.removeAll()
    }

    private static func terminate(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        // A stuck optional helper must not survive disable/quit indefinitely.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func fail(_ message: String) {
        stop()
        onSnapshot?(.unavailable)
        onFailure?(message)
        NSLog("ONE media: %@", message)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= maximumLine else { fail("Слишком большой ответ плеера"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard let snapshot = Self.decode(line) else { fail("Некорректный ответ плеера"); return }
            received = true
            onSnapshot?(snapshot)
        }
    }

    static func decode(_ line: Data) -> AmbientMediaSnapshot? {
        guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              envelope["type"] as? String == "data", envelope["diff"] as? Bool == false,
              let payload = envelope["payload"] as? [String: Any] else { return nil }
        if payload.isEmpty { return .idle }
        guard let bundleID = payload["bundleIdentifier"] as? String, !bundleID.isEmpty,
              let playing = payload["playing"] as? Bool else { return nil }
        let parentID = payload["parentApplicationBundleIdentifier"] as? String
        let sourceID = parentID?.isEmpty == false ? parentID! : bundleID
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: sourceID).first
        let sourceName = app?.localizedName ?? sourceID
        let title = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshot = AmbientMediaSnapshot(state: playing ? .playing : .paused,
            title: title?.isEmpty == false ? title! : sourceName,
            subtitle: payload["artist"] as? String ?? payload["album"] as? String,
            sourceName: sourceName, artwork: artwork(payload))
        snapshot.visualPalette = snapshot.artwork.flatMap(ArtworkPalette.extract)
        snapshot.sourceBundleIdentifier = sourceID
        snapshot.hasTrackMetadata = title?.isEmpty == false
        snapshot.isMusicSource = payload["isMusicApp"] as? Bool == true
        snapshot.canSkip = payload["prohibitsSkip"] as? Bool != true
        return snapshot
    }

    private static func artwork(_ payload: [String: Any]) -> NSImage? {
        guard let encoded = payload["artworkData"] as? String, encoded.utf8.count <= 8 * 1024 * 1024,
              let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000 else { return nil }
        // Decode a bounded thumbnail, never a full untrusted-sized bitmap.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 512,
                                      kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func togglePlayback() { send(2) }
    func skipForward() { send(4) }
    func skipBackward() { send(5) }

    private func send(_ id: Int) {
        guard supportsTransport, [2, 4, 5].contains(id) else { return }
        do {
            let child = try configuredProcess(["send", String(id)])
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.standardError
            child.terminationHandler = { [weak self] child in
                DispatchQueue.main.async {
                    self?.commands.removeAll { $0 === child }
                    if child.terminationStatus != 0 { self?.onFailure?("Плеер не принял команду") }
                }
            }
            commands.append(child)
            try child.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if child.isRunning { Self.terminate(child) }
            }
        } catch { onFailure?("Не удалось отправить команду плееру") }
    }
}

@MainActor func checkSystemMediaDecoding() {
    func decode(_ payload: [String: Any]) -> AmbientMediaSnapshot? {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": payload])
        return SystemMediaAdapter.decode(data)
    }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let first = decode(["bundleIdentifier": "test.player", "playing": true,
                        "title": "Track A", "artworkData": png.base64EncodedString()])!
    precondition(first.state == .playing && first.artwork != nil)
    precondition(first.hasTrackMetadata && !first.metadataIsRetained)
    let next = decode(["bundleIdentifier": "test.browser", "playing": true, "title": "Track B"])!
    precondition(next.sourceBundleIdentifier == "test.browser" && next.title == "Track B" && next.artwork == nil)
    precondition(next.visualPalette == nil)
    let malformedArt = decode(["bundleIdentifier": "test.player", "playing": false,
                              "title": "Paused", "artworkData": "invalid"] )!
    precondition(malformedArt.state == .paused && malformedArt.artwork == nil)
    let untitled = decode(["bundleIdentifier": "test.helper", "parentApplicationBundleIdentifier": "test.browser",
                           "playing": true, "title": " \n "])!
    precondition(!untitled.hasTrackMetadata && untitled.sourceBundleIdentifier == "test.browser")
    let emptyParent = decode(["bundleIdentifier": "test.player", "parentApplicationBundleIdentifier": "",
                             "playing": true, "title": "Track"])!
    precondition(emptyParent.sourceBundleIdentifier == "test.player")
    precondition(decode([:])?.state == .idle)
    precondition(decode(["title": "Missing source"]) == nil)
    precondition(SystemMediaAdapter.decode(Data("not JSON".utf8)) == nil)
    let diff = Data(#"{"type":"data","diff":true,"payload":{"playing":false}}"#.utf8)
    precondition(SystemMediaAdapter.decode(diff) == nil)
    print("System media checks passed: real image decoding, source/track replace, missing or corrupt artwork, pause, idle, malformed/diff rejection.")
}
