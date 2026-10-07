import AppKit
import SwiftUI

// Only overflowing, visible media labels animate. Duplicate text makes the
// wrap seamless; the accessibility tree still exposes one complete label.
struct MarqueeText: View {
    let text: String
    let font: NSFont
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var epoch = Date()

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            if active && !reduceMotion && width > 0 && textWidth > width + 1 {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let distance = textWidth + 28
                    let cycle = distance / 22 + 1.4
                    let phase = max(0, timeline.date.timeIntervalSince(epoch)).truncatingRemainder(dividingBy: cycle)
                    let offset = max(0, phase - 1.4) * 22
                    HStack(spacing: 28) {
                        label.fixedSize()
                        label.fixedSize()
                    }
                    .offset(x: -offset)
                    .frame(width: width, height: ceil(font.ascender - font.descender + font.leading) + 4, alignment: .leading)
                    .mask(LinearGradient(stops: [
                        .init(color: offset > 0 ? .clear : .white, location: 0),
                        .init(color: .white, location: min(0.2, 6 / width)),
                        .init(color: .white, location: 1 - min(0.2, 6 / width)),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing))
                }
                .onAppear { epoch = Date() }
            } else {
                label.lineLimit(1).truncationMode(.tail)
                    .frame(width: width, height: ceil(font.ascender - font.descender + font.leading) + 4, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ceil(font.ascender - font.descender + font.leading) + 4)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onChange(of: text) { _, _ in epoch = Date() }
        .onChange(of: active) { _, _ in epoch = Date() }
        .onChange(of: reduceMotion) { _, _ in epoch = Date() }
    }

    private var label: some View { Text(text).font(Font(font)) }
}
