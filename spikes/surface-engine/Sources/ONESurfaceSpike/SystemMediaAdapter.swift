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
    private var generation = 0
    private var received = false
    private var commands: [Process] = []
    private var displayedImage: (cg: CGImage, ns: NSImage)?

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
            let decoder = SystemMediaStreamDecoder()
            output = stdout; errors = stderr; process = child
            child.standardOutput = stdout; child.standardError = stderr
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                let result = decoder.receive(data)
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if let error = result.error { self.fail(error); return }
                    for decoded in result.snapshots {
                        self.received = true
                        self.onSnapshot?(self.snapshot(for: decoded))
                    }
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
        displayedImage = nil
    }

    private func snapshot(for sample: SystemMediaStreamDecoder.Sample) -> AmbientMediaSnapshot {
        guard let image = sample.cover?.image else { return sample.snapshot() }
        if displayedImage?.cg !== image {
            displayedImage = (image, NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        }
        return sample.snapshot(artwork: displayedImage?.ns)
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

    static func decode(_ line: Data) -> AmbientMediaSnapshot? {
        SystemMediaStreamDecoder().decode(line)?.snapshot()
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

/// One serial decoder per helper generation. No AppKit images leave the UI thread.
private final class SystemMediaStreamDecoder: Sendable {
    private let queue = DispatchQueue(label: "local.one.media.decode", qos: .utility)
    private let state = State()

    struct Result: Sendable {
        var snapshots: [Sample] = []
        var error: String?
    }
    struct Sample: Sendable {
        var sourceID: String?
        var playing = false
        var title: String?
        var artist: String?
        var album: String?
        var trackID: String?
        var isMusic = false
        var canSkip = false
        var progress: TrackProgress?
        var cover: Cover?

        @MainActor func snapshot(artwork reusedArtwork: NSImage? = nil) -> AmbientMediaSnapshot {
            guard let sourceID else { return .idle }
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: sourceID)
                .first?.localizedName ?? sourceID
            let artwork = reusedArtwork ?? cover.map { NSImage(cgImage: $0.image,
                size: NSSize(width: $0.image.width, height: $0.image.height)) }
            return AmbientMediaSnapshot(state: playing ? .playing : .paused, title: title ?? name,
                subtitle: artist ?? album, sourceName: name, artwork: artwork,
                visualPalette: cover?.palette, sourceBundleIdentifier: sourceID,
                hasTrackMetadata: title != nil, canSkip: canSkip, trackIdentifier: trackID,
                album: album, progress: progress, isMusicSource: isMusic)
        }
    }
    struct Cover: Sendable {
        let image: CGImage
        let palette: ArtworkPalette?
    }

    private struct SpotifyCoverKey: Equatable {
        let pid: Double
        let title: String
        let artist: String
        let album: String
        let trackNumber: Double
        let duration: Double
        let uniqueID: String?
    }

    func receive(_ data: Data) -> Result { queue.sync { state.receive(data) } }
    func decode(_ line: Data) -> Sample? { queue.sync { state.decode(line) } }

    // Each instance is private to one decoder and is accessed only on its queue.
    private final class State: @unchecked Sendable {
        var buffer = Data()
        var previousEncoding: String?
        var previousCover: Cover?
        var spotifyCover: (key: SpotifyCoverKey, position: Double, cover: Cover)?
        let maximumLine = 12 * 1024 * 1024

        func receive(_ data: Data) -> Result {
            guard !data.isEmpty else { return .init(error: "Поток данных плеера закрыт") }
            buffer.append(data)
            var result = Result()
            while let end = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: end) <= maximumLine else {
                    return .init(error: "Слишком большой ответ плеера")
                }
                guard let sample = decode(Data(buffer[..<end])) else {
                    return .init(error: "Некорректный ответ плеера")
                }
                buffer.removeSubrange(...end)
                result.snapshots.append(sample)
            }
            guard buffer.count <= maximumLine else { return .init(error: "Слишком большой ответ плеера") }
            return result
        }

        func decode(_ line: Data) -> Sample? {
            guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  envelope["type"] as? String == "data", envelope["diff"] as? Bool == false,
                  let payload = envelope["payload"] as? [String: Any] else { return nil }
            if payload.isEmpty {
                previousEncoding = nil
                previousCover = nil
                spotifyCover = nil
                return Sample()
            }
            guard let bundleID = payload["bundleIdentifier"] as? String, !bundleID.isEmpty,
                  let playing = payload["playing"] as? Bool else { return nil }
            func string(_ key: String) -> String? {
                guard let value = (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
            let title = string("title")
            let artist = string("artist"), album = string("album")
            let source = string("parentApplicationBundleIdentifier") ?? bundleID
            let uniqueID = string("uniqueIdentifier")
            let encoded = payload["artworkData"] as? String
            var image = cover(encoded)
            // Spotify can issue a new content item ID on both pause and resume
            // before re-publishing the identical artwork. That ID still goes
            // to the snapshot; this fallback supplies only cover pixels/colour.
            func number(_ key: String) -> Double? {
                guard let value = payload[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite else { return nil }
                return value.doubleValue
            }
            if source == "com.spotify.client", let title, let artist, let album,
               let pid = number("processIdentifier"), pid > 0,
               let trackNumber = number("trackNumber"), trackNumber > 0,
               let duration = number("duration"), duration > 0,
               let position = number("elapsedTime"), (0...duration).contains(position) {
                let key = SpotifyCoverKey(pid: pid, title: title, artist: artist,
                    album: album, trackNumber: trackNumber, duration: duration, uniqueID: uniqueID)
                // A new item starting at zero is ambiguous without a stable
                // unique ID, even if its human-readable metadata is identical.
                if payload["artworkData"] == nil, let previous = spotifyCover,
                   previous.key == key, (uniqueID != nil || position > 1),
                   position >= previous.position - 1 {
                    image = previous.cover
                }
                spotifyCover = image.map { (key, position, $0) }
            } else {
                spotifyCover = nil
            }
            let progress = title == nil ? nil : TrackProgress.decode(payload, playing: playing,
                receivedAt: .now, uptime: ProcessInfo.processInfo.systemUptime)
            return Sample(sourceID: source,
                playing: playing, title: title, artist: artist, album: album,
                trackID: string("contentItemIdentifier") ?? uniqueID,
                isMusic: payload["isMusicApp"] as? Bool == true,
                canSkip: payload["prohibitsSkip"] as? Bool != true, progress: progress,
                cover: image)
        }

        private func cover(_ encoded: String?) -> Cover? {
            guard let encoded, encoded.utf8.count <= 8 * 1024 * 1024 else { return nil }
            if encoded == previousEncoding { return previousCover }
            previousEncoding = encoded
            previousCover = nil
            guard let data = Data(base64Encoded: encoded),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 32_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 512,
                      kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            let cover = Cover(image: image, palette: ArtworkPalette.extract(image))
            previousCover = cover
            return cover
        }
    }
}

@MainActor func checkSystemMediaDecoding() {
    func packet(_ payload: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": payload])
    }
    func decode(_ payload: [String: Any]) -> AmbientMediaSnapshot? {
        SystemMediaAdapter.decode(packet(payload))
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
    let stream = SystemMediaStreamDecoder()
    let sample = packet(["bundleIdentifier": "test.player", "playing": false,
        "title": "Track", "contentItemIdentifier": "item-1", "artworkData": png.base64EncodedString(),
        "duration": 180, "elapsedTime": 42])
    precondition(stream.receive(Data(sample.prefix(10))).snapshots.isEmpty)
    var remainder = Data(sample.dropFirst(10)); remainder.append(10)
    remainder.append(sample); remainder.append(10)
    let burst = stream.receive(remainder)
    precondition(burst.error == nil && burst.snapshots.count == 2)
    precondition(burst.snapshots[0].cover!.image === burst.snapshots[1].cover!.image)
    precondition(burst.snapshots[1].snapshot().progress?.position == 42)
    precondition(burst.snapshots[1].snapshot().trackIdentifier == "item-1")
    // Observed Spotify transition: two new content IDs arrive without artwork
    // before the same cover returns. Keep one image without rewriting IDs.
    let spotify = SystemMediaStreamDecoder()
    var update: [String: Any] = ["bundleIdentifier": "com.spotify.client", "processIdentifier": 123,
        "title": "Track", "artist": "Artist", "album": "Album", "trackNumber": 3,
        "duration": 171, "elapsedTime": 128.013, "playing": false, "contentItemIdentifier": "paused",
        "artworkData": png.base64EncodedString()]
    let initial = spotify.decode(packet(update))!.cover!.image
    for id in ["playing-1", "playing-2", "paused-again"] {
        update["contentItemIdentifier"] = id
        update["playing"] = id.hasPrefix("playing")
        update["elapsedTime"] = 128.276
        update.removeValue(forKey: "artworkData")
        let gap = spotify.decode(packet(update))!
        precondition(gap.trackID == id && gap.cover?.image === initial,
                     "Spotify playback ID rotation must not flash the cover")
        update["artworkData"] = png.base64EncodedString()
        precondition(spotify.decode(packet(update))?.cover?.image === initial)
    }
    update.removeValue(forKey: "artworkData")
    for id in ["rapid-1", "rapid-2"] {
        update["contentItemIdentifier"] = id
        precondition(spotify.decode(packet(update))?.cover?.image === initial)
    }
    update["contentItemIdentifier"] = "next"
    update["trackNumber"] = 4
    update.removeValue(forKey: "artworkData")
    precondition(spotify.decode(packet(update))?.cover == nil)
    update["artworkData"] = png.base64EncodedString()
    _ = spotify.decode(packet(update))
    update.removeValue(forKey: "artworkData")
    update["elapsedTime"] = 0
    precondition(spotify.decode(packet(update))?.cover == nil)
    print("System media checks passed: real image decoding, source/track replace, Spotify playback ID churn, restart guard, malformed/diff rejection.")
}
