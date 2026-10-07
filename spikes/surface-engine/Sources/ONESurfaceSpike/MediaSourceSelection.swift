import Foundation

/// Playing music > browser media > other players. Rank live metadata, never
/// infer titles or playback state from a raw audio stream or foreground app.
struct MediaSourceSelection {
    static let handoffGrace: TimeInterval = 5
    static let independentFreshness: TimeInterval = 4
    private var lastTrack: AmbientMediaSnapshot?
    private var missingMetadataSince: TimeInterval?
    private var freshDeadline: TimeInterval?
    private var artworkCache: [String: AmbientMediaSnapshot] = [:]

    var recheckDeadline: TimeInterval? {
        let handoff = lastTrack == nil ? nil : missingMetadataSince.map { $0 + Self.handoffGrace }
        return [freshDeadline, handoff].compactMap { $0 }.min()
    }

    mutating func select(media: AmbientMediaSnapshot, audio: AmbientMediaSnapshot,
                         runningSources: Set<String>, now: TimeInterval,
                         independent: [AmbientMediaSnapshot] = []) -> AmbientMediaSnapshot {
        freshDeadline = nil
        artworkCache = artworkCache.filter { runningSources.contains($0.key) }
        if media.hasTrackMetadata, let source = media.sourceBundleIdentifier,
           runningSources.contains(source), media.artwork != nil {
            artworkCache[source] = media
            if artworkCache.count > 8 { artworkCache = [source: media] }
        }
        var candidates = independent.filter {
            guard let source = $0.sourceBundleIdentifier, runningSources.contains(source),
                  let readAt = $0.independentReadAt, now >= readAt, now - readAt < Self.independentFreshness else { return false }
            return $0.independentlyRead && $0.hasTrackMetadata && !$0.metadataIsRetained
                && ($0.state == .playing || $0.state == .paused)
        }
        if let source = media.sourceBundleIdentifier, runningSources.contains(source),
           media.hasTrackMetadata, media.state == .playing || media.state == .paused,
           !candidates.contains(where: { $0.sourceBundleIdentifier == source }) {
            candidates.append(media)
        }
        // Paused music does not pin the surface over another playing source.
        let playing = candidates.filter { $0.state == .playing }
        let eligible = playing.isEmpty ? candidates : playing
        if let bestPriority = eligible.map(Self.priority).max() {
            let top = eligible.filter { Self.priority($0) == bestPriority }
            var chosen = top.first { $0.sourceBundleIdentifier == media.sourceBundleIdentifier }
                ?? top.first { $0.sourceBundleIdentifier == lastTrack?.sourceBundleIdentifier }
                ?? top[0]
            if chosen.artwork == nil, let source = chosen.sourceBundleIdentifier,
               let artwork = artworkCache[source], artwork.title == chosen.title,
               artwork.subtitle == chosen.subtitle {
                chosen.artwork = artwork.artwork
                chosen.visualPalette = artwork.visualPalette
            }
            // Independent state remains refreshed by its own public adapter,
            // even while macOS chooses QuickTime as its default control target.
            lastTrack = chosen
            missingMetadataSince = nil
            if chosen.independentlyRead, let readAt = chosen.independentReadAt {
                freshDeadline = readAt + Self.independentFreshness
            }
            return chosen
        }

        guard let source = media.sourceBundleIdentifier, runningSources.contains(source),
              media.state == .playing || media.state == .paused else {
            lastTrack = nil
            missingMetadataSince = nil
            return media.state == .idle && audio.state == .audioIdle ? .idle : audio
        }

        // Some clients publish their identity before title/artwork. Smooth that
        // handoff only while the previous playing app still has public output.
        // Expire it: this helper cannot refresh a nonselected player's track.
        if let previous = lastTrack, previous.state == .playing, !previous.independentlyRead,
           let previousSource = previous.sourceBundleIdentifier,
           runningSources.contains(previousSource), audio.state == .audioActive,
           audio.audioSourceBundleIdentifiers.contains(where: {
               $0 == previousSource || $0.hasPrefix(previousSource + ".")
           }) {
            let since = missingMetadataSince ?? now
            missingMetadataSince = since
            if now - since < Self.handoffGrace {
                var retained = previous
                retained.metadataIsRetained = true
                return retained
            }
        }
        lastTrack = nil
        // Keep the grace start until genuine metadata returns; repeated untitled
        // snapshots must not restart a window of stale track information.
        return media
    }

    static func priority(_ snapshot: AmbientMediaSnapshot) -> Int {
        let id = snapshot.sourceBundleIdentifier?.lowercased() ?? ""
        if snapshot.isMusicSource || id == "com.spotify.client" || id == "com.apple.music" { return 3 }
        if ["com.apple.safari", "com.google.chrome", "com.microsoft.edgemac", "org.mozilla.firefox",
            "company.thebrowser.browser", "company.thebrowser.dia", "app.zen-browser.zen"].contains(id) { return 2 }
        return 1
    }

    static func canControl(_ selected: AmbientMediaSnapshot, current: AmbientMediaSnapshot) -> Bool {
        !selected.metadataIsRetained && !selected.independentlyRead && selected.sourceBundleIdentifier != nil
            && selected.sourceBundleIdentifier == current.sourceBundleIdentifier
            && (selected.state == .playing || selected.state == .paused)
            && (current.state == .playing || current.state == .paused)
    }
}

@MainActor func checkMediaSourceSelection() {
    func track(_ source: String, _ title: String, _ state: AmbientPlaybackState = .playing) -> AmbientMediaSnapshot {
        var value = AmbientMediaSnapshot(state: state, title: title, sourceName: source, artwork: nil)
        value.sourceBundleIdentifier = source
        value.hasTrackMetadata = true
        return value
    }
    var music = track("test.music", "Music track")
    let video = track("test.browser", "Video title")
    var noise = AudioActivityAdapter.snapshot(sources: ["Game"], failed: false)
    noise.audioSourceBundleIdentifiers = ["test.game"]
    let running: Set<String> = ["test.music", "test.browser", "test.game"]
    var policy = MediaSourceSelection()
    func select(_ media: AmbientMediaSnapshot, _ audio: AmbientMediaSnapshot = noise,
                at time: TimeInterval = 0, apps: Set<String> = running) -> AmbientMediaSnapshot {
        policy.select(media: media, audio: audio, runningSources: apps, now: time)
    }
    precondition(select(music).title == "Music track")
    music.state = .paused
    let paused = select(music)
    precondition(paused.title == "Music track" && paused.state == .paused)
    precondition(MediaSourceSelection.canControl(paused, current: music))
    precondition(select(video).sourceBundleIdentifier == "test.browser")

    music.state = .playing
    _ = select(music)
    var untagged = track("test.game", "Game")
    untagged.hasTrackMetadata = false
    var mix = noise
    mix.audioSourceBundleIdentifiers = ["test.game", "test.music.helper"]
    let retained = select(untagged, mix, at: 10)
    precondition(retained.title == "Music track" && retained.metadataIsRetained)
    precondition(policy.recheckDeadline == 15)
    precondition(!MediaSourceSelection.canControl(retained, current: untagged))
    precondition(select(untagged, mix, at: 14).metadataIsRetained)
    precondition(!select(untagged, mix, at: 15).metadataIsRetained)
    precondition(policy.recheckDeadline == nil)
    precondition(select(untagged, mix, at: 16).sourceBundleIdentifier == "test.game")

    _ = select(music)
    precondition(select(untagged).sourceBundleIdentifier == "test.game") // Previous output stopped.
    _ = select(music)
    precondition(select(music, apps: ["test.game"]).state == .audioActive) // Source quit.
    _ = select(music)
    precondition(select(.unavailable).state == .audioActive) // Failure/disable clears cache.
    precondition(select(.idle, .init(state: .audioIdle, title: "", artwork: nil)).state == .idle)
    precondition(select(.unavailable, .unavailable).state == .unavailable)
    _ = select(music)
    _ = select(untagged, mix, at: 20)
    let recovered = select(video, mix, at: 21)
    precondition(!recovered.metadataIsRetained && recovered.title == "Video title")
    precondition(MediaSourceSelection.canControl(recovered, current: video))

    let spotify = "com.spotify.client", quicktime = "com.apple.QuickTimePlayerX"
    var direct = track(spotify, "Fresh Spotify track")
    direct.independentlyRead = true; direct.independentReadAt = 100; direct.trackIdentifier = "spotify:track:a"
    let movie = track(quicktime, "Local movie")
    let browser = track("com.apple.Safari", "YouTube video")
    let apps: Set<String> = [spotify, quicktime, "com.apple.Safari", "com.apple.Music"]
    var ranked = MediaSourceSelection()
    func rank(_ current: AmbientMediaSnapshot, _ players: [AmbientMediaSnapshot], at now: TimeInterval = 100,
              running: Set<String> = apps) -> AmbientMediaSnapshot {
        ranked.select(media: current, audio: mix, runningSources: running, now: now, independent: players)
    }
    let preferred = rank(movie, [direct])
    precondition(preferred.sourceBundleIdentifier == spotify && preferred.title == "Fresh Spotify track")
    precondition(ranked.recheckDeadline == 104)
    precondition(!MediaSourceSelection.canControl(preferred, current: movie))
    direct.title = "Next Spotify track"; direct.trackIdentifier = "spotify:track:b"; direct.independentReadAt = 101
    precondition(rank(movie, [direct], at: 101).title == "Next Spotify track")
    precondition(rank(browser, [direct], at: 101).sourceBundleIdentifier == spotify)
    direct.state = .paused
    precondition(rank(movie, [direct], at: 101).sourceBundleIdentifier == quicktime)
    precondition(rank(browser, [direct], at: 101).sourceBundleIdentifier == "com.apple.Safari")
    var pausedMovie = movie; pausedMovie.state = .paused
    precondition(rank(pausedMovie, [direct], at: 101).sourceBundleIdentifier == spotify)
    direct.state = .playing
    precondition(rank(movie, [direct], at: 105).sourceBundleIdentifier == quicktime) // Expired independent reading.
    precondition(rank(movie, [direct], at: 101, running: [quicktime]).sourceBundleIdentifier == quicktime)
    precondition(rank(.unavailable, [direct], at: 101).sourceBundleIdentifier == spotify) // Optional helper failed.
    precondition(rank(movie, [], at: 101).sourceBundleIdentifier == quicktime) // Permission/read failure clears.
    var stream = track("test.streaming", "Streaming track"); stream.isMusicSource = true
    precondition(MediaSourceSelection.priority(stream) > MediaSourceSelection.priority(browser))
    print("Media selection checks passed: music > browser > local, playing > paused, independent track refresh/expiry/quit/failure, bounded untitled handoff and transport routing.")
}
