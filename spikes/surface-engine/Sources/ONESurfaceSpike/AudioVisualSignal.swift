import AppKit
import CoreAudio
import os

struct VisualAudioFrame: Sendable {
    var energy: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    var onset: Float = 0
    var hue: Float = 0.5
    var character: Float = 0
    var timestamp: TimeInterval = 0

    func fresh(at time: TimeInterval) -> VisualAudioFrame {
        time - timestamp < 0.25 ? self : VisualAudioFrame()
    }
}

// Dual envelopes follow the documented Butterchurn/MilkDrop AudioLevels model.
// Swift implementation, stereo magnitude input and transient/color mapping are
// ONE's own. See Resources/AudioVisualReferences-LICENSE.txt for attribution.
struct VisualReactivity {
    private var fast = SIMD3<Float>(repeating: 0)
    private var long = SIMD3<Float>(repeating: 0)
    private var frame = VisualAudioFrame()
    private var fluxAverage: Float = 0
    private var lastOnset: TimeInterval = -1
    private var previousBass: Float = 0
    private var count = 0
    private var lastTime: TimeInterval = 0

    mutating func update(_ measured: ProbeFeatures, at time: TimeInterval) -> VisualAudioFrame {
        let dt = Float(lastTime == 0 ? 1.0 / 30 : min(0.1, max(0.001, time - lastTime)))
        lastTime = time
        let sounding = measured.rms > 0.001
        let values = sounding ? measured.magnitudes : .zero
        var relative = SIMD3<Float>(repeating: 0)
        for band in 0..<3 {
            let retention = pow(values[band] > fast[band] ? Float(0.2) : Float(0.5), dt * 30)
            fast[band] = fast[band] * retention + values[band] * (1 - retention)
            // Initialize from the first real spectrum; don't exaggerate startup.
            if long[band] == 0 { long[band] = values[band] }
            let slow = pow(count < 50 ? Float(0.9) : Float(0.992), dt * 30)
            long[band] = long[band] * slow + values[band] * (1 - slow)
            relative[band] = sounding && long[band] > 0.0001
                ? min(3, values[band] / long[band]) : 0
        }
        count += 1
        let threshold = fluxAverage * 1.6 + 0.025
        let totalMagnitude = values.x + values.y + values.z
        // A kick may be masked by a dense full-spectrum mix. Detect its rising
        // bass envelope independently; sustained bass must not retrigger it.
        let bassAttack = relative.x > 1.3 && relative.x - previousBass > 0.25
            && values.x > totalMagnitude * 0.15
        let hit = sounding && (measured.flux > threshold || bassAttack) && time - lastOnset > 0.11
        previousBass = relative.x
        if hit {
            lastOnset = time
            frame.onset = min(1, max(0.45, (measured.flux - fluxAverage) * 2 + max(0, relative.x - 1) * 0.4))
        } else { frame.onset *= exp(-dt * 11) }
        fluxAverage += (measured.flux - fluxAverage) * (1 - exp(-dt * 3))
        let energy = sounding ? min(1, sqrt(max(0, measured.rms - 0.001)) * 2.4) : 0
        let rate = 1 - exp(-dt * (energy > frame.energy ? 50 : 16))
        frame.energy += (energy - frame.energy) * rate
        frame.bass = relative.x * 0.7 + (sounding && long.x > 0.0001 ? min(3, fast.x / long.x) * 0.3 : 0)
        frame.mid = sounding && long.y > 0.0001 ? min(3, fast.y / long.y) : 0
        frame.high = relative.z
        if sounding {
            let balance = measured.bands.reduce(0, +)
            let highShare = balance > 0 ? measured.bands[2] / balance : 0
            let midShare = balance > 0 ? measured.bands[1] / balance : 0
            let character = min(1, measured.centroid * 1.5 + highShare * 0.4)
            let hue = 0.06 + measured.centroid * 0.55 + midShare * 0.35 + highShare * 0.2
            let colorRate = 1 - exp(-dt * 1.4)
            frame.hue += (hue - frame.hue) * colorRate
            frame.character += (character - frame.character) * colorRate
        }
        if !sounding { frame.onset = 0 }
        frame.timestamp = time
        return frame
    }
}

func checkVisualReactivity() {
    var model = VisualReactivity()
    let steady = ProbeFeatures(rms: 0.08, peak: 0.2, bands: [0.04, 0.02, 0.003],
        magnitudes: SIMD3(0.2, 0.12, 0.03), centroid: 0.12, flux: 0)
    var base = VisualAudioFrame()
    for i in 0..<80 { base = model.update(steady, at: 1 + Double(i) / 30) }
    var hit = steady
    hit.magnitudes.x *= 3
    hit.flux = 0.6
    let burst = model.update(hit, at: 4)
    precondition(burst.onset >= 0.45 && burst.bass > base.bass * 1.5)
    var kickModel = VisualReactivity()
    for i in 0..<80 { _ = kickModel.update(steady, at: 1 + Double(i) / 30) }
    var kick = steady
    kick.magnitudes.x *= 3 // No broadband flux: bass-only attack must still hit.
    let kickFrame = kickModel.update(kick, at: 4)
    precondition(base.onset == 0 && kickFrame.onset >= 0.45)
    let heldBass = kickModel.update(kick, at: 4.15)
    precondition(heldBass.onset < kickFrame.onset)
    let quiet = ProbeFeatures(rms: 0, peak: 0, bands: [0, 0, 0])
    var silence = VisualAudioFrame()
    for i in 1...30 { silence = model.update(quiet, at: 4 + Double(i) / 30) }
    precondition(silence.energy < 0.001 && silence.onset == 0 && silence.bass == 0)
    precondition(burst.fresh(at: 5).energy == 0)
    var brightModel = VisualReactivity()
    let bright = ProbeFeatures(rms: 0.08, peak: 0.2, bands: [0.001, 0.01, 0.1],
        magnitudes: SIMD3(0.02, 0.12, 0.3), centroid: 0.75, flux: 0)
    var brightFrame = VisualAudioFrame()
    for i in 0..<80 { brightFrame = brightModel.update(bright, at: 1 + Double(i) / 30) }
    precondition(brightFrame.character > base.character + 0.4 && abs(brightFrame.hue - base.hue) > 0.15)
    print("Visual reactivity checks passed: bass-only kick, no sustained-bass retrigger, spectral onset, silence, stale frame, palette")
}

// A contended producer drops a buffer instead of waiting for analysis/UI.
// The sample storage has one owner and is never returned to a consumer.
private final class VisualAudioMailbox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: ProbeSpectrum.count * 2)
    private var cursor = 0
    private var frames: UInt64 = 0

    init() { samples.initialize(repeating: 0, count: ProbeSpectrum.count * 2) }
    deinit { samples.deinitialize(count: ProbeSpectrum.count * 2); samples.deallocate() }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard lock.lockIfAvailable() else { return }
        defer { lock.unlock() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = Int(first.mNumberChannels)
        guard channels == 1 || channels == 2 else { return }
        let left = data.assumingMemoryBound(to: Float.self)
        let second = buffers.count > 1 ? buffers[1] : nil
        let right = second?.mData?.assumingMemoryBound(to: Float.self)
        let rightCount = Int(second?.mDataByteSize ?? 0) / MemoryLayout<Float>.stride
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.stride / channels
        if channels == 1 && (right == nil || rightCount < count) { return }
        for i in 0..<count {
            let l = left[i * channels]
            let r = channels == 2 ? left[i * 2 + 1] : right![i]
            samples[cursor * 2] = l.isFinite ? l : 0
            samples[cursor * 2 + 1] = r.isFinite ? r : 0
            cursor = (cursor + 1) % ProbeSpectrum.count
        }
        frames &+= UInt64(count)
    }

    func copy(into left: inout [Float], right: inout [Float]) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<ProbeSpectrum.count {
            let index = (cursor + i) % ProbeSpectrum.count
            left[i] = samples[index * 2]
            right[i] = samples[index * 2 + 1]
        }
        return frames
    }
}

// Narrow capture seam for lifecycle checks; all implementations stay worker-owned.
protocol VisualAudioCapture: AnyObject {
    var sampleRate: Double { get }
    func start(consumer: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void) throws
    @discardableResult func stop() -> Bool
}

@available(macOS 14.2, *)
extension SystemAudioTap: VisualAudioCapture {}

final class VisualAudioWorker: @unchecked Sendable {
    private struct Intent {
        var revision: UInt64 = 0
        var terminating = false
    }
    private let intent = OSAllocatedUnfairLock(initialState: Intent())
    private let queue = DispatchQueue(label: "local.one.visual-audio", qos: .userInitiated)
    private let makeCapture: @Sendable () throws -> any VisualAudioCapture
    private static let retryDelays: [Double] = [0.1, 0.3, 0.8]
    // Capture/analysis/timer state belongs to queue. Only intent crosses queues.
    private var tap: (any VisualAudioCapture)?
    private var timer: DispatchSourceTimer?

    init(makeCapture: @escaping @Sendable () throws -> any VisualAudioCapture = {
        guard #available(macOS 14.2, *) else {
            throw NSError(domain: "SPIKE.Audio", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Нужна macOS 14.2+"])
        }
        return SystemAudioTap()
    }) { self.makeCapture = makeCapture }

    private func request() -> UInt64? {
        intent.withLock {
            guard !$0.terminating else { return nil }
            $0.revision &+= 1
            return $0.revision
        }
    }

    private func isCurrent(_ request: UInt64) -> Bool {
        intent.withLock { $0.revision == request }
    }

    func start(deliver: @escaping @Sendable (VisualAudioFrame, String?) -> Void) {
        guard let request = request() else { return }
        queue.async { [self] in
            cleanUp(request: request) { [self] cleaned in
                guard cleaned else {
                    deliver(.init(), "Не удалось освободить аудиовход · перезапусти SPIKE")
                    return
                }
                begin(request: request, deliver: deliver)
            }
        }
    }

    private func begin(request: UInt64,
                       deliver: @escaping @Sendable (VisualAudioFrame, String?) -> Void) {
        guard isCurrent(request) else { return }
        do {
            let capture = try makeCapture()
            let mailbox = VisualAudioMailbox()
            let analyzer = try ProbeSpectrum()
            guard isCurrent(request) else { return }
            tap = capture
            try capture.start { mailbox.consume($0) }
            // A stop/quit can arrive while synchronous HAL setup holds queue.
            // Its queued cleanup owns these resources; don't install a late timer.
            guard isCurrent(request) else { return }
            var left = [Float](repeating: 0, count: ProbeSpectrum.count)
            var right = left
            var lastFrames: UInt64 = 0
            var model = VisualReactivity()
            let began = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(3))
            timer.setEventHandler { [self] in
                guard isCurrent(request) else { return }
                let time = ProcessInfo.processInfo.systemUptime
                let frames = mailbox.copy(into: &left, right: &right)
                guard frames > lastFrames else {
                    deliver(.init(), time - began > 5 ? "Ждём системный звук" : "Ждём аудио")
                    return
                }
                lastFrames = frames
                let measured = analyzer.features(left: left, right: right, sampleRate: capture.sampleRate)
                deliver(model.update(measured, at: time), nil)
            }
            self.timer = timer
            timer.resume()
        } catch {
            let message = "Аудиовход недоступен: \(error.localizedDescription)"
            cleanUp(request: request) { _ in deliver(.init(), message) }
        }
    }

    func stop(reportFailure: @escaping @Sendable () -> Void) {
        guard let request = request() else { return }
        queue.async { [self] in
            cleanUp(request: request) { cleaned in if !cleaned { reportFailure() } }
        }
    }

    private func cleanUp(request: UInt64, attempt: Int = 0,
                         completion: @escaping @Sendable (Bool) -> Void) {
        guard isCurrent(request) else { return }
        let cleaned = stopOnQueue()
        guard isCurrent(request) else { return }
        if cleaned { completion(true); return }
        guard attempt < Self.retryDelays.count else { completion(false); return }
        queue.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [self] in
            cleanUp(request: request, attempt: attempt + 1, completion: completion)
        }
    }

    @discardableResult private func stopOnQueue() -> Bool {
        timer?.cancel()
        timer = nil
        if let tap, !tap.stop() { return false }
        tap = nil
        return true
    }

    // Never wait on queue from main. Resources remain owned even after the app's
    // audio quit deadline; process termination doesn't force unsafe HAL teardown.
    func finish(completion: @escaping @Sendable (Bool) -> Void) {
        let request = intent.withLock {
            if !$0.terminating { $0.revision &+= 1; $0.terminating = true }
            return $0.revision
        }
        queue.async { [self] in cleanUp(request: request, completion: completion) }
    }
}

// Read-only observation for the explicit no-capture self-check, on the owner queue.
extension VisualAudioWorker {
    func inspectForCheck(_ completion: @escaping @Sendable (LifecycleCheckSnapshot) -> Void) {
        queue.async { [self] in completion(.init(ownsCapture: tap != nil, hasTimer: timer != nil)) }
    }
}

@MainActor final class AudioVisualController: ObservableObject {
    @Published private(set) var enabled = true
    @Published private(set) var diagnostic: String?
    @Published var strength: Float = 0.65
    private(set) var frame = VisualAudioFrame()
    private let worker = VisualAudioWorker()
    private var visible = false
    private var running = false
    private var terminating = false
    private var generation = 0

    func toggle() {
        enabled.toggle()
        reconcile()
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        reconcile()
    }

    private func reconcile() {
        let shouldRun = visible && enabled && !terminating
        guard shouldRun != running else { return }
        running = shouldRun
        generation += 1
        let run = generation
        frame = .init()
        diagnostic = shouldRun ? "Ждём аудио" : nil
        if shouldRun {
            worker.start { [weak self] frame, diagnostic in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == run, self.running else { return }
                    self.frame = frame
                    if self.diagnostic != diagnostic { self.diagnostic = diagnostic }
                }
            }
        } else {
            worker.stop { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == run else { return }
                    self.diagnostic = "Не удалось остановить аудиовход · перезапусти SPIKE"
                }
            }
        }
    }

    func rendererFailed(_ message: String) {
        enabled = false
        reconcile()
        diagnostic = message
    }

    func finish(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        terminating = true
        running = false
        generation += 1
        frame = .init()
        worker.finish { cleaned in Task { @MainActor in completion(cleaned) } }
    }
}

@MainActor func runVisualAudioProbe() -> Int32 {
    let controller = AudioVisualController()
    controller.setVisible(true)
    var highestEnergy: Float = 0
    for second in 1...12 {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let frame = controller.frame.fresh(at: ProcessInfo.processInfo.systemUptime)
        highestEnergy = max(highestEnergy, frame.energy)
        print("visual signal t=\(second) energy=\(frame.energy) bass=\(frame.bass) status=\(controller.diagnostic ?? "live")")
        fflush(stdout)
    }
    controller.setVisible(false)
    var cleaned: Bool?
    controller.finish { cleaned = $0 }
    let deadline = Date().addingTimeInterval(2)
    while cleaned == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    print("visual signal: hidden, cleanup=\(cleaned.map(String.init) ?? "timed out"), nonzero=\(highestEnergy > 0)")
    return cleaned == true ? (highestEnergy > 0 ? 0 : 2) : 1
}
