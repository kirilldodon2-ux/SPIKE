import AppKit
@preconcurrency import AVFoundation
import CoreImage
import SwiftUI

private let mirrorFolderDefaultsKey = "mirrorSaveFolder"

@MainActor final class MirrorController: ObservableObject {
    enum Status: Sendable {
        case idle, requesting, starting, ready, denied, unavailable

        var message: String? {
            switch self {
            case .idle, .ready: nil
            case .requesting: "Запрашиваю доступ к камере…"
            case .starting: "Открываю камеру…"
            case .denied: "Доступ к камере выключен в System Settings"
            case .unavailable: "Камера недоступна"
            }
        }
    }

    enum RecordingState { case idle, preparing, recording, saving }

    let session: AVCaptureSession
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCaptureMessage: String?
    @Published private(set) var captureGeneration = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var shutterFlash = false
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var saveFolder: URL
    @Published private(set) var lightStrength = 0.0
    @Published private(set) var lightWarmth = 0.5

    private let worker: MirrorCaptureWorker
    private let light: MirrorScreenLight? = MirrorScreenLight.isEnabled ? MirrorScreenLight() : nil
    private var isActive = false
    private var permissionRequestID = UUID()
    private var recordingRequestID = UUID()
    private var workerRecordingRequested = false
    private var finishCallbacks: [() -> Void] = []
    var onVisibilityHoldEnded: (() -> Void)?
    var keepsMirrorOpen: Bool { recordingState != .idle }

    init() {
        let worker = MirrorCaptureWorker()
        self.worker = worker
        self.session = worker.session
        self.saveFolder = MirrorController.defaultFolder
        worker.onReady = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.status = .ready
            }
        }
        worker.onConfigurationFailure = { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.status = .unavailable
            }
        }
        worker.onRecordingStarted = { [weak self] id in
            Task { @MainActor in
                guard let self, self.isActive, self.recordingRequestID == id,
                      self.recordingState == .preparing else { return }
                self.recordingState = .recording
                self.lastCaptureMessage = nil
            }
        }
        worker.onRecordingResult = { [weak self] id, result in
            Task { @MainActor in
                guard let self, self.recordingRequestID == id else { return }
                switch result {
                case .saved(let url):
                    self.lastCaptureMessage = "Видео сохранено в \(url.deletingLastPathComponent().lastPathComponent)"
                case .cancelled: self.lastCaptureMessage = "Запись отменена"
                case .failed(let message): self.lastCaptureMessage = message
                }
                self.endRecordingState()
            }
        }
        worker.onCaptureResult = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                switch result {
                case .success(let url):
                    self.lastCaptureMessage = "Сохранено в \(url.deletingLastPathComponent().lastPathComponent)"
                    self.captureGeneration += 1
                    self.shutterFlash = true
                    let generation = self.captureGeneration
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(160))
                        guard let self, self.captureGeneration == generation else { return }
                        self.shutterFlash = false
                    }
                case .failure(let message):
                    self.lastCaptureMessage = message
                }
            }
        }
    }

    private static var defaultFolder: URL {
        if let path = UserDefaults.standard.string(forKey: mirrorFolderDefaultsKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        lastCaptureMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status = .starting
            worker.start()
        case .notDetermined:
            status = .requesting
            let requestID = UUID()
            permissionRequestID = requestID
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.isActive, self.permissionRequestID == requestID else { return }
                if granted {
                    self.status = .starting
                    self.worker.start()
                } else {
                    self.status = .denied
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .unavailable
        }
    }

    func deactivate() {
        isActive = false
        lightStrength = 0
        light?.hide()
        permissionRequestID = UUID()
        stopRecording()
        worker.stop()
        if status == .ready || status == .requesting || status == .starting { status = .idle }
    }

    func capture(previewAspect: CGFloat) {
        guard isActive, status == .ready, !isCapturing, recordingState == .idle else { return }
        isCapturing = true
        lastCaptureMessage = nil
        worker.capture(aspect: max(0.1, previewAspect), folder: saveFolder)
    }

    func startRecording(previewAspect: CGFloat) {
        guard isActive, status == .ready, !isCapturing, recordingState == .idle else { return }
        recordingState = .preparing
        shutterFlash = false
        lastCaptureMessage = "Готовлю запись…"
        let id = UUID()
        recordingRequestID = id
        workerRecordingRequested = false
        Task { @MainActor [weak self] in
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
            default: granted = false
            }
            guard let self, self.isActive, self.recordingRequestID == id,
                  self.recordingState == .preparing else { return }
            guard granted else {
                self.lastCaptureMessage = "Для видео со звуком нужен доступ к микрофону в настройках macOS"
                self.endRecordingState()
                return
            }
            self.workerRecordingRequested = true
            self.worker.startRecording(id: id, aspect: max(0.1, previewAspect), folder: self.saveFolder)
        }
    }

    func stopRecording() {
        guard recordingState == .preparing || recordingState == .recording else { return }
        if !workerRecordingRequested {
            recordingRequestID = UUID() // An unanswered microphone prompt cannot start later.
            lastCaptureMessage = "Запись отменена"
            endRecordingState()
        } else {
            recordingState = .saving
            lastCaptureMessage = "Сохраняю видео…"
            worker.stopRecording()
        }
    }

    func finishBeforeQuitting(_ completion: @escaping () -> Void) {
        finishCallbacks.append(completion)
        stopRecording()
        if recordingState == .idle { endRecordingState() }
    }

    private func endRecordingState() {
        recordingState = .idle
        workerRecordingRequested = false
        let callbacks = finishCallbacks
        finishCallbacks.removeAll()
        // In particular, reply to applicationShouldTerminate after it has returned terminateLater.
        Task { @MainActor in
            callbacks.forEach { $0() }
            self.onVisibilityHoldEnded?()
        }
    }

    func chooseSaveFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveFolder
        panel.prompt = "Выбрать"
        panel.message = "Папка для снимков и видео Mirror"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url
        UserDefaults.standard.set(url.path, forKey: mirrorFolderDefaultsKey)
    }

    func openSavedFolder() {
        NSWorkspace.shared.open(saveFolder)
    }

    func setLightScreen(_ screen: NSScreen?) {
        guard let light else { return }
        lightStrength = 0
        light.setScreen(screen)
    }

    func setLightStrength(_ value: Double) {
        guard let light, isActive, status == .ready, value.isFinite else { return }
        lightStrength = min(1, max(0, value))
        light.setStrength(lightStrength, warmth: lightWarmth)
    }

    func setLightWarmth(_ value: Double) {
        guard let light, value.isFinite else { return }
        lightWarmth = min(1, max(0, value))
        if isActive, status == .ready {
            light.setStrength(lightStrength, warmth: lightWarmth)
        }
    }

    func toggleLight() {
        setLightStrength(lightStrength > 0 ? 0 : 0.4)
    }
}

private final class MirrorCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                         AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CaptureResult: Sendable {
        case success(URL)
        case failure(String)
    }

    let session = AVCaptureSession()
    var onReady: (@Sendable () -> Void)?
    var onConfigurationFailure: (@Sendable () -> Void)?
    var onCaptureResult: (@Sendable (CaptureResult) -> Void)?
    var onRecordingStarted: (@Sendable (UUID) -> Void)?
    var onRecordingResult: (@Sendable (UUID, MirrorRecordingResult) -> Void)?

    private let queue = DispatchQueue(label: "one.mirror.capture", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var latestBuffer: CVPixelBuffer?
    private var configured = false
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var movie: MirrorMovieWriter?
    private var finalizingMovie = false
    private var recordingAnnounced = false
    private var recordingTimeout: DispatchWorkItem?
    private var notifications: [NSObjectProtocol] = []

    func start() {
        queue.async { [self] in
            if !configured {
                guard configure() else {
                    onConfigurationFailure?()
                    return
                }
            }
            if !session.isRunning { session.startRunning() }
            guard session.isRunning else {
                onConfigurationFailure?()
                return
            }
            onReady?()
        }
    }

    func stop() {
        queue.async { [self] in
            finishRecording()
            latestBuffer = nil
            if session.isRunning { session.stopRunning() }
        }
    }

    func startRecording(id: UUID, aspect: CGFloat, folder: URL) {
        queue.async { [self] in
            guard session.isRunning, movie == nil, !finalizingMovie, let buffer = latestBuffer else {
                onRecordingResult?(id, .failed("Камера ещё не готова к записи"))
                return
            }
            do {
                guard let device = AVCaptureDevice.default(for: .audio) else {
                    throw NSError(domain: "SPIKE.Mirror", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Микрофон недоступен"])
                }
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(audioOutput) else {
                    session.commitConfiguration()
                    throw NSError(domain: "SPIKE.Mirror", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Не удалось подключить микрофон"])
                }
                session.addInput(input)
                audioInput = input
                audioOutput.setSampleBufferDelegate(self, queue: queue)
                session.addOutput(audioOutput)
                session.commitConfiguration()
                guard let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) else {
                    throw NSError(domain: "SPIKE.Mirror", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Не удалось настроить звук видео"])
                }
                movie = try MirrorMovieWriter(id: id, source: buffer, aspect: aspect,
                                             folder: folder, audioSettings: settings)
                recordingAnnounced = false
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.movie?.id == id, !self.recordingAnnounced else { return }
                    self.failRecording("Камера или микрофон не передают данные. Запись не началась")
                }
                recordingTimeout = timeout
                queue.asyncAfter(deadline: .now() + 3, execute: timeout)
            } catch {
                removeMicrophone()
                onRecordingResult?(id, .failed("Не удалось начать запись: \(error.localizedDescription)"))
            }
        }
    }

    func stopRecording() { queue.async { [self] in finishRecording() } }

    private func removeMicrophone() {
        guard let audioInput else { return }
        session.beginConfiguration()
        if session.outputs.contains(audioOutput) { session.removeOutput(audioOutput) }
        session.removeInput(audioInput)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        self.audioInput = nil
        session.commitConfiguration()
    }

    private func finishRecording() {
        guard let movie else { return }
        recordingTimeout?.cancel()
        recordingTimeout = nil
        self.movie = nil
        finalizingMovie = true
        removeMicrophone()
        movie.finish { [self] result in
            queue.async { [self] in
                finalizingMovie = false
                onRecordingResult?(movie.id, result)
            }
        }
    }

    private func failRecording(_ message: String) {
        guard let movie else { return }
        recordingTimeout?.cancel()
        recordingTimeout = nil
        self.movie = nil
        removeMicrophone()
        movie.cancel()
        onRecordingResult?(movie.id, .failed(message))
    }

    func capture(aspect: CGFloat, folder: URL) {
        queue.async { [self] in
            guard session.isRunning, let buffer = latestBuffer else {
                onCaptureResult?(.failure("Кадр ещё не готов"))
                return
            }
            do {
                let data = try Self.jpegData(from: buffer, aspect: aspect)
                let url = try Self.writeUnique(data: data, to: folder)
                onCaptureResult?(.success(url))
            } catch {
                onCaptureResult?(.failure("Не удалось сохранить селфи: \(error.localizedDescription)"))
            }
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                     for: .video,
                                                     position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        session.commitConfiguration()
        configured = true
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: session,
                queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { [self] in
                    // Finalize any acquired clip; no automatic recording restart after interruption.
                    finishRecording()
                    latestBuffer = nil
                    onConfigurationFailure?()
                }
            })
        }
        return true
    }

    deinit { notifications.forEach { NotificationCenter.default.removeObserver($0) } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        do {
            if output === self.output, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                latestBuffer = buffer
                try movie?.appendVideo(buffer, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            } else if output === audioOutput {
                try movie?.appendAudio(sampleBuffer)
            }
            if let movie, movie.isReady, !recordingAnnounced {
                recordingAnnounced = true
                recordingTimeout?.cancel()
                recordingTimeout = nil
                onRecordingStarted?(movie.id)
            }
        } catch { failRecording("Запись прервалась: \(error.localizedDescription)") }
    }

    fileprivate static func jpegData(from buffer: CVPixelBuffer, aspect: CGFloat) throws -> Data {
        let context = CIContext(options: [.cacheIntermediates: false])
        let cropped = MirrorMovieWriter.mirroredCrop(buffer, aspect: aspect)
        guard let data = context.jpegRepresentation(of: cropped, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else {
            throw NSError(domain: "ONE.Mirror", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "JPEG-кодирование не удалось"])
        }
        return data
    }

    fileprivate static func writeUnique(data: Data, to folder: URL) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("ONE Mirror \(date) \(UUID().uuidString.prefix(8)).jpg")
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

}

private final class CameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        updateMirroring()
    }

    func updateMirroring() {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let ready: Bool

    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(session: session) }
    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        if ready { nsView.updateMirroring() }
    }
}

private struct ShutterBrackets: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 2
        let radius = max(0, cornerRadius - 3)
        let length: CGFloat = 20
        var path = Path()
        for corner in 0..<4 {
            let x = corner % 2 == 0 ? rect.minX + inset : rect.maxX - inset
            let y = corner < 2 ? rect.minY + inset : rect.maxY - inset
            let sx: CGFloat = corner % 2 == 0 ? 1 : -1
            let sy: CGFloat = corner < 2 ? 1 : -1
            path.move(to: CGPoint(x: x + sx * length, y: y))
            path.addLine(to: CGPoint(x: x + sx * radius, y: y))
            path.addQuadCurve(to: CGPoint(x: x, y: y + sy * radius), control: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + sy * length))
        }
        return path
    }
}

private struct MirrorPressTarget: View {
    @ObservedObject var controller: MirrorController
    let aspect: CGFloat

    private var enabled: Bool {
        controller.status == .ready && !controller.isCapturing && controller.recordingState != .saving
    }

    private func click() {
        guard enabled else { return }
        if controller.recordingState == .idle { controller.capture(previewAspect: aspect) }
        else { controller.stopRecording() }
    }

    var body: some View {
        // Keep the established SwiftUI button / nonactivating-panel event path.
        // One exclusive gesture owns pointer input: a successful hold cannot also tap.
        Button(action: click) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .exclusively(before: TapGesture())
            .onEnded { result in
                guard enabled else { return }
                switch result {
                case .first(true):
                    if controller.recordingState == .idle {
                        controller.startRecording(previewAspect: aspect)
                    }
                case .second: click()
                default: break
                }
            })
        .accessibilityLabel(controller.recordingState == .idle ? "Сделать селфи" : "Остановить запись видео")
        .accessibilityAction(named: "Записать видео со звуком") {
            guard enabled else { return }
            controller.startRecording(previewAspect: aspect)
        }
        .help(controller.recordingState == .idle
            ? "Нажмите для селфи · удерживайте для видео со звуком"
            : "Нажмите, чтобы остановить и сохранить видео")
        .disabled(!enabled)
    }
}

struct MirrorToolView: View {
    @ObservedObject var controller: MirrorController
    let active: Bool
    var cornerRadius: CGFloat = SurfaceLayout.mirrorCornerRadius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceAppearance) private var appearance
    private var flash: Bool { controller.shutterFlash }
    private var recording: Bool { controller.recordingState == .recording }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(appearance.fill(0.07))
                CameraPreview(session: controller.session, ready: controller.status == .ready)
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .opacity(controller.status == .ready ? 1 : 0)
                    .animation(controller.status == .ready ? .easeOut(duration: 0.18) : nil,
                               value: controller.status == .ready)
                if let message = controller.status.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(appearance.secondary).surfaceInkLegibility()
                }
                if let message = controller.lastCaptureMessage {
                    Text(message).font(.system(size: 10, weight: .medium)).foregroundStyle(appearance.primary)
                        .surfaceInkLegibility()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(appearance.surface, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 10)
                }
                ShutterBrackets(cornerRadius: cornerRadius)
                    .stroke(recording ? appearance.recording : appearance.primary,
                            style: StrokeStyle(lineWidth: flash || recording ? 2.5 : 1.5, lineCap: .round))
                    .padding((flash || recording) && !reduceMotion ? 6 : 1)
                    .opacity(flash || recording ? 1 : 0.5)
                    // The frame sits on live pixels, so outline it independently of the surface.
                    .shadow(color: appearance.oppositeInk.opacity(0.8), radius: 0.75)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: flash)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: recording)
                    .allowsHitTesting(false)
                Color.white.opacity(flash && !reduceMotion ? 0.24 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .animation(.easeOut(duration: 0.24), value: flash)
                    .allowsHitTesting(false)
                MirrorPressTarget(controller: controller,
                    aspect: geometry.size.width / max(geometry.size.height, 1))
            }
            .contentShape(Rectangle())
        }
        .onAppear { if active { controller.activate() } }
        .onChange(of: active) { _, value in
            if value { controller.activate() } else { controller.deactivate() }
        }
        .onDisappear { controller.deactivate() }

    }
}

func checkMirrorCapture() {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 80, 40, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixels = buffer!
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
    do {
        let jpeg = try MirrorCaptureWorker.jpegData(from: pixels, aspect: 1)
        let decoded = NSBitmapImageRep(data: jpeg)!
        precondition(decoded.pixelsWide == 40 && decoded.pixelsHigh == 40)
        let left = decoded.colorAt(x: 5, y: 20)!.usingColorSpace(.deviceRGB)!
        let right = decoded.colorAt(x: 35, y: 20)!.usingColorSpace(.deviceRGB)!
        precondition(left.blueComponent > 0.7 && right.redComponent > 0.7, "Selfie must mirror exactly once")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("one-mirror-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try MirrorCaptureWorker.writeUnique(data: jpeg, to: folder)
        let second = try MirrorCaptureWorker.writeUnique(data: jpeg, to: folder)
        let saved = try Data(contentsOf: first)
        precondition(first != second && saved == jpeg)
        do {
            _ = try MirrorCaptureWorker.writeUnique(data: jpeg, to: folder.appendingPathComponent("missing"))
            preconditionFailure("Missing folder must report a save error")
        } catch {}
        print("Mirror checks passed: JPEG center crop, single mirror, unique files, visible save-error path. No camera used.")
    } catch { preconditionFailure("Mirror check failed: \(error)") }
}
