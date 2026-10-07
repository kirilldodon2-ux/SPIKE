import AppKit
import SwiftUI

enum SurfaceMaterial: String, Sendable {
    case solid, glass
}

/// AppKit resolves dynamic colours on main; rendering receives only value types.
struct SurfaceSystemColors: Equatable, Sendable {
    let background: SIMD3<Float>
    let primary: SIMD3<Float>
    let secondary: SIMD3<Float>
    let muted: SIMD3<Float>
    let accent: SIMD3<Float>

    @MainActor static func resolve(for appearance: NSAppearance) -> SurfaceSystemColors? {
        var result: SurfaceSystemColors?
        appearance.performAsCurrentDrawingAppearance {
            func rgba(_ color: NSColor) -> SIMD4<Float>? {
                guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
                let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
                guard values.allSatisfy(\.isFinite) else { return nil }
                let v = values.map { Float(min(1, max(0, $0))) }
                return SIMD4(v[0], v[1], v[2], v[3])
            }
            guard let window = rgba(.windowBackgroundColor), let label = rgba(.labelColor),
                  let secondary = rgba(.secondaryLabelColor), let muted = rgba(.tertiaryLabelColor),
                  let accent = rgba(.controlAccentColor) else { return }
            let background = SIMD3(window.x, window.y, window.z)
            func overWindow(_ color: SIMD4<Float>) -> SIMD3<Float> {
                SurfaceAppearance.mix(background, SIMD3(color.x, color.y, color.z), color.w)
            }
            result = SurfaceSystemColors(background: background, primary: overWindow(label),
                secondary: overWindow(secondary), muted: overWindow(muted), accent: overWindow(accent))
        }
        return result
    }
}

/// Saved colour settings and an independent material; media keep their opacity.
struct SurfaceAppearance: Equatable, Sendable {
    let backgroundRGB: SIMD3<Float>
    var isTransparent = false
    var isRainbow = false
    var opacity: Double = 0.35
    var material: SurfaceMaterial = .solid
    var usesSystemColors = false
    // Resolved only on the view's copy. Saved RGB/Rainbow are never replaced.
    private var systemColors: SurfaceSystemColors?
    static let black = SurfaceAppearance(backgroundRGB: .zero)
    private static let defaultsKey = "surface.background.sRGB"
    private static let transparencyKey = "surface.background.transparent"
    private static let opacityKey = "surface.background.opacity"
    private static let rainbowKey = "surface.background.rainbow"
    private static let materialKey = "surface.material"
    private static let systemColorsKey = "surface.colors.system"

    // Bright stops keep one dark foreground readable across the whole gradient.
    static let rainbowRGB: [SIMD3<Float>] = [
        SIMD3(1, 0.42, 0.54), SIMD3(1, 0.67, 0.35), SIMD3(0.98, 0.88, 0.40),
        SIMD3(0.42, 0.84, 0.58), SIMD3(0.34, 0.76, 0.96), SIMD3(0.68, 0.54, 0.98),
        SIMD3(0.96, 0.47, 0.80)
    ]
    private static let rainbowReference: SIMD3<Float> = rainbowSamples.min {
        ArtworkPalette.luminance($0) < ArtworkPalette.luminance($1)
    }!
    private static var rainbowSamples: [SIMD3<Float>] {
        (0..<(rainbowRGB.count - 1)).flatMap { index in
            (0...100).map { mix(rainbowRGB[index], rainbowRGB[index + 1], Float($0) / 100) }
        }
    }
    var isGlass: Bool { material == .glass }
    var hasSystemPalette: Bool { systemColors != nil }
    private var rendersRainbow: Bool { isRainbow && !hasSystemPalette }
    var contrastRGB: SIMD3<Float> {
        systemColors?.background ?? (rendersRainbow && !isGlass ? Self.rainbowReference : backgroundRGB)
    }
    var needsClearCanvas: Bool { isGlass || isTransparent || rendersRainbow }

    var usesLightInk: Bool {
        Self.contrast(SIMD3(repeating: 1), contrastRGB) >= Self.contrast(.zero, contrastRGB)
    }
    var inkRGB: SIMD3<Float> { systemColors?.primary ?? (usesLightInk ? SIMD3(repeating: 1) : .zero) }
    var secondaryRGB: SIMD3<Float> { systemColors?.secondary ?? readable(Self.mix(contrastRGB, inkRGB, 0.60)) }
    var mutedRGB: SIMD3<Float> { systemColors?.muted ?? readable(Self.mix(contrastRGB, inkRGB, 0.35), minimum: 3) }
    var headerRGB: SIMD3<Float> { systemColors?.primary ?? readable(Self.mix(contrastRGB, inkRGB, 0.90)) }
    var surface: Color { Self.color(contrastRGB).opacity(isTransparent ? opacity : 1) }
    @ViewBuilder var background: some View {
        if rendersRainbow {
            RainbowSurfaceBackground(colors: Self.rainbowRGB.map(Self.color))
                .opacity(isTransparent ? opacity : 1)
        } else { surface }
    }
    var primary: Color { isGlass ? .primary : Self.color(inkRGB) }
    var secondary: Color { isGlass ? .secondary : Self.color(secondaryRGB) }
    var muted: Color { isGlass ? .secondary.opacity(0.7) : Self.color(mutedRGB) }
    var header: Color { isGlass ? .primary.opacity(0.9) : Self.color(headerRGB) }
    var accent: Color { isGlass ? .accentColor : Self.color(systemColors?.accent ?? readable(SIMD3(0, 0.82, 0.9))) }
    var recording: Color { isGlass ? .red : Self.color(readable(SIMD3(1, 0.23, 0.19))) }
    var oppositeInk: Color { usesLightInk ? .black : .white }
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(backgroundRGB.x), green: CGFloat(backgroundRGB.y),
                blue: CGFloat(backgroundRGB.z), alpha: isTransparent ? opacity : 1)
    }

    /// Limit state fills near middle grey so even pressed controls keep legible ink.
    func fillRGB(_ amount: Float) -> SIMD3<Float> {
        let backgroundRGB = contrastRGB
        let secondary = secondaryRGB
        let requested = Self.mix(backgroundRGB, inkRGB, amount)
        guard Self.contrast(secondary, requested) < 4.5 else { return requested }
        var low: Float = 0, high = amount
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if Self.contrast(secondary, Self.mix(backgroundRGB, inkRGB, mid)) >= 4.5 { low = mid }
            else { high = mid }
        }
        return Self.mix(backgroundRGB, inkRGB, low)
    }
    func fill(_ amount: Float) -> Color {
        if isGlass || hasSystemPalette { return primary.opacity(Double(amount)) }
        let rgb = fillRGB(amount)
        guard needsClearCanvas else { return Self.color(rgb) }
        return primary.opacity(Double(fillAlpha(amount)))
    }
    private func fillAlpha(_ amount: Float) -> Float {
        // An opaque fill would cover the gradient or leave tiles on a clear surface.
        let rgb = fillRGB(amount)
        let delta = inkRGB - contrastRGB
        let index = (0..<3).max { abs(delta[$0]) < abs(delta[$1]) }!
        let fraction = (rgb[index] - contrastRGB[index]) / delta[index]
        return max(0, min(1, fraction))
    }

    func opaqueFallback(_ required: Bool, glassAvailable: Bool = true) -> SurfaceAppearance {
        var value = self
        if required { value.isTransparent = false }
        if required || !glassAvailable { value.material = .solid }
        return value
    }

    func resolvingSystemColors(_ colors: SurfaceSystemColors?) -> SurfaceAppearance {
        var value = self
        value.systemColors = usesSystemColors ? colors : nil
        return value
    }

    func resettingColor() -> SurfaceAppearance {
        var value = Self.black
        value.material = material
        return value
    }

    func pressOpacity(_ requested: Double, on background: SIMD3<Float>? = nil,
                      ink: SIMD3<Float>? = nil) -> Double {
        if isGlass { return requested }
        let background = background ?? contrastRGB, ink = ink ?? inkRGB
        var low = Float(requested), high: Float = 1
        if Self.contrast(Self.mix(background, ink, low), background) >= 4.5 { return requested }
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if Self.contrast(Self.mix(background, ink, mid), background) >= 4.5 { high = mid }
            else { low = mid }
        }
        return Double(high)
    }

    private func readable(_ candidate: SIMD3<Float>, minimum: Float = 4.5) -> SIMD3<Float> {
        let backgroundRGB = contrastRGB
        if Self.contrast(candidate, backgroundRGB) >= minimum { return candidate }
        var low: Float = 0, high: Float = 1
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if Self.contrast(Self.mix(candidate, inkRGB, mid), backgroundRGB) >= minimum { high = mid }
            else { low = mid }
        }
        return Self.mix(candidate, inkRGB, high)
    }

    static func contrast(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let first = ArtworkPalette.luminance(a), second = ArtworkPalette.luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
    static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        a + (b - a) * amount
    }
    private static func color(_ rgb: SIMD3<Float>) -> Color {
        Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z), opacity: 1)
    }

    @MainActor init?(color: NSColor, preserving previous: SurfaceAppearance) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init)
        guard components.allSatisfy(\.isFinite) else { return nil }
        self.init(components: components.map { min(1, max(0, $0)) })
        material = previous.material
        isTransparent = previous.isTransparent
        // Opacity changes keep Rainbow; choosing a different RGB returns to flat colour.
        isRainbow = previous.isRainbow && (0..<3).allSatisfy {
            abs(backgroundRGB[$0] - previous.backgroundRGB[$0]) < 0.00001
        }
        opacity = isTransparent ? min(1, max(0, Double(rgb.alphaComponent))) : previous.opacity
    }
    init(backgroundRGB: SIMD3<Float>, isTransparent: Bool = false, opacity: Double = 0.35,
         isRainbow: Bool = false) {
        self.backgroundRGB = backgroundRGB
        self.isTransparent = isTransparent
        self.opacity = opacity
        self.isRainbow = isRainbow
    }
    private init?(components: [Double]) {
        guard components.count == 3, components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        backgroundRGB = SIMD3(Float(components[0]), Float(components[1]), Float(components[2]))
    }
    static func load(from defaults: UserDefaults = .standard) -> SurfaceAppearance {
        var appearance = SurfaceAppearance.black
        if let values = defaults.array(forKey: defaultsKey) as? [Double],
           let decoded = SurfaceAppearance(components: values) {
            appearance = decoded
        }
        if let raw = defaults.string(forKey: materialKey), let material = SurfaceMaterial(rawValue: raw) {
            appearance.material = material
        }
        appearance.isTransparent = defaults.bool(forKey: transparencyKey)
        appearance.isRainbow = defaults.bool(forKey: rainbowKey)
        appearance.usesSystemColors = defaults.bool(forKey: systemColorsKey)
        if let value = defaults.object(forKey: opacityKey) as? Double, value.isFinite, (0...1).contains(value) {
            appearance.opacity = value
        }
        return appearance
    }
    func save(to defaults: UserDefaults = .standard) {
        if usesSystemColors { defaults.set(true, forKey: Self.systemColorsKey) }
        else { defaults.removeObject(forKey: Self.systemColorsKey) }
        if material == .solid { defaults.removeObject(forKey: Self.materialKey) }
        else { defaults.set(material.rawValue, forKey: Self.materialKey) }
        if backgroundRGB == .zero { defaults.removeObject(forKey: Self.defaultsKey) }
        else { defaults.set([Double(backgroundRGB.x), Double(backgroundRGB.y), Double(backgroundRGB.z)],
                            forKey: Self.defaultsKey) }
        if isTransparent { defaults.set(true, forKey: Self.transparencyKey) }
        else { defaults.removeObject(forKey: Self.transparencyKey) }
        if isRainbow { defaults.set(true, forKey: Self.rainbowKey) }
        else { defaults.removeObject(forKey: Self.rainbowKey) }
        if opacity != 0.35 { defaults.set(opacity, forKey: Self.opacityKey) }
        else { defaults.removeObject(forKey: Self.opacityKey) }
    }

    @MainActor static func check() {
        // Include the white/black crossover and saturated colours, not just extremes.
        for r in 0...10 { for g in 0...10 { for b in 0...10 {
            let appearance = SurfaceAppearance(backgroundRGB: SIMD3(Float(r), Float(g), Float(b)) / 10)
            for ink in [appearance.inkRGB, appearance.secondaryRGB, appearance.headerRGB] {
                precondition(contrast(ink, appearance.backgroundRGB) >= 4.499)
            }
            precondition(contrast(appearance.mutedRGB, appearance.backgroundRGB) >= 2.999)
            for amount: Float in [0.06, 0.10, 0.16, 0.22] {
                precondition(contrast(appearance.inkRGB, appearance.fillRGB(amount)) >= 4.499)
                precondition(contrast(appearance.secondaryRGB, appearance.fillRGB(amount)) >= 4.499)
            }
        } } }
        let suite = "local.one.appearance-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = SurfaceAppearance(backgroundRGB: SIMD3(0.23, 0.55, 0.8))
        selected.save(to: defaults)
        precondition(load(from: defaults) == selected)
        var system = selected
        system.usesSystemColors = true
        system.isRainbow = true
        system.save(to: defaults)
        precondition(load(from: defaults) == system,
            "System colour choice must survive reload without replacing the manual palette")
        let light = SurfaceSystemColors.resolve(for: NSAppearance(named: .aqua)!)!
        let dark = SurfaceSystemColors.resolve(for: NSAppearance(named: .darkAqua)!)!
        precondition(ArtworkPalette.luminance(light.background) > ArtworkPalette.luminance(dark.background))
        for colors in [light, dark] {
            let resolved = system.resolvingSystemColors(colors)
            precondition(resolved.backgroundRGB == selected.backgroundRGB && resolved.isRainbow)
            precondition(resolved.contrastRGB == colors.background && resolved.inkRGB == colors.primary)
            precondition(resolved.secondaryRGB == colors.secondary && resolved.mutedRGB == colors.muted)
            precondition(Self.contrast(resolved.inkRGB, resolved.contrastRGB) >= 4.5)
            precondition(!resolved.needsClearCanvas, "Saved Rainbow must not cover the system palette")
            resolved.save(to: defaults)
            precondition(load(from: defaults) == system, "Resolved colours must not leak into preferences")
            var returned = system
            returned.usesSystemColors = false
            precondition(returned.resolvingSystemColors(colors).contrastRGB == Self.rainbowReference)
            precondition(!returned.resolvingSystemColors(colors).hasSystemPalette)
            precondition(resolved.opaqueFallback(true).usesSystemColors)
            precondition(!resolved.resettingColor().usesSystemColors)
        }
        precondition(!system.resolvingSystemColors(nil).hasSystemPalette)
        selected.save(to: defaults)
        var glass = selected
        glass.material = .glass
        glass.save(to: defaults)
        precondition(load(from: defaults) == glass, "Glass selection must survive reload without losing RGB")
        precondition(glass.needsClearCanvas, "Glass must not be covered by an opaque Metal stage")
        precondition(SurfaceAppearance(color: .white, preserving: glass)?.material == .glass)
        precondition(glass.resettingColor().material == .glass)
        precondition(glass.resettingColor().backgroundRGB == .zero)
        glass.isTransparent = true
        glass.isRainbow = true
        glass.opacity = 0.72
        glass.save(to: defaults)
        let fallback = glass.opaqueFallback(true)
        precondition(fallback.material == .solid && !fallback.isTransparent && fallback.isRainbow)
        precondition(load(from: defaults) == glass, "Accessibility fallback must not overwrite preferences")
        precondition(glass.opaqueFallback(false, glassAvailable: false).material == .solid)
        precondition(glass.opaqueFallback(false).material == .glass)
        var returned = glass
        returned.material = .solid
        precondition(returned.backgroundRGB == selected.backgroundRGB && returned.isRainbow
                     && returned.isTransparent && returned.opacity == 0.72)
        defaults.set([Double.nan, 0, 0], forKey: defaultsKey)
        precondition(load(from: defaults).material == .glass, "Invalid RGB must not reset material")
        defaults.set("unknown", forKey: materialKey)
        precondition(load(from: defaults).material == .solid)
        var clear = SurfaceAppearance(backgroundRGB: .zero, isTransparent: true, opacity: 0)
        clear.save(to: defaults)
        precondition(load(from: defaults) == clear)
        clear.opacity = 0.72
        clear.save(to: defaults)
        precondition(load(from: defaults) == clear)
        precondition(!clear.opaqueFallback(true).isTransparent && clear.isTransparent)
        var rainbow = SurfaceAppearance(backgroundRGB: selected.backgroundRGB, isTransparent: true,
                                        opacity: 0.72, isRainbow: true)
        rainbow.save(to: defaults)
        precondition(load(from: defaults) == rainbow)
        precondition(rainbow.needsClearCanvas && !rainbow.usesLightInk)
        let changedAlpha = NSColor(srgbRed: CGFloat(rainbow.backgroundRGB.x),
            green: CGFloat(rainbow.backgroundRGB.y), blue: CGFloat(rainbow.backgroundRGB.z), alpha: 0.2)
        precondition(SurfaceAppearance(color: changedAlpha, preserving: rainbow)?.isRainbow == true)
        precondition(SurfaceAppearance(color: .white, preserving: rainbow)?.isRainbow == false)
        for background in rainbowSamples {
            for ink in [rainbow.inkRGB, rainbow.secondaryRGB, rainbow.headerRGB] {
                precondition(contrast(ink, background) >= 4.499)
            }
            precondition(contrast(rainbow.mutedRGB, background) >= 2.999)
            for amount: Float in [0.06, 0.10, 0.16, 0.22] {
                // Rainbow state fills are dark translucent overlays, not flat tiles.
                let fill = mix(background, rainbow.inkRGB, rainbow.fillAlpha(amount))
                precondition(contrast(rainbow.inkRGB, fill) >= 4.499)
                precondition(contrast(rainbow.secondaryRGB, fill) >= 4.499)
            }
        }
        rainbow.isRainbow = false
        precondition(rainbow.backgroundRGB == selected.backgroundRGB)
        defaults.set(Double.nan, forKey: opacityKey)
        precondition(load(from: defaults).opacity == 0.35)
        black.save(to: defaults)
        precondition(load(from: defaults) == .black)
        for invalid: [Double] in [[1], [1, 2, 3], [-1, 0, 0], [.nan, 0, 0]] {
            defaults.set(invalid, forKey: defaultsKey)
            precondition(load(from: defaults) == .black)
        }
        print("Appearance checks passed: 1,331 solid backgrounds + 606 rainbow samples, readable fills, persistence/reset/fallback, picker transitions and independent Glass preference")
        print("System colours passed: AppKit light/dark palette, label contrast, saved source/manual/Rainbow, fallback/reset and resolved-copy persistence isolation")
    }
}

/// Its timeline only redraws the decorative background, never publishes app state.
private struct RainbowSurfaceBackground: View {
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 2 * .pi / 18
                    let drift = 0.18 * sin(phase)
                    let tilt = 0.15 * cos(phase)
                    LinearGradient(colors: colors,
                        startPoint: UnitPoint(x: drift - 0.10, y: 0.5 - tilt),
                        endPoint: UnitPoint(x: 1.10 + drift, y: 0.5 + tilt))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SurfaceAppearanceKey: EnvironmentKey {
    static let defaultValue = SurfaceAppearance.black
}
extension EnvironmentValues {
    var surfaceAppearance: SurfaceAppearance {
        get { self[SurfaceAppearanceKey.self] }
        set { self[SurfaceAppearanceKey.self] = newValue }
    }
}

/// A small opposite-colour halo helps foreground over unblurred desktop content.
/// It is not a measurement of the windows behind SPIKE.
private struct SurfaceInkLegibility: ViewModifier {
    @Environment(\.surfaceAppearance) private var appearance
    func body(content: Content) -> some View {
        let needsHalo = appearance.isTransparent && !appearance.isGlass
        content.shadow(color: needsHalo ? appearance.oppositeInk.opacity(0.8) : .clear,
                       radius: needsHalo ? 0.8 : 0)
    }
}
extension View {
    func surfaceInkLegibility() -> some View { modifier(SurfaceInkLegibility()) }
}
