import SwiftUI

/// One passive native background, sharing the foreground's existing silhouette.
struct SurfaceMaterialView: View {
    let appearance: SurfaceAppearance
    let shape: UnevenRoundedRectangle
    let attachedToScreenTop: Bool

    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        Group {
            if appearance.isGlass, #available(macOS 26.0, *) {
                GeometryReader { geometry in
                    // Put the native top rim outside the visible screen, not across it.
                    // Extending upward keeps the bottom edge and its radii in place.
                    let extensionHeight: CGFloat = attachedToScreenTop ? 12 : 0
                    Color.clear
                        .frame(width: geometry.size.width,
                               height: geometry.size.height + extensionHeight)
                        .glassEffect(.regular, in: shape)
                        .offset(y: -extensionHeight)
                }
            } else {
                appearance.background
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
