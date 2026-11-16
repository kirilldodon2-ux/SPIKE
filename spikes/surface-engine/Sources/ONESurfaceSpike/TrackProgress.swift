import CoreFoundation
import SwiftUI

/// One source sample projected on the monotonic clock. Never retain progress
/// across a source change or estimate it from the public audio fallback.
struct TrackProgress {
    let duration: TimeInterval
    let position: TimeInterval
    let sampledAt: TimeInterval
    let rate: Double

    func elapsed(at now: TimeInterval) -> TimeInterval {
        min(duration, position + max(0, now - sampledAt) * rate)
    }

    static func sample(duration: TimeInterval, position: TimeInterval,
                       at time: TimeInterval, rate: Double) -> TrackProgress? {
        guard duration.isFinite, duration >= 1, duration <= 604_800,
              position.isFinite, (0...duration).contains(position),
              time.isFinite, rate.isFinite, (0...4).contains(rate) else { return nil }
        return .init(duration: duration, position: position, sampledAt: time, rate: rate)
    }

    static func decode(_ payload: [String: Any], playing: Bool,
                       receivedAt: Date, uptime: TimeInterval) -> TrackProgress? {
        func number(_ key: String) -> Double? {
            guard let value = payload[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        guard let duration = number("duration"), duration > 0, duration <= 604_800,
              let position = number("elapsedTime"), (0...duration).contains(position) else { return nil }
        var rate = 0.0
        var age = 0.0
        if playing {
            if payload["playbackRate"] != nil {
                guard let value = number("playbackRate"), value > 0, value <= 4 else { return nil }
                rate = value
            } else { rate = 1 }
            guard let raw = payload["timestamp"] as? String,
                  let date = try? Date.ISO8601FormatStyle().parse(raw) else { return nil }
            age = receivedAt.timeIntervalSince(date)
            guard age >= -2 else { return nil }
        } else if payload["playbackRate"] != nil {
            // A pause notification can precede the matching metadata update.
            guard number("playbackRate") == 0 else { return nil }
        }
        return sample(duration: duration, position: position, at: uptime - max(0, age), rate: rate)
    }

    static func label(_ seconds: TimeInterval) -> String {
        let seconds = Int(seconds)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct TrackProgressView: View {
    let progress: TrackProgress
    let active: Bool
    let canSeek: Bool
    let enableSeeking: (() -> Void)?
    typealias Seek = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    let seek: Seek
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceAppearance) private var appearance
    @State private var hover = false
    @State private var dragPosition: TimeInterval?
    @State private var pendingPosition: TimeInterval?

    init(progress: TrackProgress, active: Bool, canSeek: Bool,
         enableSeeking: (() -> Void)?, seek: @escaping Seek) {
        self.progress = progress
        self.active = active
        self.canSeek = canSeek
        self.enableSeeking = enableSeeking
        self.seek = seek
    }

    var body: some View {
        let now = ProcessInfo.processInfo.systemUptime
        if active && progress.rate > 0 && progress.elapsed(at: now) < progress.duration {
            TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.2)) { _ in
                row(at: ProcessInfo.processInfo.systemUptime)
            }
        } else {
            row(at: now)
        }
    }

    private func row(at now: TimeInterval) -> some View {
        let elapsed = dragPosition ?? pendingPosition ?? progress.elapsed(at: now)
        let current = TrackProgress.label(elapsed)
        let total = TrackProgress.label(progress.duration)
        return Group {
            if canSeek {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let x = width * elapsed / progress.duration
                        ZStack(alignment: .leading) {
                            Capsule().fill(appearance.primary.opacity(0.20))
                            Capsule().fill(appearance.primary.opacity(0.82)).frame(width: x)
                            if hover || dragPosition != nil || pendingPosition != nil {
                                Circle().fill(appearance.primary)
                                    .frame(width: 6, height: 6).offset(x: min(max(0, x - 3), max(0, width - 6)))
                            }
                        }
                        .frame(height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                guard pendingPosition == nil else { return }
                                dragPosition = position(at: gesture.location.x, width: width)
                            }
                            .onEnded { gesture in
                                dragPosition = nil
                                if let value = position(at: gesture.location.x, width: width) { commit(value) }
                            })
                    }
                    .frame(height: 13)
                    times(current, total)
                }
                .onHover { hover = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Позиция трека")
                .accessibilityValue("\(current) из \(total)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: commit(elapsed + 5)
                    case .decrement: commit(elapsed - 5)
                    @unknown default: break
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text("\(current) / \(total)")
                    Spacer(minLength: 0)
                    if let enableSeeking {
                        Button(action: enableSeeking) {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Включить перемотку для этого плеера")
                        .accessibilityLabel("Включить перемотку для этого плеера")
                    }
                }
                .accessibilityLabel("Прогресс воспроизведения")
                .accessibilityValue("\(current) из \(total)")
            }
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(appearance.secondary)
        .frame(maxWidth: 200)
        .onChange(of: canSeek) { _, enabled in
            if !enabled { dragPosition = nil; pendingPosition = nil }
        }
    }

    private func times(_ current: String, _ total: String) -> some View {
        HStack { Text(current); Spacer(minLength: 0); Text(total) }
    }

    private func position(at x: CGFloat, width: CGFloat) -> TimeInterval? {
        guard width > 0 else { return nil }
        return progress.duration * min(1, max(0, x / width))
    }

    private func commit(_ value: TimeInterval) {
        guard active, canSeek, pendingPosition == nil else { return }
        let target = min(progress.duration - 0.25, max(0, value))
        pendingPosition = target
        seek(target) { pendingPosition = nil }
    }
}

func checkTrackProgress() {
    let now = Date(timeIntervalSince1970: 1_000)
    let payload: [String: Any] = ["duration": 120.0, "elapsedTime": 10.5,
        "timestamp": "1970-01-01T00:16:38Z", "playbackRate": 1.5]
    let playing = TrackProgress.decode(payload, playing: true, receivedAt: now, uptime: 80)!
    precondition(playing.elapsed(at: 80) == 13.5 && playing.elapsed(at: 81) == 15)
    precondition(playing.elapsed(at: 200) == 120)
    precondition(TrackProgress.decode(payload, playing: false, receivedAt: now, uptime: 80) == nil)
    var pausedPayload = payload; pausedPayload["playbackRate"] = 0
    let paused = TrackProgress.decode(pausedPayload, playing: false, receivedAt: now, uptime: 80)!
    precondition(paused.elapsed(at: 100) == 10.5)
    var bad = pausedPayload
    for value: Any in [true, Double.nan, 0, -1] {
        bad["duration"] = value
        precondition(TrackProgress.decode(bad, playing: false, receivedAt: now, uptime: 80) == nil)
    }
    bad = pausedPayload; bad["elapsedTime"] = 121
    precondition(TrackProgress.decode(bad, playing: false, receivedAt: now, uptime: 80) == nil)
    bad = payload; bad["timestamp"] = "invalid"
    precondition(TrackProgress.decode(bad, playing: true, receivedAt: now, uptime: 80) == nil)
    precondition(TrackProgress.label(3601) == "1:00:01")
    print("Track progress checks passed: play/pause, anchored time/rate, clamp, malformed and missing timing.")
}
