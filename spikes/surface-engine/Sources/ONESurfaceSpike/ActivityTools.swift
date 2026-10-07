import AppKit
import SwiftUI

enum SurfaceContentMode: String, CaseIterable {
    case media = "Now Playing"
    case mirror = "Mirror"

    var symbol: String { self == .media ? "waveform" : "camera" }
}

@MainActor private func selectSurfaceMode(_ mode: SurfaceContentMode, state: SurfaceState) {
    guard state.contentMode != mode else { return }
    if state.contentMode == .mirror { state.mirror.deactivate() }
    state.contentMode = mode
    state.updateVisualVisibility()
}

/// Each expanded wing is one target, including the artwork/identity below this
/// overlay. The notch gap and collapsed identity keep their existing behavior.
struct SurfaceSideTabs: View {
    @ObservedObject var state: SurfaceState
    let progress: CGFloat
    let width: CGFloat

    var body: some View {
        let tabWidth = SurfaceLayout.sideTabWidth(surfaceWidth: width,
            anchorWidth: state.gap + 2 * SurfaceLayout.wingWidth)
        let zoneWidth = SurfaceLayout.sideTabZoneWidth(surfaceWidth: width, gap: state.gap)
        let revealing = state.hoveredSideTab != nil
        HStack(spacing: 0) {
            zone(.media, width: zoneWidth, tabWidth: tabWidth, revealing: revealing)
                .offset(x: (1 - progress) * 32)
            Spacer(minLength: 0)
            zone(.mirror, width: zoneWidth, tabWidth: tabWidth, revealing: revealing)
                .offset(x: -(1 - progress) * 32)
        }
        .padding(.horizontal, SurfaceLayout.sideTabsContentPadding)
        .opacity(progress)
    }

    private func zone(_ mode: SurfaceContentMode, width: CGFloat,
                      tabWidth: CGFloat, revealing: Bool) -> some View {
        Button {
            state.hoveredSideTab = mode
            selectSurfaceMode(mode, state: state)
        } label: {
            SlidingModeLabel(mode: mode, availableWidth: tabWidth, hovering: revealing)
                .frame(width: width, height: state.barHeight,
                       alignment: mode == .media ? .leading : .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(SharedModeZoneStyle())
        .accessibilityLabel(mode.rawValue)
        .accessibilityAddTraits(state.contentMode == mode ? .isSelected : [])
        .help(mode.rawValue)
    }
}

private struct SharedModeZoneStyle: ButtonStyle {
    @Environment(\.surfaceAppearance) private var appearance
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? appearance.pressOpacity(0.78, ink: appearance.headerRGB) : 1)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

private struct SlidingModeLabel: View {
    let mode: SurfaceContentMode
    let availableWidth: CGFloat
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceAppearance) private var appearance

    private var titleWidth: CGFloat { SurfaceLayout.sideTabLabelWidth(mode.rawValue) }
    private var canRevealTitle: Bool { availableWidth >= titleWidth }
    private var leading: Bool { mode == .media }

    var body: some View {
        HStack(spacing: 5) {
            if leading { symbol }
            if canRevealTitle {
                Text(mode.rawValue)
                    .font(Font(SurfaceLayout.menuBarFont))
                    .fixedSize()
                    .opacity(hovering ? 1 : 0)
            }
            if !leading { symbol }
        }
        .padding(.horizontal, 8)
        .frame(width: min(availableWidth, titleWidth), height: 24, alignment: leading ? .leading : .trailing)
        .frame(width: hovering && canRevealTitle ? titleWidth : min(28, availableWidth),
               height: 24, alignment: leading ? .leading : .trailing)
        .foregroundStyle(appearance.header)
        .surfaceInkLegibility()
        .clipped()
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.88), value: hovering)
    }

    private var symbol: some View {
        Image(systemName: mode.symbol).font(Font(SurfaceLayout.menuBarFont))
            .frame(width: SurfaceLayout.sideTabSymbolWidth)
    }
}

enum AmbientPlaybackState {
    case unavailable
    case audioActive
    case audioIdle
    case idle
    case playing
    case paused
}

struct AmbientMediaSnapshot {
    var state: AmbientPlaybackState
    var title: String
    var subtitle: String?
    var sourceName: String?
    var artwork: NSImage?
    var visualPalette: ArtworkPalette? = nil
    var sourceBundleIdentifier: String? = nil
    // A source-name fallback is not a real track title.
    var hasTrackMetadata = false
    var metadataIsRetained = false
    var canSkip = false
    var audioSourceBundleIdentifiers: [String] = []
    var trackIdentifier: String? = nil
    var isMusicSource = false
    var independentlyRead = false
    var independentReadAt: TimeInterval? = nil

    static let idle = AmbientMediaSnapshot(state: .idle, title: "Shh…",
                                           subtitle: "Ничего не играет",
                                           sourceName: nil, artwork: nil)
    static let unavailable = AmbientMediaSnapshot(state: .unavailable, title: "Музыка",
                                                  subtitle: "Не удалось получить текущий трек",
                                                  sourceName: nil, artwork: nil)
}

@MainActor protocol AmbientMediaAdapter: AnyObject {
    var onSnapshot: ((AmbientMediaSnapshot) -> Void)? { get set }
    var supportsTransport: Bool { get }
    func start()
    func stop()
    func togglePlayback()
    func skipForward()
    func skipBackward()
}

extension AmbientMediaAdapter {
    var supportsTransport: Bool { false }
}

struct MediaLaunchTarget: Identifiable {
    let name: String
    let bundleIdentifier: String
    let url: URL
    let icon: NSImage

    var id: String { bundleIdentifier }
}

@MainActor final class AmbientMediaController: ObservableObject {
    @Published private(set) var snapshot = AmbientMediaSnapshot.unavailable
    @Published private(set) var launchTargets: [MediaLaunchTarget] = []
    @Published private(set) var experimentalMediaEnabled = !UserDefaults.standard.bool(forKey: "disableExperimentalMedia")
    @Published private(set) var mediaDiagnostic: String?
    @Published private(set) var sourceOpenDiagnostic: String?
    @Published private(set) var musicPriorityEnabled = !UserDefaults.standard.bool(forKey: "disableMusicPriority")
    @Published private(set) var musicPriorityDiagnostic: String?
    let musicFavorites = MusicFavoritesController()
    private let audio = AudioActivityAdapter()
    private var media: SystemMediaAdapter?
    private var audioSnapshot = AmbientMediaSnapshot.unavailable
    private var mediaSnapshot = AmbientMediaSnapshot.unavailable
    private var selection = MediaSourceSelection()
    private var pendingSelectionRecheck: DispatchWorkItem?
    private let musicPlayers = MusicPlayerAdapter()
    private var musicSnapshots: [AmbientMediaSnapshot] = []

    init() {
        refreshLaunchTargets()
        audio.onSnapshot = { [weak self] value in
            self?.audioSnapshot = value
            self?.publish()
        }
        audio.start()
        musicPlayers.onSnapshots = { [weak self] values in
            self?.musicSnapshots = values
            self?.publish()
        }
        musicPlayers.onDiagnostic = { [weak self] message in self?.musicPriorityDiagnostic = message }
        if musicPriorityEnabled { musicPlayers.start() }
        if experimentalMediaEnabled { startMedia() }
    }

    var hasTransport: Bool {
        if snapshot.independentlyRead {
            return musicPriorityEnabled && musicSnapshots.contains {
                $0.sourceBundleIdentifier == snapshot.sourceBundleIdentifier
                    && $0.trackIdentifier == snapshot.trackIdentifier
                    && $0.state == snapshot.state
                    && ProcessInfo.processInfo.systemUptime - ($0.independentReadAt ?? 0) < MediaSourceSelection.independentFreshness
            }
        }
        return media?.supportsTransport == true
            && MediaSourceSelection.canControl(snapshot, current: mediaSnapshot)
    }

    func toggleMusicPriority() {
        musicPriorityEnabled.toggle()
        UserDefaults.standard.set(!musicPriorityEnabled, forKey: "disableMusicPriority")
        musicPriorityDiagnostic = nil
        if musicPriorityEnabled { musicPlayers.start() } else { musicPlayers.stop() }
        publish()
    }

    func requestMusicPermissions() { musicPlayers.requestPermissions() }

    var canOpenSource: Bool { snapshot.sourceBundleIdentifier != nil }

    var musicFavoriteTarget: MusicFavoriteTarget? {
        guard snapshot.sourceBundleIdentifier == "com.apple.Music",
              let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first
        else { return nil }
        return MusicFavoriteTarget(snapshot: snapshot, processID: process.processIdentifier)
    }

    func toggleExperimentalMedia() {
        experimentalMediaEnabled.toggle()
        UserDefaults.standard.set(!experimentalMediaEnabled, forKey: "disableExperimentalMedia")
        media?.stop()
        media = nil
        mediaSnapshot = .unavailable
        mediaDiagnostic = nil
        if experimentalMediaEnabled { startMedia() }
        publish()
    }

    private func startMedia() {
        let adapter = SystemMediaAdapter()
        adapter.onSnapshot = { [weak self] value in
            self?.mediaSnapshot = value
            self?.mediaDiagnostic = nil
            self?.publish()
        }
        adapter.onFailure = { [weak self] message in self?.mediaDiagnostic = message }
        media = adapter
        adapter.start()
    }

    private func publish() {
        pendingSelectionRecheck?.cancel()
        pendingSelectionRecheck = nil
        let now = ProcessInfo.processInfo.systemUptime
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        snapshot = selection.select(media: mediaSnapshot, audio: audioSnapshot,
            runningSources: running, now: now, independent: musicSnapshots)
        // The adapters deduplicate unchanged readings; expiry must also happen
        // when neither the helper nor the audio process list emits another update.
        if let deadline = selection.recheckDeadline {
            let task = DispatchWorkItem { [weak self] in self?.publish() }
            pendingSelectionRecheck = task
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, deadline - now), execute: task)
        }
    }

    func stop() {
        pendingSelectionRecheck?.cancel()
        pendingSelectionRecheck = nil
        media?.stop()
        musicPlayers.stop()
        audio.stop()
        musicFavorites.present(nil, active: false)
    }

    func togglePlayback() {
        guard hasTransport else { return }
        if snapshot.independentlyRead { musicPlayers.send(.toggle, target: snapshot) }
        else { media?.togglePlayback() }
    }
    func skipForward() {
        guard hasTransport && snapshot.canSkip else { return }
        if snapshot.independentlyRead { musicPlayers.send(.next, target: snapshot) }
        else { media?.skipForward() }
    }
    func skipBackward() {
        guard hasTransport && snapshot.canSkip else { return }
        if snapshot.independentlyRead { musicPlayers.send(.previous, target: snapshot) }
        else { media?.skipBackward() }
    }

    func launch(_ target: MediaLaunchTarget) {
        NSWorkspace.shared.open(target.url)
    }

    func openSource() {
        sourceOpenDiagnostic = nil
        guard let id = snapshot.sourceBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            sourceOpenDiagnostic = "Не удалось найти приложение-источник"
            return
        }
        // Open the owning app, never an inferred web URL or a different audio process.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: id)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            let message = "Не удалось открыть источник: \(error.localizedDescription)"
            Task { @MainActor in self?.sourceOpenDiagnostic = message }
        }
    }

    private func refreshLaunchTargets() {
        let candidates = [("Music", "com.apple.Music"),
                          ("Spotify", "com.spotify.client")]
        launchTargets = candidates.compactMap { name, bundleIdentifier in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return nil
            }
            return MediaLaunchTarget(name: name, bundleIdentifier: bundleIdentifier,
                                     url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
        }
    }
}

struct CollapsedMediaWing: View {
    @ObservedObject var controller: AmbientMediaController
    var wingWidth: CGFloat = SurfaceLayout.wingWidth
    @Environment(\.surfaceAppearance) private var appearance

    var body: some View {
        Group {
            if controller.snapshot.state != .idle,
               let artwork = controller.snapshot.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: SurfaceLayout.miniTileSize, height: SurfaceLayout.miniTileSize)
                    .clipShape(RoundedRectangle(cornerRadius: SurfaceLayout.miniTileCornerRadius,
                        style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(controller.snapshot.state == .idle ? appearance.secondary : appearance.primary)
                    .surfaceInkLegibility()
            }
        }
        .frame(width: SurfaceLayout.miniTileSize, height: SurfaceLayout.miniTileSize)
        .frame(width: wingWidth, height: 32)
        .accessibilityLabel(controller.snapshot.state == .unavailable
                            ? "Текущий трек недоступен"
                            : controller.snapshot.state == .idle
                            ? "Ничего не играет"
                            : controller.snapshot.state == .audioActive
                            ? "Активный аудиовыход: \(controller.snapshot.sourceName ?? "источник неизвестен")"
                            : controller.snapshot.state == .audioIdle
                            ? "Нет активных аудиопотоков"
                            : "Сейчас играет: \(controller.snapshot.title)")
    }
}

private struct ModeMelt: ViewModifier {
    let settled: Bool

    func body(content: Content) -> some View {
        content
            .opacity(settled ? 1 : 0)
            .scaleEffect(settled ? 1 : 0.985)
            .offset(y: settled ? 0 : 5)
            .blur(radius: settled ? 0 : 1.5)
    }
}

struct SurfaceContentView: View {
    @ObservedObject var state: SurfaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceAppearance) private var appearance
    @Namespace private var modeSelection

    private var modeAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.30, dampingFraction: 0.88)
    }

    private var modeTransition: AnyTransition {
        reduceMotion ? .opacity : .modifier(active: ModeMelt(settled: false),
                                            identity: ModeMelt(settled: true))
    }

    var body: some View {
        VStack(spacing: 12) {
            if !state.usesSideTabs {
                HStack(spacing: 6) {
                    modeButton(.media, symbol: "waveform")
                    modeButton(.mirror, symbol: "camera.fill")
                    Spacer()
                }
                .animation(modeAnimation, value: state.contentMode)
            }
            ZStack {
                switch state.contentMode {
                case .media:
                    AmbientMediaView(controller: state.ambientMedia, visual: state.audioVisual,
                        active: state.expanded)
                        .transition(modeTransition)
                case .mirror:
                    MirrorToolView(controller: state.mirror, active: state.expanded,
                        cornerRadius: state.mirrorCornerRadius)
                        .transition(modeTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(modeAnimation, value: state.contentMode)
        }
        .padding(state.contentPadding)
        .onChange(of: reduceMotion) { _, _ in state.updateVisualVisibility() }
    }

    private func modeButton(_ mode: SurfaceContentMode, symbol: String) -> some View {
        Button {
            selectSurfaceMode(mode, state: state)
        } label: {
            Label(mode.rawValue, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(appearance.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    if state.contentMode == mode {
                        Capsule().fill(LinearGradient(colors: [appearance.fill(0.22),
                                                               appearance.fill(0.12)],
                                                      startPoint: .top, endPoint: .bottom))
                            .matchedGeometryEffect(id: "selected-mode", in: modeSelection)
                    } else {
                        Capsule().fill(appearance.fill(0.06))
                    }
                }
        }
        .buttonStyle(SurfaceButtonStyle())
        .accessibilityAddTraits(state.contentMode == mode ? .isSelected : [])
    }
}

private struct AmbientMediaView: View {
    @ObservedObject var controller: AmbientMediaController
    @ObservedObject var visual: AudioVisualController
    let active: Bool
    @Environment(\.surfaceAppearance) private var appearance

    var body: some View {
        Group {
            if controller.snapshot.state == .idle || controller.snapshot.state == .audioIdle || controller.snapshot.state == .unavailable {
                HStack(spacing: 14) {
                    idleView.frame(maxWidth: .infinity)
                    if visual.enabled { AudioVisualStage(controller: visual, active: active) }
                }
            } else { nowPlayingView }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(spacing: 2) {
                MusicFavoriteDiagnostic(controller: controller.musicFavorites)
                if let message = controller.sourceOpenDiagnostic ?? (controller.mediaDiagnostic == nil
                    ? nil : "Данные плеера недоступны · можно перезапустить через меню") {
                    Text(message).font(.system(size: 9)).foregroundStyle(appearance.secondary).surfaceInkLegibility()
                }
            }
        }
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Text(controller.snapshot.title)
                .font(.system(size: 31, weight: .light, design: .rounded))
                .surfaceInkLegibility()
            Text(controller.snapshot.subtitle ?? "")
                .font(.system(size: 12))
                .foregroundStyle(appearance.secondary)
                .surfaceInkLegibility()
            if !controller.launchTargets.isEmpty {
                HStack(spacing: 8) {
                    ForEach(controller.launchTargets) { target in
                        Button { controller.launch(target) } label: {
                            HStack(spacing: 7) {
                                Image(nsImage: target.icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 18, height: 18)
                                Text("Открыть \(target.name)")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(appearance.fill(0.08), in: Capsule())
                        }
                        .buttonStyle(SurfaceButtonStyle())
                    }
                }
            }
        }
    }

    private var nowPlayingView: some View {
        HStack(spacing: 14) {
            sourceLink { artworkView }

            VStack(alignment: .leading, spacing: 8) {
                sourceLink { metadataView }
                if controller.canOpenSource {
                    HStack(spacing: 8) {
                        Group {
                            Button(action: controller.skipBackward) {
                                Image(systemName: "backward.fill").frame(width: 28, height: 28)
                            }
                                .disabled(!controller.snapshot.canSkip)
                                .help("Предыдущий трек")
                            Button(action: controller.togglePlayback) {
                                Image(systemName: controller.snapshot.state == .playing
                                      ? "pause.fill" : "play.fill")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(SurfaceButtonStyle(prominent: true))
                            Button(action: controller.skipForward) {
                                Image(systemName: "forward.fill").frame(width: 28, height: 28)
                            }
                                .disabled(!controller.snapshot.canSkip)
                                .help("Следующий трек")
                        }
                        .disabled(!controller.hasTransport)
                        if let target = controller.musicFavoriteTarget {
                            MusicFavoriteButton(controller: controller.musicFavorites,
                                target: target, active: active)
                        }
                    }
                    .buttonStyle(SurfaceButtonStyle())
                    .font(.system(size: 15))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if visual.enabled { AudioVisualStage(controller: visual, active: active, palette: controller.snapshot.visualPalette) }
        }
    }

    private var artworkView: some View {
        Group {
            if let artwork = controller.snapshot.artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(appearance.accent)
            }
        }
        .frame(width: SurfaceLayout.mediaTileSize, height: SurfaceLayout.mediaTileSize)
        .background(appearance.fill(0.07))
        .clipShape(RoundedRectangle(cornerRadius: SurfaceLayout.mediaTileCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SurfaceLayout.mediaTileCornerRadius, style: .continuous))
    }

    private var metadataView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source = controller.snapshot.sourceName {
                Text(source.uppercased()).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(appearance.secondary)
            }
            MarqueeText(text: controller.snapshot.title,
                font: .systemFont(ofSize: 16, weight: .medium), active: active)
            if let subtitle = controller.snapshot.subtitle {
                MarqueeText(text: subtitle, font: .systemFont(ofSize: 12), active: active)
                    .foregroundStyle(appearance.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .surfaceInkLegibility()
    }

    @ViewBuilder private func sourceLink<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if controller.canOpenSource {
            Button(action: controller.openSource, label: content)
                .buttonStyle(.plain)
                .help("Открыть \(controller.snapshot.sourceName ?? "источник")")
                .accessibilityLabel("Открыть \(controller.snapshot.sourceName ?? "источник"): \(controller.snapshot.title)\(controller.snapshot.subtitle.map { ", " + $0 } ?? "")")
                .accessibilityHint(controller.snapshot.metadataIsRetained
                    ? "Последние данные плеера; текущий системный источник меняется" : "")
        } else { content() }
    }
}

struct SurfaceButtonStyle: ButtonStyle {
    var prominent = false
    var hoverHighlight = true
    func makeBody(configuration: Configuration) -> some View {
        SurfaceButtonBody(configuration: configuration, prominent: prominent,
                          hoverHighlight: hoverHighlight)
    }
}

private struct SurfaceButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let hoverHighlight: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.surfaceAppearance) private var appearance
    @State private var hovering = false

    private var fillOpacity: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.16 }
        if hovering && hoverHighlight { return 0.10 }
        return prominent ? 0.06 : 0
    }

    private var scale: CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        if configuration.isPressed { return 0.96 }
        return hovering ? 1.02 : 1
    }

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? appearance.primary : appearance.muted)
            .surfaceInkLegibility()
            .contentShape(Rectangle())
            .background(appearance.fill(Float(fillOpacity)), in: Capsule())
            .scaleEffect(scale)
            .opacity(isEnabled && configuration.isPressed
                ? appearance.pressOpacity(0.86, on: appearance.fillRGB(Float(fillOpacity))) : 1)
            .animation(reduceMotion ? nil : configuration.isPressed
                ? .easeOut(duration: 0.07) : .spring(response: 0.22, dampingFraction: 0.8),
                value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
