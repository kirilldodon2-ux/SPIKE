import AppKit
import SwiftUI

// A local display fill light, independent of macOS Edge Light and camera effects.
// Draw only on light changes; this is not a continuously animated overlay.
@MainActor final class MirrorScreenLight {
    // Parked by the product owner. No instance or UI is connected in the app.
    static let isEnabled = false

    private var screenFrame: NSRect?
    private var panel: MirrorLightPanel?
    private var edgeView: MirrorEdgeLightView?

    func setScreen(_ screen: NSScreen?) {
        hide()
        screenFrame = screen?.frame
        if let screenFrame { panel?.setFrame(screenFrame, display: false) }
    }

    func setStrength(_ strength: Double, warmth: Double) {
        guard Self.isEnabled, strength.isFinite, strength > 0, let screenFrame else {
            hide()
            return
        }
        if panel == nil {
            let window = MirrorLightPanel(contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            // Above application content, below the black SPIKE surface and system menus.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            if #available(macOS 13.0, *) { window.collectionBehavior.insert(.canJoinAllApplications) }
            let view = MirrorEdgeLightView(frame: NSRect(origin: .zero, size: screenFrame.size))
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            edgeView = view
            panel = window
        }
        edgeView?.warmth = warmth.isFinite ? min(1, max(0, warmth)) : 0.5
        edgeView?.strength = min(1, strength)
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
    }

    func hide() { panel?.orderOut(nil) }
}

private final class MirrorLightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MirrorEdgeLightView: NSView {
    var strength = 0.0 { didSet { needsDisplay = true } }
    var warmth = 0.5 { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        let width = min(bounds.width, bounds.height) * (0.035 + 0.105 * strength)
        let alpha = 0.82 * strength
        let space = CGColorSpaceCreateDeviceRGB()
        // A perceptual cool-white → neutral → warm-white blend, not claimed Kelvin values.
        let neutral: [CGFloat] = [1, 0.985, 0.95]
        let endpoint: [CGFloat] = warmth < 0.5 ? [0.78, 0.88, 1] : [1, 0.78, 0.52]
        let mix = CGFloat(abs(warmth - 0.5) * 2)
        let rgb = zip(neutral, endpoint).map { $0 + ($1 - $0) * mix }
        let colors = [CGColor(colorSpace: space, components: rgb + [CGFloat(alpha)])!,
                      CGColor(colorSpace: space, components: rgb + [CGFloat(alpha * 0.72)])!,
                      CGColor(colorSpace: space, components: rgb + [0])!] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors,
                                        locations: [0, 0.3, 1]) else { return }
        let edges: [(CGRect, CGPoint, CGPoint)] = [
            (CGRect(x: 0, y: 0, width: width, height: bounds.height),
             CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0)),
            (CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height),
             CGPoint(x: bounds.width, y: 0), CGPoint(x: bounds.width - width, y: 0)),
            (CGRect(x: 0, y: 0, width: bounds.width, height: width),
             CGPoint(x: 0, y: 0), CGPoint(x: 0, y: width)),
            (CGRect(x: 0, y: bounds.height - width, width: bounds.width, height: width),
             CGPoint(x: 0, y: bounds.height), CGPoint(x: 0, y: bounds.height - width))
        ]
        for (rect, start, end) in edges {
            context.saveGState()
            context.clip(to: rect)
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
            context.restoreGState()
        }
    }
}

struct MirrorLightControl: View {
    @ObservedObject var controller: MirrorController

    var body: some View {
        HStack(spacing: 6) {
            Button { controller.toggleLight() } label: {
                Image(systemName: controller.lightStrength > 0 ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 18)
            }
            .buttonStyle(SurfaceButtonStyle())
            .accessibilityLabel(controller.lightStrength > 0 ? "Выключить подсветку" : "Включить подсветку")
            .accessibilityValue(controller.lightStrength > 0 ? "Включена" : "Выключена")
            Slider(value: Binding(get: { controller.lightWarmth },
                                  set: { controller.setLightWarmth($0) }), in: 0...1)
                .tint(Color(red: 1, green: 0.78, blue: 0.52))
                .frame(width: 76)
                .accessibilityLabel("Тепло подсветки Mirror")
                .accessibilityValue("\(Int(controller.lightWarmth * 100)) процентов")
                .help("Холоднее ← → Теплее · не включает свет")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .disabled(controller.status != .ready)
        .help("Включить или выключить свет по краям экрана")
    }
}
