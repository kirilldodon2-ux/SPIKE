import AppKit
import SwiftUI

enum DeepSettingsPage: String, CaseIterable {
    case appearance = "Внешний вид", identity = "Картинка", visual = "Визуал"
}

/// UI commands stay in AppKit; values continue to belong to the existing controllers.
struct DeepSettingsActions {
    var close: () -> Void = {}
    var chooseColor: () -> Void = {}
    var toggleGlass: () -> Void = {}
    var toggleTransparency: () -> Void = {}
    var toggleRainbow: () -> Void = {}
    var toggleSystemColors: () -> Void = {}
    var resetColor: () -> Void = {}
    var changeOpacity: (Double) -> Void = { _ in }
    var additional: () -> Void = {}
}

struct DeepSettingsView: View {
    @ObservedObject var state: SurfaceState
    @Environment(\.surfaceAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(appearance.primary.opacity(0.10)).frame(height: 1)
                .accessibilityHidden(true)
            DeepSegments(title: "Страница настроек", selection: $state.settingsPage,
                options: DeepSettingsPage.allCases.map { ($0, $0.rawValue) }, height: 26)
                .padding(.top, 10)
                .padding(.bottom, 16)
            ScrollView {
                Group {
                    switch state.settingsPage {
                    case .appearance: DeepAppearanceSettings(state: state)
                    case .identity: DeepIdentitySettings(identity: state.identity)
                    case .visual: DeepVisualSettings(controller: state.audioVisual,
                        showsMedia: state.contentMode == .media)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            HStack {
                Button(action: state.settingsActions.additional) {
                    HStack(spacing: 10) {
                        Text("Дополнительно…")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    }
                    .padding(.trailing, 8).frame(height: 28)
                }
                .buttonStyle(DeepControlStyle())
                .accessibilityLabel("Дополнительно…")
                Spacer()
                Button(action: state.settingsActions.close) {
                    Text("Готово").padding(.horizontal, 16).frame(minWidth: 70, minHeight: 28)
                }
                    .buttonStyle(DeepControlStyle(filled: true, radius: 14))
            }
            .frame(height: 28).padding(.top, 16)
        }
        .font(.system(size: SurfaceLayout.menuBarFont.pointSize))
        .controlSize(.small)
        .tint(appearance.hasSystemPalette ? appearance.accent : appearance.primary.opacity(0.65))
        .padding(.horizontal, SurfaceLayout.sideTabsContentPadding)
        .padding(.bottom, 14)
        .surfaceInkLegibility()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Настройки SPIKE")
    }
}

private struct DeepAppearanceSettings: View {
    @ObservedObject var state: SurfaceState
    @Environment(\.surfaceAppearance) private var appearance

    private var hexColor: String {
        let rgb = state.appearance.usesSystemColors ? appearance.contrastRGB : state.appearance.backgroundRGB
        return String(format: "#%02X%02X%02X", Int((rgb.x * 255).rounded()),
                      Int((rgb.y * 255).rounded()), Int((rgb.z * 255).rounded()))
    }
    private var color: Color {
        let rgb = state.appearance.usesSystemColors ? appearance.contrastRGB : state.appearance.backgroundRGB
        return Color(.sRGB, red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    var body: some View {
        DeepColumns {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Материал")
                    DeepSegments(title: "Материал", selection: Binding(get: { state.appearance.material }, set: { value in
                        guard value != .glass || SurfaceMaterialView.glassAvailable else { return }
                        if value != state.appearance.material { state.settingsActions.toggleGlass() }
                    }), options: [(.solid, "Обычный"), (.glass, "Liquid Glass")],
                        disabled: SurfaceMaterialView.glassAvailable ? [] : [.glass])
                }
                Toggle("Прозрачный фон", isOn: Binding(get: { state.appearance.isTransparent }, set: { value in
                    if value != state.appearance.isTransparent { state.settingsActions.toggleTransparency() }
                }))
                .toggleStyle(DeepSwitchStyle()).disabled(appearance.isGlass)
                if state.appearance.isTransparent && !appearance.isGlass {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Плотность фона").foregroundStyle(appearance.secondary)
                            Spacer()
                            Text("\(Int((state.appearance.opacity * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(appearance.secondary)
                        }
                        Slider(value: Binding(get: { state.appearance.opacity }, set: { value in
                            state.settingsActions.changeOpacity(value)
                        }), in: 0...1).accessibilityLabel("Плотность фона")
                    }
                }
                if state.appearance.isGlass && !appearance.isGlass {
                    Text("Сейчас обычный фон: настройки доступности или версия macOS.")
                        .font(.system(size: 11)).foregroundStyle(appearance.secondary)
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Цвет SPIKE")
                    HStack(spacing: 8) {
                        Button(action: state.settingsActions.chooseColor) {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 7).fill(color)
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(appearance.primary.opacity(0.20)))
                                    .frame(width: 26, height: 26)
                                Text(state.appearance.usesSystemColors ? "macOS" : hexColor)
                                    .monospaced().foregroundStyle(appearance.secondary)
                            }
                            .frame(height: 28).padding(.horizontal, 2)
                        }
                        .buttonStyle(DeepControlStyle())
                        .disabled(appearance.isGlass || state.appearance.usesSystemColors)
                        .accessibilityLabel("Цвет SPIKE: \(hexColor)")
                        Spacer(minLength: 0)
                        DeepResetButton(title: "Вернуть чёрный цвет", action: state.settingsActions.resetColor)
                            .disabled(state.appearance == state.appearance.resettingColor())
                    }
                }
                HStack(spacing: 8) {
                    Button(action: state.settingsActions.toggleSystemColors) {
                        Text("Системные").frame(maxWidth: .infinity).frame(height: 28)
                    }
                    .buttonStyle(DeepControlStyle(selected: state.appearance.usesSystemColors, filled: true))
                    .accessibilityLabel("Использовать системные цвета")
                    .accessibilityAddTraits(state.appearance.usesSystemColors ? .isSelected : [])
                    .help("Цвета macOS: повторное нажатие возвращает ручную палитру.")
                    Button(action: state.settingsActions.toggleRainbow) {
                        Text("Rainbow").frame(maxWidth: .infinity).frame(height: 28)
                    }
                    .buttonStyle(DeepControlStyle(selected: state.appearance.isRainbow
                        && !state.appearance.usesSystemColors, filled: true))
                    .accessibilityAddTraits(state.appearance.isRainbow
                        && !state.appearance.usesSystemColors ? .isSelected : [])
                }
                .disabled(appearance.isGlass)
                if state.appearance.usesSystemColors && !appearance.hasSystemPalette {
                    Text("Системная палитра пока недоступна.")
                        .font(.system(size: 11)).foregroundStyle(appearance.secondary)
                }
                if appearance.isGlass {
                    Text("Цвет и прозрачность сохраняются для обычного фона.")
                        .font(.system(size: 11)).foregroundStyle(appearance.secondary)
                }
            }
        }
    }
}

private struct DeepIdentitySettings: View {
    @ObservedObject var identity: IdentityController
    @Environment(\.surfaceAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DeepColumns {
            VStack(alignment: .leading, spacing: 7) {
                Text("Личная картинка")
                HStack(spacing: 8) {
                    Button { identity.chooseImage() } label: {
                        Text(identity.isLoading ? "Загружаю…" : "Сменить картинку…")
                            .padding(.horizontal, 10).frame(height: 28)
                    }
                        .buttonStyle(DeepControlStyle(filled: true))
                    Spacer(minLength: 0)
                    DeepResetButton(title: "Вернуть логотип") { identity.restoreLogo() }
                }
                .disabled(identity.isLoading)
                Text("PNG · JPEG · GIF").foregroundStyle(appearance.secondary).font(.system(size: 11))
            }
        } right: {
            VStack(alignment: .leading, spacing: 7) {
                Text("Эффект картинки")
                DeepSegments(title: "Эффект картинки",
                    selection: Binding(get: { identity.effect }, set: { identity.selectEffect($0) }),
                    options: IdentityEffect.allCases.map { ($0, $0.title) })
                    .help(identity.effect.detail)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Сила эффекта")
                        Spacer()
                        Text("\(Int((identity.effectStrength * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(appearance.secondary)
                    }
                    .font(.system(size: 11))
                    Slider(value: Binding(get: { identity.effectStrength }, set: { identity.setEffectStrength($0) }), in: 0...1)
                        .accessibilityLabel("Сила эффекта картинки")
                }
                if reduceMotion {
                    Text("Движение уменьшено в настройках macOS.")
                        .font(.system(size: 11)).foregroundStyle(appearance.secondary)
                }
            }
        }
    }
}

private struct DeepVisualSettings: View {
    @ObservedObject var controller: AudioVisualController
    let showsMedia: Bool
    @Environment(\.surfaceAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DeepColumns {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Аудиореактивный визуал", isOn: Binding(get: { controller.enabled }, set: { value in
                    if value != controller.enabled { controller.toggle() }
                }))
                .toggleStyle(DeepSwitchStyle())
                if reduceMotion {
                    status("Движение уменьшено в настройках macOS.")
                } else if !showsMedia {
                    status("Переключись на Now Playing для предпросмотра.")
                } else if let diagnostic = controller.diagnostic {
                    status(diagnostic)
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Интенсивность")
                    Spacer()
                    Text("\(Int((controller.strength * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(appearance.secondary)
                }
                Slider(value: $controller.strength, in: 0...1).accessibilityLabel("Интенсивность визуала")
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(appearance.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// Small, local styles for Deep; no preference or controller state lives here.
private func deepControlFill(_ amount: Float, appearance: SurfaceAppearance) -> Color {
    // These fills sit only behind primary ink; keep its contrast without flattening
    // the track to protect secondary text that is outside the control.
    if !appearance.isGlass && !appearance.isTransparent {
        let mixed = SurfaceAppearance.mix(appearance.contrastRGB, appearance.inkRGB, amount)
        if SurfaceAppearance.contrast(appearance.inkRGB, mixed) < 4.5 {
            return appearance.fill(amount)
        }
    }
    return appearance.primary.opacity(Double(amount))
}

private struct DeepColumns<Left: View, Right: View>: View {
    @Environment(\.surfaceAppearance) private var appearance
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            left().frame(maxWidth: .infinity, alignment: .topLeading)
            right().frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay {
            Rectangle().fill(appearance.primary.opacity(0.10))
                .frame(width: 1).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct DeepSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var disabled: Set<Value> = []
    var height: CGFloat = 24
    @Environment(\.surfaceAppearance) private var appearance

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button { selection = option.0 } label: {
                    Text(option.1).lineLimit(1).minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity).frame(height: height)
                }
                .buttonStyle(DeepControlStyle(selected: selection == option.0, radius: 11))
                .disabled(disabled.contains(option.0))
                .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
                if index < options.count - 1 {
                    Rectangle().fill(appearance.primary.opacity(0.12))
                        .frame(width: 1, height: 14)
                        .opacity(selection == option.0 || selection == options[index + 1].0 ? 0 : 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(2)
        .background(deepControlFill(0.06, appearance: appearance), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

private struct DeepResetButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 12))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(DeepControlStyle())
        .accessibilityLabel(title).help(title)
    }
}

private struct DeepSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeepSwitchBody(configuration: configuration)
    }
}

private struct DeepSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.surfaceAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
                Capsule().fill(appearance.primary.opacity(configuration.isOn ? 0.30 : 0.14))
                    .frame(width: 36, height: 21)
                    .overlay {
                        Circle().fill(.white).frame(width: 17, height: 17)
                            .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                            .offset(x: configuration.isOn ? 7.5 : -7.5)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
            }
            .frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(DeepControlStyle())
    }
}

private struct DeepControlStyle: ButtonStyle {
    var selected = false
    var filled = false
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        DeepControlBody(configuration: configuration, selected: selected, filled: filled, radius: radius)
    }
}

private struct DeepControlBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let filled: Bool
    let radius: CGFloat
    @Environment(\.surfaceAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var selectionFill: Color {
        let amount: Float = colorScheme == .dark ? 0.18 : 0.40
        if !appearance.isGlass {
            let mixed = SurfaceAppearance.mix(appearance.contrastRGB, SIMD3(repeating: 1), amount)
            if SurfaceAppearance.contrast(appearance.inkRGB, mixed) < 4.5 {
                return appearance.oppositeInk.opacity(0.20)
            }
        }
        return .white.opacity(Double(amount))
    }

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? appearance.primary : appearance.muted)
            .contentShape(Rectangle())
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                if selected {
                    shape.fill(selectionFill)
                        .overlay(shape.strokeBorder(appearance.primary.opacity(0.06)))
                } else {
                    shape.fill(deepControlFill(isEnabled && configuration.isPressed ? 0.14
                        : isEnabled && hovering ? 0.09 : filled ? 0.06 : 0, appearance: appearance))
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
