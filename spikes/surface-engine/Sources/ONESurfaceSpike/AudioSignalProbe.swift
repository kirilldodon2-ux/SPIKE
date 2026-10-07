import Accelerate
import CoreAudio
import Foundation

// Shared spectrum/tap primitives for the expanded visual and explicit CLI probes.
// Collapsed launch does not capture. PCM stays in a bounded memory window;
// diagnostics print only numeric features, never audio samples.
struct ProbeFeatures: Sendable {
    let rms: Float
    let peak: Float
    let bands: [Float]
    var magnitudes = SIMD3<Float>(repeating: 0)
    var centroid: Float = 0
    var flux: Float = 0
}

final class ProbeSpectrum {
    static let count = 2048
    private let transform: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private var real = [Float](repeating: 0, count: count)
    private var imaginary = [Float](repeating: 0, count: count)
    private var resultReal = [Float](repeating: 0, count: count)
    private var resultImaginary = [Float](repeating: 0, count: count)
    private var power = [Float](repeating: 0, count: count / 2)
    private var previousMagnitude = [Float](repeating: 0, count: count / 2)

    init() throws {
        transform = try vDSP.DiscreteFourierTransform(previous: nil, count: Self.count,
            direction: .forward, transformType: .complexComplex, ofType: Float.self)
        window = (0..<Self.count).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(Self.count - 1)) }
    }

    func features(left: [Float], right: [Float], sampleRate: Double) -> ProbeFeatures {
        let n = Self.count
        var sum: Float = 0
        var peak: Float = 0
        for bin in power.indices { power[bin] = 0 }
        // Sum channel powers, not waveforms: opposite-phase stereo must not cancel.
        for channel in [left, right] {
            for value in channel { sum += value * value; peak = max(peak, abs(value)) }
            for index in 0..<n { real[index] = channel[index] * window[index] }
            transform.transform(inputReal: real, inputImaginary: imaginary,
                outputReal: &resultReal, outputImaginary: &resultImaginary)
            for bin in 1..<n / 2 {
                power[bin] += resultReal[bin] * resultReal[bin]
                    + resultImaginary[bin] * resultImaginary[bin]
            }
        }
        let ranges = [(20.0, 250.0), (250.0, 4000.0), (4000.0, 20000.0)]
        let bands: [Float] = ranges.map { low, high in
            var total: Float = 0
            for bin in 1..<n / 2 {
                let hz = Double(bin) * sampleRate / Double(n)
                if hz >= low && hz < high { total += power[bin] }
            }
            return sqrt(total) / Float(n)
        }
        var magnitudes = SIMD3<Float>(repeating: 0)
        var total: Float = 0, weighted: Float = 0, flux: Float = 0
        for bin in 1..<n / 2 {
            let hz = Float(Double(bin) * sampleRate / Double(n))
            let magnitude = sqrt(power[bin]) / Float(n)
            total += magnitude
            weighted += hz * magnitude
            flux += max(0, magnitude - previousMagnitude[bin])
            previousMagnitude[bin] = magnitude
            if hz >= 20 && hz < 320 { magnitudes[0] += magnitude }
            else if hz >= 320 && hz < 2800 { magnitudes[1] += magnitude }
            else if hz >= 2800 && hz < 11025 { magnitudes[2] += magnitude }
        }
        return ProbeFeatures(rms: sqrt(sum / Float(n * 2)), peak: peak, bands: bands,
            magnitudes: magnitudes, centroid: total > 0 ? min(1, weighted / total / 8000) : 0,
            flux: total > 0 ? min(1, flux / total) : 0)
    }
}

// All fields are confined to ioQueue. This bounded diagnostic mailbox is not
// the final real-time transport: production must avoid synchronous snapshot copies.
private final class ProbeWindow: @unchecked Sendable {
    var left = [Float](repeating: 0, count: ProbeSpectrum.count)
    var right = [Float](repeating: 0, count: ProbeSpectrum.count)
    var cursor = 0
    var frames = 0
    var callbacks = 0
    var invalidSamples = 0

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        callbacks += 1
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return }
        let channels = Int(first.mNumberChannels)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.stride / channels
        let values = data.assumingMemoryBound(to: Float.self)
        let second = buffers.count > 1 ? buffers[1] : nil
        let planarRight = second?.mData?.assumingMemoryBound(to: Float.self)
        let rightCount = Int(second?.mDataByteSize ?? 0) / MemoryLayout<Float>.stride
        for i in 0..<count {
            let l = values[i * channels]
            let r = channels > 1 ? values[i * channels + 1]
                : (planarRight != nil && i < rightCount ? planarRight![i] : l)
            if !l.isFinite || !r.isFinite { invalidSamples += 1 }
            left[cursor] = l.isFinite ? l : 0
            right[cursor] = r.isFinite ? r : 0
            cursor = (cursor + 1) % ProbeSpectrum.count
            frames += 1
        }
    }

    func snapshot() -> (left: [Float], right: [Float], frames: Int, callbacks: Int, invalid: Int) {
        let order = (0..<ProbeSpectrum.count).map { (cursor + $0) % ProbeSpectrum.count }
        return (order.map { left[$0] }, order.map { right[$0] }, frames, callbacks, invalidSamples)
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

private func probeCheck(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw ProbeError(description: "\(action): OSStatus \(status)") }
}

@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var started = false
    let ioQueue = DispatchQueue(label: "local.one.audio-signal-probe.io", qos: .userInteractive)
    fileprivate let window = ProbeWindow()
    private(set) var sampleRate: Double = 0

    func start(consumer: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "ONE audio visual"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try probeCheck(AudioHardwareCreateProcessTap(description, &tap), "create tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try probeCheck(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "read tap format")
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
              format.mSampleRate > 0 else {
            throw ProbeError(description: "unsupported tap format: \(format)")
        }
        sampleRate = format.mSampleRate
        print("signal format: sampleRate=\(sampleRate) channels=\(format.mChannelsPerFrame) float32 flags=\(format.mFormatFlags)")
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ONE temporary audio visual",
            kAudioAggregateDeviceUIDKey: "local.one.signal-probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true]]
        ]
        try probeCheck(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "create aggregate")
        try probeCheck(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, ioQueue) { _, input, _, _, _ in
            consumer(input)
        }, "create IO proc")
        guard let proc else { throw ProbeError(description: "IO proc missing after creation") }
        print("signal: requesting system audio access; microphone and screen are not captured")
        fflush(stdout)
        try probeCheck(AudioDeviceStart(aggregate, proc), "start IO")
        started = true
    }

    @discardableResult func stop() -> Bool {
        func cleanup(_ status: OSStatus, _ name: String) -> Bool {
            if status != noErr { print("signal cleanup error: \(name) OSStatus \(status)"); return false }
            return true
        }
        if let proc {
            if started {
                guard cleanup(AudioDeviceStop(aggregate, proc), "stop IO") else { return false }
                started = false
            }
            guard cleanup(AudioDeviceDestroyIOProcID(aggregate, proc), "destroy IO proc") else { return false }
        }
        proc = nil
        started = false
        if aggregate != kAudioObjectUnknown {
            guard cleanup(AudioHardwareDestroyAggregateDevice(aggregate), "destroy aggregate") else { return false }
        }
        aggregate = AudioObjectID(kAudioObjectUnknown)
        if tap != kAudioObjectUnknown {
            guard cleanup(AudioHardwareDestroyProcessTap(tap), "destroy tap") else { return false }
        }
        tap = AudioObjectID(kAudioObjectUnknown)
        return true
    }
}

// No capture permission or hardware is needed for these checks.
func checkAudioSignalAnalysis() {
    do {
        let analyzer = try ProbeSpectrum()
        let zeros = [Float](repeating: 0, count: ProbeSpectrum.count)
        let silence = analyzer.features(left: zeros, right: zeros, sampleRate: 48000)
        precondition(silence.rms == 0 && silence.peak == 0 && silence.bands.allSatisfy { $0 == 0 })
        for (index, frequency) in [100.0, 1000.0, 8000.0].enumerated() {
            let tone = (0..<ProbeSpectrum.count).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / 48000)) }
            let features = analyzer.features(left: tone, right: tone.map { -$0 }, sampleRate: 48000)
            precondition(abs(features.rms - 0.35355) < 0.01)
            precondition(abs(features.peak - tone.map { abs($0) }.max()!) < 0.00001)
            for other in 0..<3 where other != index {
                precondition(features.bands[index] > 10 * features.bands[other])
            }
        }
        print("Audio signal analysis checks passed (silence, three bands, opposite-phase stereo)")
    } catch { fatalError("Audio analysis check: \(error)") }
}

func runAudioSignalProbe() -> Int32 {
    guard #available(macOS 14.2, *) else { print("signal unavailable: requires macOS 14.2+"); return 1 }
    let probe = SystemAudioTap()
    do {
        let analyzer = try ProbeSpectrum()
        let window = probe.window
        try probe.start { window.consume($0) }
        print("signal: 15-second diagnostic; play/pause audio to compare; no audio files saved")
        var highestRMS: Float = 0
        var previousFrames = 0
        for second in 1...15 {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let snapshot = probe.ioQueue.sync { probe.window.snapshot() }
            let features = analyzer.features(left: snapshot.left, right: snapshot.right, sampleRate: probe.sampleRate)
            highestRMS = max(highestRMS, features.rms)
            let fresh = snapshot.frames > previousFrames
            previousFrames = snapshot.frames
            print(String(format: "signal t=%d callbacks=%d frames=%d fresh=%d rms=%.6f peak=%.6f bass=%.6f mid=%.6f high=%.6f invalid=%d",
                second, snapshot.callbacks, snapshot.frames, fresh ? 1 : 0, features.rms,
                features.peak, features.bands[0], features.bands[1], features.bands[2], snapshot.invalid))
            fflush(stdout)
        }
        let cleaned = probe.stop()
        if highestRMS > 0.00001 && cleaned {
            print("signal: NONZERO AUDIO CONFIRMED; tap and aggregate destroyed")
            return 0
        }
        print("signal: NOT PROVEN (silence, denied access, or no working callbacks); cleanup=\(cleaned)")
        return 2
    } catch {
        print("signal error: \(error)")
        _ = probe.stop()
        return 1
    }
}
