import AppKit
import SwiftUI

enum IdentityEffect: String, CaseIterable {
    case pulse, orbit, breathe, vhs

    var title: String {
        switch self {
        case .pulse: "Pulse"
        case .orbit: "Orbit"
        case .breathe: "Breathe"
        case .vhs: "VHS"
        }
    }

    var symbol: String {
        switch self {
        case .pulse: "waveform.path"
        case .orbit: "arrow.triangle.2.circlepath"
        case .breathe: "wind"
        case .vhs: "tv"
        }
    }

    var detail: String {
        switch self {
        case .pulse: "Мягкий пульс и переливающийся свет."
        case .orbit: "Медленное вращение с цветным послесвечением."
        case .breathe: "Спокойное дыхание через прозрачность."
        case .vhs: "Короткие зелёные и розовые VHS-помехи."
        }
    }
}

/// The same bounded image and effect are used in the wing and the settings preview.
/// These are decorative effects, independent of playback or activity status.
struct IdentityEffectImage: View {
    @ObservedObject var identity: IdentityController
    var edge: CGFloat = 24
    var active = true
    var cornerRadius: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceAppearance) private var appearance

    private static let logo: NSImage? = {
        let url = Bundle.main.url(forResource: "do", withExtension: "png")
            ?? Bundle.module.url(forResource: "do", withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30,
            paused: !active || reduceMotion || (identity.effectStrength == 0 && identity.asset?.isAnimated != true))) { context in
            let elapsed = max(0, context.date.timeIntervalSince(identity.effectStarted))
            let strength = reduceMotion ? 0 : identity.effectStrength
            let wave = (1 - cos(elapsed * 2 * .pi / 2.8)) / 2
            let color = Color(hue: elapsed.truncatingRemainder(dividingBy: 14) / 14,
                              saturation: 0.65, brightness: 1)
            // Brief bursts; no full-image flash, and no random work on the main thread.
            let tick = Int(elapsed * 12)
            let burst = tick % 31 < 4 ? strength : 0
            let jitter = sin(Double(tick) * 17.3) * edge / 24

            ZStack {
                if identity.effect == .vhs && burst > 0 {
                    ghost(.green, at: context.date)
                        .offset(x: edge / 24 * 2.4 * burst, y: jitter * burst)
                        .opacity(0.65 * burst)
                    ghost(.pink, at: context.date)
                        .offset(x: -edge / 24 * 2.4 * burst)
                        .opacity(0.7 * burst)
                }
                symbol(at: context.date)
                    .scaleEffect(identity.effect == .pulse ? 1 + 0.14 * strength * wave
                                 : identity.effect == .orbit && strength > 0 ? 0.92 : 1)
                    .rotationEffect(.degrees(identity.effect == .orbit && strength > 0
                        ? elapsed.truncatingRemainder(dividingBy: 20 - 13 * strength) * 360 / (20 - 13 * strength) : 0))
                    .opacity(identity.effect == .breathe ? 1 - 0.68 * strength * wave : 1)
                    .offset(x: identity.effect == .vhs ? jitter * burst * 0.6 : 0)
                    .shadow(color: color.opacity((identity.effect == .pulse ? wave : identity.effect == .orbit ? 0.65 : 0) * strength * 0.6),
                            radius: edge / 24 * 3 * strength)
                if identity.effect == .vhs && burst > 0 {
                    symbol(at: context.date)
                        .offset(x: jitter * 2.2 * burst)
                        .mask(Rectangle().frame(height: edge * 0.16)
                            .offset(y: sin(Double(tick) * 5.7) * edge * 0.3))
                        .opacity(0.8 * burst)
                }
            }
            .frame(width: edge, height: edge)
        }
        .frame(width: edge, height: edge)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func symbol(at date: Date) -> some View {
        if let asset = identity.asset {
            let index = asset.frameIndex(elapsed: date.timeIntervalSince(identity.animationStarted),
                                         reduceMotion: reduceMotion)
            Image(asset.frames[index], scale: 1, label: Text(""))
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: edge, height: edge)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? edge * 5 / 24,
                    style: .continuous))
        } else if let logo = Self.logo {
            Image(nsImage: logo).renderingMode(.original)
                .resizable().interpolation(.high).antialiased(true).scaledToFit()
                .frame(width: edge * 21 / 24, height: edge)
        } else {
            Text("SPIKE").font(.system(size: edge * 0.4, weight: .semibold)).foregroundStyle(appearance.accent)
        }
    }

    private func ghost(_ color: Color, at date: Date) -> some View {
        symbol(at: date).overlay(color).mask(symbol(at: date))
    }
}

struct IdentityAnchorView: View {
    @ObservedObject var identity: IdentityController
    var wingWidth: CGFloat = SurfaceLayout.wingWidth

    var body: some View {
        IdentityEffectImage(identity: identity, edge: SurfaceLayout.miniTileSize,
            cornerRadius: SurfaceLayout.miniTileCornerRadius)
            .frame(width: wingWidth, height: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("SPIKE — открыть или свернуть; правый клик — меню")
    }
}

struct IdentitySettingsView: View {
    @ObservedObject var identity: IdentityController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let colors: [Color] = [.mint, .cyan, .purple, .pink]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Свой знак").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("PNG · JPEG · GIF").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.black)
                IdentityEffectImage(identity: identity, edge: 72, active: identity.previewVisible)
            }
            .frame(height: 124)
            .accessibilityLabel("Предпросмотр картинки: \(identity.effect.title)")

            HStack(spacing: 6) {
                ForEach(IdentityEffect.allCases, id: \.self) { effect in
                    Button { identity.selectEffect(effect) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: effect.symbol).font(.system(size: 20, weight: .medium))
                                .foregroundStyle(identity.effect == effect
                                    ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.white.opacity(0.7)))
                            Text(effect.title).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).frame(height: 60)
                        .background(identity.effect == effect ? Color.mint.opacity(0.12) : Color.white.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(effect.title)
                    .accessibilityAddTraits(identity.effect == effect ? [.isSelected] : [])
                }
            }
            Text(identity.effect.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                HStack {
                    Text("Сила эффекта").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int((identity.effectStrength * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { identity.effectStrength }, set: { identity.setEffectStrength($0) }), in: 0...1)
                    .tint(.mint).accessibilityLabel("Сила эффекта картинки")
            }
            HStack {
                Button("Сменить картинку…") { identity.chooseImage() }
                Spacer()
                Button("Вернуть логотип") { identity.restoreLogo() }
            }
            .controlSize(.small).disabled(identity.isLoading)
            Text(reduceMotion ? "Reduce Motion: картинка и эффекты остаются статичными." : "0% — исходная картинка. GIF продолжает свою анимацию.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 400, height: 430, alignment: .top)
        .foregroundStyle(.white)
        .background(Color(red: 0.075, green: 0.075, blue: 0.085))
        .environment(\.colorScheme, .dark)
    }
}
