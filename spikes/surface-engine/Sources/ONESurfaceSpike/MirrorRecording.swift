import AppKit
@preconcurrency import AVFoundation
import CoreImage

enum MirrorRecordingResult: Sendable {
    case saved(URL), cancelled, failed(String)
}

// Owned by Mirror's serial capture queue. No camera, microphone or session ownership here.
final class MirrorMovieWriter: @unchecked Sendable {
    let id: UUID
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let aspect: CGFloat
    private let size: CGSize
    private var startTime: CMTime?
    private var lastVideoTime: CMTime?
    private var lastAudioTime: CMTime?
    private(set) var hasVideo = false
    private(set) var hasAudio = false
    private var finishing = false
    var isReady: Bool { hasVideo && hasAudio }

    init(id: UUID, source: CVPixelBuffer, aspect: CGFloat, folder: URL,
         audioSettings: [String: Any]) throws {
        self.id = id
        self.aspect = max(0.1, aspect)
        let crop = Self.mirroredCrop(source, aspect: self.aspect)
        let scale = min(1, 1920 / crop.extent.width, 1080 / crop.extent.height)
        let width = max(16, Int(crop.extent.width * scale) / 2 * 2)
        let height = max(16, Int(crop.extent.height * scale) / 2 * 2)
        size = CGSize(width: width, height: height)
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        url = folder.appendingPathComponent("SPIKE Mirror \(date) \(id.uuidString.prefix(8)).mov")
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(10_000_000, max(1_000_000, width * height * 4)),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw Self.error("Не удалось настроить запись видео со звуком")
        }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            let error = writer.error ?? Self.error("Не удалось создать видео")
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // The same mirror and center crop as resizeAspectFill in the preview and saved JPEG.
    static func mirroredCrop(_ buffer: CVPixelBuffer, aspect: CGFloat) -> CIImage {
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: extent.width, y: 0)
            .scaledBy(x: -1, y: 1))
        let width = min(extent.width, extent.height * aspect)
        let height = min(extent.height, extent.width / aspect)
        let crop = CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2,
                          width: width, height: height)
        return image.cropped(to: crop).transformed(by:
            CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        guard !finishing, time.isNumeric,
              lastVideoTime.map({ time > $0 }) ?? true else { return }
        try checkFailure()
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var destination: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,
            pool, [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &destination)
        // Real-time backpressure drops a frame instead of growing memory or blocking capture.
        if allocation == kCVReturnWouldExceedAllocationThreshold { return }
        guard allocation == kCVReturnSuccess, let destination else {
            throw Self.error("Не удалось подготовить кадр видео")
        }
        let image = Self.mirroredCrop(buffer, aspect: aspect)
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: size.width / image.extent.width, y: size.height / image.extent.height))
        context.render(scaled, to: destination, bounds: CGRect(origin: .zero, size: size),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        guard adaptor.append(destination, withPresentationTime: time) else {
            throw writer.error ?? Self.error("Не удалось записать кадр видео")
        }
        lastVideoTime = time
        hasVideo = true
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        guard !finishing, let startTime else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric, time >= startTime,
              lastAudioTime.map({ time > $0 }) ?? true else { return }
        try checkFailure()
        guard audio.isReadyForMoreMediaData else { return }
        guard audio.append(sample) else {
            throw writer.error ?? Self.error("Не удалось записать звук")
        }
        lastAudioTime = time
        hasAudio = true
    }

    private func checkFailure() throws {
        guard writer.status == .writing else {
            throw writer.error ?? Self.error("Запись видео прервалась")
        }
    }

    func finish(_ completion: @escaping @Sendable (MirrorRecordingResult) -> Void) {
        guard !finishing else { return }
        finishing = true
        guard isReady else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.cancelled)
            return
        }
        guard writer.status == .writing else {
            let message = writer.error?.localizedDescription ?? "Запись видео прервалась"
            try? FileManager.default.removeItem(at: url)
            completion(.failed(message))
            return
        }
        video.markAsFinished()
        audio.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                completion(.saved(url))
            } else {
                let message = writer.error?.localizedDescription ?? "Не удалось сохранить видео"
                try? FileManager.default.removeItem(at: url)
                completion(.failed(message))
            }
        }
    }

    func cancel() {
        guard !finishing else { return }
        finishing = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SPIKE.Mirror.Video", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// Synthetic encoded A/V, not a live capture probe. Also verifies nonzero source PTS,
// decoding, the actual saved mirror/crop, cancellation, and missing-folder failures.
func checkMirrorRecording() {
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        do { try await runMirrorRecordingCheck() }
        catch { preconditionFailure("Mirror video check failed: \(error)") }
        finished.signal()
    }
    let deadline = Date().addingTimeInterval(20)
    while finished.wait(timeout: .now()) != .success {
        precondition(Date() < deadline, "Mirror video check timed out")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

private func runMirrorRecordingCheck() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spike-video-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 80, 40, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
    let pixels = pixel!
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    for y in 0..<40 { for x in 0..<80 {
        let i = y * stride + x * 4
        base[i] = x < 40 ? 0 : 255
        base[i + 1] = 0
        base[i + 2] = x < 40 ? 255 : 0
        base[i + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
    let movie = try MirrorMovieWriter(id: UUID(), source: pixels, aspect: 1, folder: folder,
                                     audioSettings: audioSettings)
    // An early audio packet is ignored until the first video frame establishes the clock.
    try movie.appendAudio(makeMirrorTestAudio(at: CMTime(value: 479000, timescale: 48000)))
    precondition(!movie.hasAudio)
    for frame in 0..<8 {
        let time = CMTime(value: Int64(480000 + frame * 1600), timescale: 48000)
        try movie.appendVideo(pixels, at: time)
        try movie.appendAudio(makeMirrorTestAudio(at: time))
        try await Task.sleep(for: .milliseconds(40))
    }
    precondition(movie.isReady)
    try movie.appendVideo(pixels, at: CMTime(value: 1, timescale: 30)) // stale frame is ignored
    let result = await withCheckedContinuation { continuation in
        movie.finish { continuation.resume(returning: $0) }
    }
    guard case .saved(let url) = result else { preconditionFailure("Synthetic A/V failed: \(result)") }
    let asset = AVURLAsset(url: url)
    let videos = try await asset.loadTracks(withMediaType: .video)
    let audios = try await asset.loadTracks(withMediaType: .audio)
    precondition(videos.count == 1 && audios.count == 1)
    let size = try await videos[0].load(.naturalSize)
    let duration = try await asset.load(.duration)
    precondition(size == CGSize(width: 40, height: 40) && duration.seconds > 0.15 && duration.seconds < 1)
    let reader = try AVAssetReader(asset: asset)
    let videoOutput = AVAssetReaderTrackOutput(track: videos[0], outputSettings:
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    let audioOutput = AVAssetReaderTrackOutput(track: audios[0], outputSettings:
        [AVFormatIDKey: kAudioFormatLinearPCM])
    reader.add(videoOutput)
    reader.add(audioOutput)
    precondition(reader.startReading())
    let frame = videoOutput.copyNextSampleBuffer()!
    let decoded = CMSampleBufferGetImageBuffer(frame)!
    CVPixelBufferLockBaseAddress(decoded, .readOnly)
    let bytes = CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(decoded)
    precondition(bytes[20 * row + 5 * 4] > 180 && bytes[20 * row + 35 * 4 + 2] > 180,
                 "Saved video must center-crop and mirror once")
    CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
    let sound = audioOutput.copyNextSampleBuffer()!
    precondition(CMSampleBufferGetNumSamples(sound) > 0 && CMSampleBufferGetDataBuffer(sound) != nil)
    reader.cancelReading()

    let cancelled = try MirrorMovieWriter(id: UUID(), source: pixels, aspect: 1,
                                         folder: folder, audioSettings: audioSettings)
    try cancelled.appendVideo(pixels, at: .zero)
    let cancelledResult = await withCheckedContinuation { continuation in
        cancelled.finish { continuation.resume(returning: $0) }
    }
    guard case .cancelled = cancelledResult else { preconditionFailure("No sound must not produce a silent movie") }
    precondition(!FileManager.default.fileExists(atPath: cancelled.url.path))
    do {
        _ = try MirrorMovieWriter(id: UUID(), source: pixels, aspect: 1,
            folder: folder.appendingPathComponent("missing"), audioSettings: audioSettings)
        preconditionFailure("Missing save folder must fail visibly")
    } catch {}
    print("Mirror video checks passed: real H.264/AAC encode/decode, shared PTS, mirrored crop, cancel/error cleanup. No camera or microphone used.")
}

private func makeMirrorTestAudio(at time: CMTime) throws -> CMSampleBuffer {
    let count = 1600
    var format = AudioStreamBasicDescription(mSampleRate: 48000,
        mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var description: CMAudioFormatDescription?
    precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &description) == noErr)
    var block: CMBlockBuffer?
    precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: count * 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr)
    var pointer: UnsafeMutablePointer<Int8>?
    precondition(CMBlockBufferGetDataPointer(block!, atOffset: 0, lengthAtOffsetOut: nil,
        totalLengthOut: nil, dataPointerOut: &pointer) == noErr)
    pointer!.withMemoryRebound(to: Float.self, capacity: count) { samples in
        for i in 0..<count { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.1) }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
        presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: description, sampleCount: count, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &sample) == noErr)
    return sample!
}

