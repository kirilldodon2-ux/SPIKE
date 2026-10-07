import AppKit

enum SurfaceLayout {
    static let wingWidth: CGFloat = 44
    static let contentHeight: CGFloat = 228
    static let minimumExpandedWidth: CGFloat = 500
    static let expandedSideAllowance: CGFloat = 176
    static let contentPadding: CGFloat = 16
    static let collapsedCornerRadius: CGFloat = 12
    static let miniTileSize: CGFloat = 24
    static let miniTileInset: CGFloat = 4
    static let miniTileCornerRadius = collapsedCornerRadius - miniTileInset
    static let collapsedWingWidth = miniTileSize + 2 * miniTileInset
    static let expandedCornerRadius: CGFloat = 26
    // Visually nest the camera's bottom corners inside the expanded surface.
    static let mirrorCornerRadius = expandedCornerRadius - contentPadding
    static let mediaTileSize: CGFloat = 140
    static let mediaTileCornerRadius: CGFloat = 14
    static let sideTabsContentPadding: CGFloat = 20
    static let sideTabsContentHeight = mediaTileSize + 2 * sideTabsContentPadding
    static let sideTabsCornerRadius = mediaTileCornerRadius + sideTabsContentPadding
    static let deepSettingsHeight: CGFloat = 216
    // Fixed tabs/footer need 110 pt; leave a usable row in the scroll viewport.
    static let minimumDeepSettingsHeight: CGFloat = 160
    static let deepBottomClearance: CGFloat = 12

    // Read the menu bar's standard font in points; display scaling remains macOS-owned.
    static var menuBarFont: NSFont { NSFont.menuBarFont(ofSize: 0) }
    static let sideTabSymbolWidth: CGFloat = 14
    static func sideTabLabelWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: menuBarFont]).width)
            + sideTabSymbolWidth + 5 + 16
    }

    static func expandedWidth(gap: CGFloat, sideTabs: Bool) -> CGFloat {
        let allowance = sideTabs
            ? 2 * (sideTabsContentPadding + wingWidth + sideTabLabelWidth("Now Playing"))
            : expandedSideAllowance
        return max(minimumExpandedWidth, gap + allowance)
    }

    static func sideTabZoneWidth(surfaceWidth: CGFloat, gap: CGFloat) -> CGFloat {
        max(0, (surfaceWidth - gap) / 2 - sideTabsContentPadding)
    }

    static func sideTabWidth(surfaceWidth: CGFloat, anchorWidth: CGFloat) -> CGFloat {
        max(0, (surfaceWidth - anchorWidth) / 2 - sideTabsContentPadding)
    }
}

struct SurfaceGeometry {
    let screen: NSRect
    let centerX: CGFloat
    let top: CGFloat
    let gap: CGFloat
    let barHeight: CGFloat
    let physical: Bool
    let visibleBottom: CGFloat

    init(screen: NSRect, visible: NSRect, inset: CGFloat,
         left: NSRect?, right: NSRect?, virtual: Bool) {
        self.screen = screen
        visibleBottom = max(screen.minY, visible.minY)
        if !virtual, inset > 0, let left, let right, right.minX > left.maxX {
            centerX = (left.maxX + right.minX) / 2
            top = screen.maxY
            gap = right.minX - left.maxX
            barHeight = inset
            physical = true
        } else {
            centerX = screen.midX
            // Virtual mode sits below the menu bar, including on a notched display.
            top = min(visible.maxY, screen.maxY - inset) - 6
            gap = 32
            barHeight = 32
            physical = false
        }
    }

    func deepHeight(sideTabs: Bool) -> CGFloat {
        let base = frame(expanded: true, sideTabs: sideTabs)
        let available = max(0, base.minY - visibleBottom - SurfaceLayout.deepBottomClearance)
        return available >= SurfaceLayout.minimumDeepSettingsHeight
            ? min(SurfaceLayout.deepSettingsHeight, available) : 0
    }

    func frame(expanded: Bool, sideTabs: Bool = false, deep: Bool = false) -> NSRect {
        let width = min(screen.width, expanded ? SurfaceLayout.expandedWidth(gap: gap, sideTabs: sideTabs)
                                                : gap + 2 * SurfaceLayout.collapsedWingWidth)
        let contentHeight = sideTabs ? SurfaceLayout.sideTabsContentHeight : SurfaceLayout.contentHeight
        let height = barHeight + (expanded ? contentHeight : 0)
            + (expanded && deep ? deepHeight(sideTabs: sideTabs) : 0)
        let x = min(max(screen.minX, centerX - width / 2), screen.maxX - width)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }
}

func checkGeometry() {
    // Global coordinates: secondary displays may have negative origins.
    let screen = NSRect(x: -1512, y: 120, width: 1512, height: 982)
    let left = NSRect(x: -1512, y: 1070, width: 666, height: 32)
    let right = NSRect(x: -666, y: 1070, width: 666, height: 32)
    let physical = SurfaceGeometry(screen: screen, visible: screen, inset: 32,
                                   left: left, right: right, virtual: false)
    precondition(physical.physical && physical.gap == 180)
    precondition(physical.frame(expanded: false).midX == -756)
    precondition(physical.frame(expanded: true).maxY == screen.maxY)
    precondition(physical.frame(expanded: false).minY == screen.maxY - 32)
    precondition(physical.frame(expanded: false).width == physical.gap + 2 * SurfaceLayout.collapsedWingWidth)
    precondition((SurfaceLayout.collapsedWingWidth - SurfaceLayout.miniTileSize) / 2 == SurfaceLayout.miniTileInset)
    let compact = physical.frame(expanded: true, sideTabs: true)
    let standard = physical.frame(expanded: true)
    precondition(compact.maxY == standard.maxY && compact.width >= standard.width)
    precondition(compact.height == 212 && standard.height == 260)
    precondition((compact.height - physical.barHeight - SurfaceLayout.mediaTileSize) / 2 == 20)
    let labelWidth = SurfaceLayout.sideTabLabelWidth("Now Playing")
    precondition(SurfaceLayout.sideTabWidth(surfaceWidth: compact.width,
        anchorWidth: physical.gap + 2 * SurfaceLayout.wingWidth) >= labelWidth)
    let leftZoneWidth = SurfaceLayout.sideTabZoneWidth(surfaceWidth: compact.width, gap: physical.gap)
    let miniCenter = (compact.width - physical.gap) / 2 - SurfaceLayout.wingWidth / 2
    precondition(SurfaceLayout.sideTabsContentPadding + leftZoneWidth == (compact.width - physical.gap) / 2)
    precondition(miniCenter - SurfaceLayout.miniTileSize / 2 >= SurfaceLayout.sideTabsContentPadding)
    precondition(miniCenter + SurfaceLayout.miniTileSize / 2 <= SurfaceLayout.sideTabsContentPadding + leftZoneWidth)
    precondition(physical.frame(expanded: false, sideTabs: true) == physical.frame(expanded: false))
    let virtual = SurfaceGeometry(screen: screen, visible: screen, inset: 32,
                                  left: left, right: right, virtual: true)
    precondition(!virtual.physical && virtual.frame(expanded: false).maxY == 1064)
    precondition(virtual.frame(expanded: true, sideTabs: true).maxY == virtual.frame(expanded: true).maxY)
    let absent = SurfaceGeometry(screen: screen, visible: screen, inset: 0,
                                 left: nil, right: nil, virtual: false)
    precondition(!absent.physical)
    // Actual M3 Pro screen report: odd-point notch width, half-point side boundaries.
    let retina = SurfaceGeometry(screen: NSRect(x: 0, y: 0, width: 1512, height: 982),
        visible: NSRect(x: 0, y: 0, width: 1512, height: 950), inset: 32,
        left: NSRect(x: 0, y: 950, width: 663.5, height: 32),
        right: NSRect(x: 848.5, y: 950, width: 663.5, height: 32), virtual: false)
    let frame = retina.frame(expanded: false)
    precondition(retina.gap == 185 && frame.width == 249 && frame.midX == 756)
    precondition([frame.minX, frame.maxX, frame.minY, frame.maxY].allSatisfy { ($0 * 2).rounded() == $0 * 2 })
    for geometry in [physical, virtual, absent, retina] {
        for sideTabs in [false, true] {
            let base = geometry.frame(expanded: true, sideTabs: sideTabs)
            let deep = geometry.frame(expanded: true, sideTabs: sideTabs, deep: true)
            precondition(base == geometry.frame(expanded: true, sideTabs: sideTabs, deep: false))
            precondition(deep.maxY == base.maxY && deep.minX == base.minX && deep.width == base.width)
            precondition(deep.height - base.height == SurfaceLayout.deepSettingsHeight)
            precondition(geometry.frame(expanded: false, sideTabs: sideTabs, deep: true)
                == geometry.frame(expanded: false, sideTabs: sideTabs))
        }
    }
    let short = SurfaceGeometry(screen: NSRect(x: -800, y: -400, width: 800, height: 480),
        visible: NSRect(x: -800, y: -350, width: 800, height: 398), inset: 0,
        left: nil, right: nil, virtual: true)
    let shortDeep = short.frame(expanded: true, sideTabs: true, deep: true)
    precondition(short.deepHeight(sideTabs: true) > 0
        && short.deepHeight(sideTabs: true) < SurfaceLayout.deepSettingsHeight)
    precondition(shortDeep.minY == short.visibleBottom + SurfaceLayout.deepBottomClearance)
    precondition(short.deepHeight(sideTabs: false) == 0)
    precondition(short.frame(expanded: true, deep: true) == short.frame(expanded: true))
    let tiny = SurfaceGeometry(screen: NSRect(x: 0, y: 0, width: 800, height: 180),
        visible: NSRect(x: 0, y: 0, width: 800, height: 148), inset: 0,
        left: nil, right: nil, virtual: true)
    precondition(tiny.deepHeight(sideTabs: true) == 0)
    precondition(tiny.frame(expanded: true, sideTabs: true, deep: true)
        == tiny.frame(expanded: true, sideTabs: true))
    print("Deep geometry checks passed: unchanged base/closed frames, fixed top/width, Dock clearance and bounded settings height.")
    print("Geometry checks passed: actual screen notch gap, fixed top, virtual mode, compact 212 pt / classic 260 pt, 20 pt body margins, expanded header zones, balanced collapsed 4 pt slot insets / 249 pt on M3 Pro.")
}
