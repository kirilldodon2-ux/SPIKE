import CoreAudio
import Foundation
import os

// Exercises the real worker through its narrow capture seam. Never touches HAL.
private final class LifecycleCheckCapture: VisualAudioCapture, @unchecked Sendable {
    private struct State {
        var starts = 0
        var stops = 0
        var failures = 0
        var alwaysFail = false
        var blocked = false
        var startFails = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    let sampleRate: Double = 48000
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    func configure(failures: Int = 0, alwaysFail: Bool = false, blocked: Bool = false, startFails: Bool = false) {
        state.withLock {
            $0.failures = failures; $0.alwaysFail = alwaysFail
            $0.blocked = blocked; $0.startFails = startFails
        }
    }
    func start(consumer: @escaping @Sendable (UnsafePointer<AudioBufferList>) -> Void) throws {
        let blocked = state.withLock { $0.starts += 1; return $0.blocked }
        entered.signal()
        if blocked { lifecycleWait(release, "release fake start") }
        if state.withLock({ $0.startFails }) { throw NSError(domain: "fake-start", code: 1) }
    }
    func stop() -> Bool {
        let success = state.withLock {
            $0.stops += 1
            if $0.alwaysFail { return false }
            if $0.failures > 0 { $0.failures -= 1; return false }
            return true
        }
        if success { stopped.signal() }
        return success
    }
}

private func lifecycleWait(_ signal: DispatchSemaphore, _ action: String) {
    precondition(signal.wait(timeout: .now() + 3) == .success, "Audio lifecycle check timed out: \(action)")
}

struct LifecycleCheckSnapshot: Sendable {
    let ownsCapture: Bool
    let hasTimer: Bool
}

private extension VisualAudioWorker {
    func snapshotForCheck() -> LifecycleCheckSnapshot {
        let box = OSAllocatedUnfairLock<LifecycleCheckSnapshot?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        inspectForCheck { snapshot in box.withLock { $0 = snapshot }; done.signal() }
        lifecycleWait(done, "worker snapshot")
        return box.withLock { $0! }
    }
    func finishForCheck(expected: Bool = true) {
        let done = DispatchSemaphore(value: 0)
        finish { cleaned in precondition(cleaned == expected); done.signal() }
        lifecycleWait(done, "async finish")
    }
}

func checkVisualAudioLifecycle() {
    // Retry a transient stop error while hidden, with no extra user request.
    do {
        let capture = LifecycleCheckCapture()
        let worker = VisualAudioWorker(makeCapture: { capture })
        worker.start { _, _ in }
        precondition(worker.snapshotForCheck().hasTimer)
        capture.configure(failures: 1)
        worker.stop { preconditionFailure("Transient stop must recover") }
        let retained = worker.snapshotForCheck()
        precondition(retained.ownsCapture && !retained.hasTimer)
        lifecycleWait(capture.stopped, "automatic stop retry")
        precondition(!worker.snapshotForCheck().ownsCapture && capture.stops == 2)
        worker.finishForCheck()
    }
    // Bound permanent failure; a second capture must wait for successful cleanup.
    do {
        let capture = LifecycleCheckCapture()
        let creations = OSAllocatedUnfairLock(initialState: 0)
        let worker = VisualAudioWorker(makeCapture: { creations.withLock { $0 += 1 }; return capture })
        worker.start { _, _ in }
        precondition(worker.snapshotForCheck().hasTimer)
        capture.configure(alwaysFail: true)
        let failed = DispatchSemaphore(value: 0)
        worker.stop { failed.signal() }
        lifecycleWait(failed, "bounded permanent stop failure")
        precondition(capture.stops == 4 && worker.snapshotForCheck().ownsCapture)
        let blocked = DispatchSemaphore(value: 0)
        worker.start { _, diagnostic in if diagnostic?.contains("освободить") == true { blocked.signal() } }
        lifecycleWait(blocked, "retained capture blocks second start")
        precondition(capture.stops == 8 && capture.starts == 1 && creations.withLock { $0 } == 1)
        capture.configure()
        worker.start { _, _ in }
        precondition(worker.snapshotForCheck().hasTimer && capture.starts == 2)
        worker.finishForCheck()
        precondition(!worker.snapshotForCheck().ownsCapture)
    }
    // Inspect after blocked start returns, before queued cleanup. A cancelled
    // start must never install a timer, rather than simply cancelling it later.
    do {
        let capture = LifecycleCheckCapture(); capture.configure(blocked: true)
        let worker = VisualAudioWorker(makeCapture: { capture })
        let deliveries = OSAllocatedUnfairLock(initialState: 0)
        worker.start { _, _ in deliveries.withLock { $0 += 1 } }
        lifecycleWait(capture.entered, "blocked fake start entered")
        let snapshot = OSAllocatedUnfairLock<LifecycleCheckSnapshot?>(initialState: nil)
        let observed = DispatchSemaphore(value: 0)
        worker.inspectForCheck { state in snapshot.withLock { $0 = state }; observed.signal() }
        worker.stop { preconditionFailure("Cancelled start cleanup should succeed") }
        let finished = DispatchSemaphore(value: 0)
        worker.finish { cleaned in precondition(cleaned); finished.signal() }
        // Caller has returned although fake start still holds the worker.
        precondition(finished.wait(timeout: .now() + 0.03) == .timedOut)
        capture.release.signal()
        lifecycleWait(observed, "post-start pre-cleanup snapshot")
        precondition(snapshot.withLock { $0!.ownsCapture && !$0!.hasTimer })
        lifecycleWait(finished, "finish after delayed start")
        precondition(!worker.snapshotForCheck().ownsCapture && deliveries.withLock { $0 } == 0)
        worker.start { _, _ in preconditionFailure("Quit must reject new capture") }
        precondition(!worker.snapshotForCheck().ownsCapture && capture.starts == 1)
    }
    // A superseded retry must never cancel a newer successful run.
    do {
        let capture = LifecycleCheckCapture()
        let worker = VisualAudioWorker(makeCapture: { capture })
        worker.start { _, _ in }
        precondition(worker.snapshotForCheck().hasTimer)
        capture.configure(failures: 1)
        worker.stop { preconditionFailure("Superseded stop must not report") }
        precondition(!worker.snapshotForCheck().hasTimer)
        worker.start { _, _ in }
        precondition(worker.snapshotForCheck().hasTimer && capture.starts == 2)
        let oldRetryElapsed = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { oldRetryElapsed.signal() }
        lifecycleWait(oldRetryElapsed, "old retry deadline")
        precondition(worker.snapshotForCheck().hasTimer && capture.stops == 2)
        worker.finishForCheck()
    }
    // Failed partial setup cleans up with retries, without auto-starting again.
    do {
        let capture = LifecycleCheckCapture(); capture.configure(failures: 1, startFails: true)
        let worker = VisualAudioWorker(makeCapture: { capture })
        let failed = DispatchSemaphore(value: 0)
        worker.start { _, diagnostic in if diagnostic != nil { failed.signal() } }
        lifecycleWait(failed, "failed start cleanup retry")
        let state = worker.snapshotForCheck()
        precondition(!state.ownsCapture && !state.hasTimer && capture.stops == 2 && capture.starts == 1)
        worker.finishForCheck()
    }
    print("Audio lifecycle checks passed: transient retry, permanent cap/ownership, recovered start, delayed cancel, async quit, stale retry, partial setup; fake capture only")
}
