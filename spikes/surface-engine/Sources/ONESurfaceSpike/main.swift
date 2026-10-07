import AppKit
import SwiftUI
import QuartzCore
import Darwin

@MainActor final class SurfaceState: ObservableObject {
    @Published var expanded = false
    @Published var gap: CGFloat = 32
    @Published var barHeight: CGFloat = 32
    @Published var expandedContentWidth: CGFloat = SurfaceLayout.minimumExpandedWidth
    @Published var attachedToScreenTop = false
    @Published var message = "Наведи курсор · проверь ощущение"
    @Published var contentMode: SurfaceContentMode = .media
    // Compact tabs are the launch default; classic layout is a session override.
    @Published var usesSideTabs = true
    @Published var hoveredSideTab: SurfaceContentMode?
    @Published var appearance = SurfaceAppearance.load()
    @Published var systemColors: SurfaceSystemColors?
    @Published var settingsOpen = false
    @Published var settingsPage: DeepSettingsPage = .appearance
    @Published var settingsHeight: CGFloat = SurfaceLayout.deepSettingsHeight
    var settingsActions = DeepSettingsActions()
    var contentHeight: CGFloat {
        usesSideTabs ? SurfaceLayout.sideTabsContentHeight : SurfaceLayout.contentHeight
    }
    var contentPadding: CGFloat {
        usesSideTabs ? SurfaceLayout.sideTabsContentPadding : SurfaceLayout.contentPadding
    }
    var expandedCornerRadius: CGFloat {
        usesSideTabs ? SurfaceLayout.sideTabsCornerRadius : SurfaceLayout.expandedCornerRadius
    }
    var mirrorCornerRadius: CGFloat { expandedCornerRadius - contentPadding }
    let ambientMedia = AmbientMediaController()
    let mirror = MirrorController()
    let audioVisual = AudioVisualController()
    let identity = IdentityController()

    func updateVisualVisibility() {
        audioVisual.setVisible(expanded && contentMode == .media
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

struct SurfaceView: View {
    @ObservedObject var state: SurfaceState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var systemColorScheme
    private var appearance: SurfaceAppearance {
        state.appearance.resolvingSystemColors(state.systemColors)
            .opaqueFallback(reduceTransparency || contrast == .increased,
            glassAvailable: SurfaceMaterialView.glassAvailable)
    }

    var body: some View {
        GeometryReader { geometry in
            // One source of visual progress: the actual animated window height.
            // Keep content mounted so layout doesn't jump before the resize starts.
            let progress = min(1, max(0, (geometry.size.height - state.barHeight)
                                      / state.contentHeight))
            let wingWidth = SurfaceLayout.collapsedWingWidth
                + (SurfaceLayout.wingWidth - SurfaceLayout.collapsedWingWidth) * progress
            let shape = UnevenRoundedRectangle(
                bottomLeadingRadius: SurfaceLayout.collapsedCornerRadius
                    + (state.expandedCornerRadius - SurfaceLayout.collapsedCornerRadius) * progress,
                bottomTrailingRadius: SurfaceLayout.collapsedCornerRadius
                    + (state.expandedCornerRadius - SurfaceLayout.collapsedCornerRadius) * progress)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    CollapsedMediaWing(controller: state.ambientMedia,
                        wingWidth: wingWidth)
                    Color.clear.frame(width: state.gap)
                    IdentityAnchorView(identity: state.identity,
                        wingWidth: wingWidth)
                }
                .accessibilityHidden(state.usesSideTabs && progress >= 0.99)
                .frame(maxWidth: .infinity)
                .frame(height: state.barHeight)
                .overlay {
                    if state.usesSideTabs {
                        SurfaceSideTabs(state: state, progress: progress,
                            width: geometry.size.width)
                            .allowsHitTesting(progress >= 0.99)
                            .accessibilityHidden(progress < 0.99)
                    }
                }
                SurfaceContentView(state: state)
                // Stable text layout throughout the transition; reveal by clipping.
                .frame(width: state.expandedContentWidth,
                       height: state.contentHeight)
                .opacity(progress)
                .accessibilityHidden(progress < 0.99)
                // Main progress still uses only the original content height.
                // The extra frame reveals Deep without moving the live block.
                let settingsProgress = state.settingsHeight > 0
                    ? min(1, max(0, (geometry.size.height - state.barHeight - state.contentHeight)
                                / state.settingsHeight)) : 0
                DeepSettingsView(state: state)
                    .frame(width: state.expandedContentWidth, height: state.settingsHeight)
                    .opacity(settingsProgress)
                    .allowsHitTesting(state.settingsOpen && settingsProgress >= 0.99)
                    .accessibilityHidden(!state.settingsOpen || settingsProgress < 0.99)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .foregroundStyle(appearance.primary)
            .textSelection(.disabled)
            .contentShape(Rectangle())
            .background {
                SurfaceMaterialView(appearance: appearance, shape: shape,
                    attachedToScreenTop: state.attachedToScreenTop)
            }
            .clipShape(shape)
            .transaction { $0.animation = nil }
        }
        .environment(\.surfaceAppearance, appearance)
        .environment(\.colorScheme, appearance.isGlass || appearance.usesSystemColors ? systemColorScheme
                     : (appearance.usesLightInk ? .dark : .light))
    }
}

@MainActor final class SurfacePanel: NSPanel {
    var settingsFocusEnabled = false
    var dismissSettings: (() -> Void)?
    override var canBecomeKey: Bool { settingsFocusEnabled }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        if settingsFocusEnabled { dismissSettings?() }
        else { super.cancelOperation(sender) }
    }
}

@MainActor final class SurfaceHost: NSHostingView<SurfaceView> {
    override var needsPanelToBecomeKey: Bool {
        (window as? SurfacePanel)?.settingsFocusEnabled == true
    }
    var hover: ((Bool) -> Void)?
    var appearanceChanged: (() -> Void)?
    var click: (() -> Void)?
    var drag: ((String, Bool) -> Void)?
    var headerHeight: CGFloat = 32
    var headerGapWidth: CGFloat?
    var sideTabHover: ((SurfaceContentMode?) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    private var tracking: NSTrackingArea?
    private var pointerInside = false

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved,
                                               .activeAlways, .inVisibleRect]
        if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: options,
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        pointerInside = true
        hover?(true)
    }
    override func mouseExited(with event: NSEvent) { pointerInside = false; sideTabHover?(nil); hover?(false) }
    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        if !pointerInside { pointerInside = true; hover?(true) }
        guard let gap = headerGapWidth, bounds.width > gap + 2 * SurfaceLayout.wingWidth + 16 else {
            sideTabHover?(nil)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let width = SurfaceLayout.sideTabZoneWidth(surfaceWidth: bounds.width, gap: gap)
        let y = isFlipped ? 0 : bounds.height - headerHeight
        let inset = SurfaceLayout.sideTabsContentPadding
        let left = NSRect(x: inset, y: y, width: width, height: headerHeight)
        let right = NSRect(x: bounds.width - inset - width, y: y, width: width, height: headerHeight)
        sideTabHover?(left.contains(point) ? .media : right.contains(point) ? .mirror : nil)
    }
    func synchronizeHoverAfterReconfigure() {
        let inside = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        pointerInside = inside
        if inside { NSCursor.arrow.set() }
        hover?(inside)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inHeader = isFlipped ? point.y <= headerHeight : point.y >= bounds.height - headerHeight
        // Expanded wing clicks (including mini images) belong to SwiftUI.
        if inHeader, let gap = headerGapWidth,
           bounds.width > gap + 2 * SurfaceLayout.wingWidth + 16,
           abs(point.x - bounds.midX) > gap / 2,
           point.x >= SurfaceLayout.sideTabsContentPadding,
           point.x <= bounds.width - SurfaceLayout.sideTabsContentPadding {
            super.mouseDown(with: event)
            return
        }
        if inHeader && point.x > bounds.midX { click?() }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        drag?("Drag entered", true)
        return [] // Diagnostic lifecycle only: never advertise a working drop.
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { drag?("Drag cancelled / exited", false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Diagnostic acknowledgement only. No URL access, copy, move or retention.
        drag?("Drop получен · файл не сохранён", false)
        return false
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        drag?("Drag завершён · файлы не сохранены", false)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSWindowDelegate {
    private var colorPickerOpen = false
    private var termination = SurfaceTerminationGate()
    let state = SurfaceState()
    var panel: SurfacePanel!
    var host: SurfaceHost!
    var virtual = false
    var selectedDisplay: String?
    var geometry: SurfaceGeometry?
    var pendingCollapse: DispatchWorkItem?
    var dragging = false
    var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SurfacePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.dismissSettings = { [weak self] in
            guard let self, !self.menuOpen else { return }
            self.closeSettings()
        }
        state.settingsActions = DeepSettingsActions(
            close: { [weak self] in self?.closeSettings() },
            chooseColor: { [weak self] in self?.showColorPicker() },
            toggleGlass: { [weak self] in self?.toggleGlass() },
            toggleTransparency: { [weak self] in self?.toggleTransparency() },
            toggleRainbow: { [weak self] in self?.toggleRainbow() },
            toggleSystemColors: { [weak self] in self?.toggleSystemColors() },
            resetColor: { [weak self] in self?.restoreSurfaceColor() },
            changeOpacity: { [weak self] value in self?.changeSurfaceOpacity(value) },
            additional: { [weak self] in self?.showAdditionalSettings() })
        // Below this level the system menu can intercept the notch hover/click.
        panel.level = .statusBar
        // Keep the anchored utility surface out of Exposé's window rearrangement.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if #available(macOS 13.0, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        host = SurfaceHost(rootView: SurfaceView(state: state))
        host.appearanceChanged = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshSystemColors() }
        }
        host.sizingOptions = []
        host.registerForDraggedTypes([.fileURL])
        host.hover = { [weak self] inside in self?.hover(inside) }
        host.sideTabHover = { [weak self] mode in
            guard let self, self.state.hoveredSideTab != mode else { return }
            self.state.hoveredSideTab = mode
        }
        host.click = { [weak self] in
            guard let self else { return }
            self.toggleExpanded()
        }
        host.drag = { [weak self] message, active in
            guard let self else { return }
            self.dragging = active
            self.state.message = message
            print(message)
            if active { self.pendingCollapse?.cancel(); self.expand(true) }
            else { self.hover(false) }
        }
        state.mirror.onVisibilityHoldEnded = { [weak self] in
            guard let self, self.state.expanded, self.state.contentMode == .mirror,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.hover(false)
        }
        panel.contentView = host
        NotificationCenter.default.addObserver(self, selector: #selector(refreshSystemColors),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
        refreshSystemColors()
        NotificationCenter.default.addObserver(self, selector: #selector(reconfigure),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reconfigure), name: name, object: nil)
        }
        reconfigure()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if termination.hasReplied { return .terminateNow }
        guard termination.begin(waitForMirror: state.mirror.keepsMirrorOpen) else { return .terminateLater }
        state.audioVisual.finish { [weak self, weak sender] cleaned in
            guard let self, let sender else { return }
            if !cleaned { NSLog("SPIKE audio cleanup exhausted retries during quit") }
            if self.termination.audioDidFinish() { sender.reply(toApplicationShouldTerminate: true) }
        }
        // Independent of the worker queue, which may be stuck in a HAL call.
        // This deadline applies only to audio; an unfinished MOV still holds quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak sender] in
            guard let self, let sender, self.termination.awaitingAudio else { return }
            NSLog("SPIKE audio quit deadline reached; retained resources left to process termination")
            if self.termination.audioDidFinish() { sender.reply(toApplicationShouldTerminate: true) }
        }
        if state.mirror.keepsMirrorOpen {
            state.mirror.finishBeforeQuitting { [weak self, weak sender] in
                guard let self, let sender else { return }
                if self.termination.mirrorDidFinish() { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard colorPickerOpen else { return }
        // NSColorPanel can hide on deactivation without windowWillClose.
        NSColorPanel.shared.close()
        colorPickerOpen = false
        hover(panel.frame.contains(NSEvent.mouseLocation))
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.ambientMedia.stop()
        state.mirror.deactivate()
    }

    func displayID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
    }

    @objc func reconfigure() {
        pendingCollapse?.cancel()
        dragging = false
        state.expanded = state.settingsOpen
        state.updateVisualVisibility()
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { displayID($0) == selectedDisplay })
                ?? screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first else {
            panel.orderOut(nil)
            return
        }
        if !screens.contains(where: { displayID($0) == selectedDisplay }) { selectedDisplay = nil }
        let next = SurfaceGeometry(screen: screen.frame, visible: screen.visibleFrame,
            inset: screen.safeAreaInsets.top, left: screen.auxiliaryTopLeftArea,
            right: screen.auxiliaryTopRightArea, virtual: virtual)
        geometry = next
        state.settingsHeight = next.deepHeight(sideTabs: state.usesSideTabs)
        if state.settingsOpen && state.settingsHeight == 0 {
            state.settingsOpen = false
            endSettingsFocus()
        }
        state.attachedToScreenTop = next.physical
        state.gap = next.gap
        state.barHeight = next.barHeight
        state.expandedContentWidth = next.frame(expanded: true, sideTabs: state.usesSideTabs).width
        host.headerHeight = next.barHeight
        host.headerGapWidth = state.usesSideTabs ? next.gap : nil
        panel.setFrame(next.frame(expanded: state.expanded, sideTabs: state.usesSideTabs,
                                 deep: state.settingsOpen), display: true)
        host.updateTrackingAreas()
        panel.orderFrontRegardless()
        rebuildMenu()
        host.synchronizeHoverAfterReconfigure()
    }

    func expand(_ value: Bool) {
        guard let geometry, state.expanded != value else { return }
        state.expanded = value
        if !value {
            state.hoveredSideTab = nil
            state.settingsOpen = false
            endSettingsFocus()
        }
        state.updateVisualVisibility()
        resize(to: geometry.frame(expanded: value, sideTabs: state.usesSideTabs, deep: state.settingsOpen))
    }

    private func resize(to frame: NSRect) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    func hover(_ inside: Bool) {
        pendingCollapse?.cancel()
        guard !menuOpen else { return }
        if inside { expand(true); return }
        guard !dragging, !colorPickerHoldsSurface, !state.settingsOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.dragging, !self.menuOpen, !self.colorPickerHoldsSurface,
                  !self.state.settingsOpen,
                  !self.state.mirror.keepsMirrorOpen,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.expand(false)
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private var colorPickerHoldsSurface: Bool {
        colorPickerOpen && NSColorPanel.shared.isVisible
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = item("Открыть / свернуть", #selector(toggleExpanded))
        _ = item("Настройки SPIKE…", #selector(showSettings))
        let mode = item("Тест: поверхность без брови", #selector(toggleVirtual))
        mode.state = virtual ? .on : .off
        let tabs = item("Классические вкладки", #selector(toggleSideTabs))
        tabs.state = state.usesSideTabs ? .off : .on
        let media = item("Эксперимент: системные данные плеера", #selector(toggleSystemMedia))
        media.state = state.ambientMedia.experimentalMediaEnabled ? .on : .off
        let music = item("Приоритет музыки", #selector(toggleMusicPriority))
        music.state = state.ambientMedia.musicPriorityEnabled ? .on : .off
        if state.ambientMedia.musicPriorityEnabled {
            _ = item("Разрешить Spotify и Music…", #selector(requestMusicPermissions))
        }
        let visual = item("Аудиореактивный визуал", #selector(toggleVisual))
        visual.state = state.audioVisual.enabled ? .on : .off
        _ = item("Настройки визуала…", #selector(showVisualSettings))
        menu.addItem(.separator())
        _ = item("Сменить картинку…", #selector(chooseIdentityImage))
        _ = item("Эффекты картинки…", #selector(showIdentitySettings))
        _ = item("Вернуть логотип ONE", #selector(restoreIdentityLogo))
        let glass = item("Liquid Glass · эксперимент", #selector(toggleGlass))
        glass.state = state.appearance.isGlass ? .on : .off
        _ = item("Цвет SPIKE…", #selector(showColorPicker))
        let rainbow = item("Rainbow", #selector(toggleRainbow))
        rainbow.state = state.appearance.isRainbow && !state.appearance.usesSystemColors ? .on : .off
        let transparency = item("Прозрачный фон", #selector(toggleTransparency))
        transparency.state = state.appearance.isTransparent ? .on : .off
        _ = item("Вернуть чёрный цвет", #selector(restoreSurfaceColor))
        menu.addItem(.separator())
        _ = item("Папка для снимков и видео…", #selector(chooseSelfieFolder))
        _ = item("Открыть папку Mirror", #selector(openSelfieFolder))
        menu.addItem(.separator())
        let auto = item("Экран: автоматически", #selector(selectScreen(_:)))
        auto.state = selectedDisplay == nil ? .on : .off
        for screen in NSScreen.screens {
            let entry = item(screen.localizedName, #selector(selectScreen(_:)))
            entry.representedObject = displayID(screen)
            entry.state = selectedDisplay == displayID(screen) ? .on : .off
        }
        menu.addItem(.separator())
        _ = item("Выйти из ONE Spike", #selector(quit))
        host.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        // An optional renderer can disable itself between menu openings.
        menu.items.first { $0.action == #selector(toggleVisual) }?.state = state.audioVisual.enabled ? .on : .off
        menu.items.first { $0.action == #selector(toggleTransparency) }?.state = state.appearance.isTransparent ? .on : .off
        menu.items.first { $0.action == #selector(toggleRainbow) }?.state =
            state.appearance.isRainbow && !state.appearance.usesSystemColors ? .on : .off
        let glass = menu.items.first { $0.action == #selector(toggleGlass) }
        glass?.state = state.appearance.isGlass ? .on : .off
        glass?.title = state.appearance.isGlass && !effectiveGlass
            ? "Liquid Glass · временно обычный фон" : "Liquid Glass · эксперимент"
        menu.items.first { $0.action == #selector(showColorPicker) }?.title = effectiveGlass
            ? "Цвет обычного фона…" : "Цвет SPIKE…"
        let imageItem = menu.items.first { $0.action == #selector(chooseIdentityImage) }
        imageItem?.title = state.identity.isLoading ? "Загружаю картинку…" : "Сменить картинку…"
        imageItem?.isEnabled = !state.identity.isLoading
        menu.items.first { $0.action == #selector(restoreIdentityLogo) }?.isEnabled = !state.identity.isLoading
        menuOpen = true
        pendingCollapse?.cancel()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        hover(false)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showSettings) || item.action == #selector(showIdentitySettings)
            || item.action == #selector(showVisualSettings) {
            return (geometry?.deepHeight(sideTabs: state.usesSideTabs) ?? 0) > 0
        }
        if item.action == #selector(toggleGlass) {
            return SurfaceMaterialView.glassAvailable || state.appearance.isGlass
        }
        if item.action == #selector(showColorPicker) {
            return !effectiveGlass && !state.appearance.usesSystemColors
        }
        if item.action == #selector(toggleRainbow)
            || item.action == #selector(toggleTransparency) { return !effectiveGlass }
        if item.action == #selector(restoreSurfaceColor) {
            return state.appearance != state.appearance.resettingColor()
        }
        if item.action == #selector(chooseIdentityImage) || item.action == #selector(restoreIdentityLogo) {
            return !state.identity.isLoading
        }
        return true
    }
    @objc func chooseSelfieFolder() { state.mirror.chooseSaveFolder() }
    @objc func chooseIdentityImage() {
        state.settingsPage = .identity
        showSettings()
        state.identity.chooseImage()
        if state.settingsOpen { panel.makeKeyAndOrderFront(nil) }
    }
    @objc func restoreIdentityLogo() { state.identity.restoreLogo() }
    @objc func showSettings() {
        guard let geometry, geometry.deepHeight(sideTabs: state.usesSideTabs) > 0 else { return }
        pendingCollapse?.cancel()
        state.settingsHeight = geometry.deepHeight(sideTabs: state.usesSideTabs)
        state.settingsOpen = true
        panel.settingsFocusEnabled = true
        if state.expanded {
            resize(to: geometry.frame(expanded: true, sideTabs: state.usesSideTabs, deep: true))
        } else { expand(true) }
        // Context-menu tracking must finish before the nonactivating panel takes key focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.settingsOpen, NSApp.modalWindow == nil else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
    }
    func closeSettings() {
        guard state.settingsOpen, let geometry else { return }
        pendingCollapse?.cancel()
        if colorPickerOpen { NSColorPanel.shared.close() }
        state.settingsOpen = false
        endSettingsFocus()
        resize(to: geometry.frame(expanded: true, sideTabs: state.usesSideTabs))
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.32
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.state.settingsOpen else { return }
            self.host.synchronizeHoverAfterReconfigure()
        }
    }
    private func endSettingsFocus() {
        panel.settingsFocusEnabled = false
        // AppKit sends resignKey automatically on orderOut; never call that override directly.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
    func showAdditionalSettings() {
        guard state.settingsOpen else { return }
        let menu = NSMenu()
        menu.delegate = self
        func item(_ title: String, _ action: Selector, in parent: NSMenu) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            parent.addItem(entry)
            return entry
        }
        _ = item("Папка для снимков и видео…", #selector(chooseSelfieFolder), in: menu)
        _ = item("Открыть папку Mirror", #selector(openSelfieFolder), in: menu)
        menu.addItem(.separator())
        let music = item("Приоритет музыки", #selector(toggleMusicPriority), in: menu)
        music.state = state.ambientMedia.musicPriorityEnabled ? .on : .off
        if state.ambientMedia.musicPriorityEnabled {
            _ = item("Разрешить Spotify и Music…", #selector(requestMusicPermissions), in: menu)
        }
        let screens = NSMenu()
        let screenItem = NSMenuItem(title: "Экран", action: nil, keyEquivalent: "")
        screenItem.submenu = screens
        menu.addItem(screenItem)
        let auto = item("Автоматически", #selector(selectScreen(_:)), in: screens)
        auto.state = selectedDisplay == nil ? .on : .off
        for screen in NSScreen.screens {
            let entry = item(screen.localizedName, #selector(selectScreen(_:)), in: screens)
            entry.representedObject = displayID(screen)
            entry.state = selectedDisplay == displayID(screen) ? .on : .off
        }
        let experiments = NSMenu()
        let advancedItem = NSMenuItem(title: "Эксперименты", action: nil, keyEquivalent: "")
        advancedItem.submenu = experiments
        menu.addItem(advancedItem)
        let tabs = item("Классические вкладки", #selector(toggleSideTabs), in: experiments)
        tabs.state = state.usesSideTabs ? .off : .on
        let virtualMode = item("Поверхность без брови", #selector(toggleVirtual), in: experiments)
        virtualMode.state = virtual ? .on : .off
        let helper = item("Системные данные плеера", #selector(toggleSystemMedia), in: experiments)
        helper.state = state.ambientMedia.experimentalMediaEnabled ? .on : .off
        menu.addItem(.separator())
        _ = item("Выйти из SPIKE", #selector(quit), in: menu)
        let point = NSPoint(x: SurfaceLayout.sideTabsContentPadding,
                            y: host.isFlipped ? host.bounds.height - 20 : 20)
        menu.popUp(positioning: nil, at: point, in: host)
    }
    @objc func showColorPicker() {
        pendingCollapse?.cancel()
        colorPickerOpen = true
        expand(true)
        let picker = NSColorPanel.shared
        syncColorPicker()
        picker.isContinuous = true
        picker.delegate = self
        picker.setTarget(self)
        picker.setAction(#selector(surfaceColorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        picker.makeKeyAndOrderFront(nil)
    }
    @objc func surfaceColorChanged(_ sender: NSColorPanel) {
        guard let appearance = SurfaceAppearance(color: sender.color, preserving: state.appearance) else { return }
        state.appearance = appearance
        appearance.save()
    }
    func changeSurfaceOpacity(_ value: Double) {
        guard value.isFinite else { return }
        state.appearance.opacity = min(1, max(0, value))
        state.appearance.save()
        if colorPickerOpen { syncColorPicker() }
    }
    @objc func restoreSurfaceColor() {
        state.appearance = state.appearance.resettingColor()
        state.appearance.save()
        if colorPickerOpen { syncColorPicker() }
    }
    @objc func toggleTransparency() {
        state.appearance.isTransparent.toggle()
        state.appearance.save()
        if colorPickerOpen { syncColorPicker() }
        rebuildMenu()
    }
    @objc func toggleRainbow() {
        if state.appearance.usesSystemColors {
            state.appearance.usesSystemColors = false
            state.appearance.isRainbow = true
        } else { state.appearance.isRainbow.toggle() }
        state.appearance.save()
        if colorPickerOpen { syncColorPicker() }
        rebuildMenu()
    }
    @objc func refreshSystemColors() {
        guard let colors = SurfaceSystemColors.resolve(for: NSApp.effectiveAppearance),
              colors != state.systemColors else { return }
        state.systemColors = colors
    }
    func toggleSystemColors() {
        if colorPickerOpen { NSColorPanel.shared.close() }
        state.appearance.usesSystemColors.toggle()
        state.appearance.save()
        rebuildMenu()
    }
    private var effectiveGlass: Bool {
        state.appearance.opaqueFallback(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            glassAvailable: SurfaceMaterialView.glassAvailable).isGlass
    }
    @objc func toggleGlass() {
        // Finish the existing picker session before its RGB/alpha controls become inactive.
        if colorPickerOpen { NSColorPanel.shared.close() }
        state.appearance.material = state.appearance.isGlass ? .solid : .glass
        state.appearance.save()
        rebuildMenu()
    }
    private func syncColorPicker() {
        let picker = NSColorPanel.shared
        picker.setTarget(nil)
        picker.showsAlpha = state.appearance.isTransparent
        picker.color = state.appearance.nsColor
        picker.title = state.appearance.isTransparent ? "SPIKE · Цвет и прозрачность" : "SPIKE · Цвет"
        picker.setTarget(self)
        picker.setAction(#selector(surfaceColorChanged(_:)))
    }
    @objc func showIdentitySettings() {
        state.settingsPage = .identity
        showSettings()
    }
    func windowWillClose(_ notification: Notification) {
        if colorPickerOpen, let window = notification.object as? NSColorPanel {
            window.setTarget(nil)
            colorPickerOpen = false
            hover(panel.frame.contains(NSEvent.mouseLocation))
        }
    }
    @objc func openSelfieFolder() { state.mirror.openSavedFolder() }
    @objc func toggleVisual() {
        state.audioVisual.toggle()
        rebuildMenu()
    }
    @objc func showVisualSettings() {
        state.settingsPage = .visual
        showSettings()
    }
    @objc func toggleExpanded() {
        let next = !state.expanded
        if !next, colorPickerHoldsSurface { NSColorPanel.shared.close() }
        pendingCollapse?.cancel()
        expand(next)
    }
    @objc func toggleSideTabs() {
        pendingCollapse?.cancel()
        state.usesSideTabs.toggle()
        state.hoveredSideTab = nil
        if let geometry {
            state.expandedContentWidth = geometry.frame(expanded: true, sideTabs: state.usesSideTabs).width
            state.settingsHeight = geometry.deepHeight(sideTabs: state.usesSideTabs)
        }
        if state.settingsOpen && state.settingsHeight == 0 { closeSettings() }
        host.headerGapWidth = state.usesSideTabs ? state.gap : nil
        host.updateTrackingAreas()
        if let geometry, state.expanded {
            resize(to: geometry.frame(expanded: true, sideTabs: state.usesSideTabs, deep: state.settingsOpen))
        }
        rebuildMenu()
    }
    @objc func toggleVirtual() { virtual.toggle(); reconfigure() }
    @objc func toggleSystemMedia() {
        state.ambientMedia.toggleExperimentalMedia()
        rebuildMenu()
    }
    @objc func toggleMusicPriority() {
        state.ambientMedia.toggleMusicPriority()
        rebuildMenu()
    }
    @objc func requestMusicPermissions() { state.ambientMedia.requestMusicPermissions() }
    @objc func selectScreen(_ sender: NSMenuItem) { selectedDisplay = sender.representedObject as? String; reconfigure() }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--self-test") {
    SurfaceAppearance.check()
    checkGeometry()
    checkMediaStates()
    checkMediaSourceSelection()
    MusicPlayerEvents.checkDescriptors()
    checkSystemMediaDecoding()
    checkMusicFavorites()
    checkMirrorCapture()
    checkMirrorRecording()
    checkAudioSignalAnalysis()
    checkVisualReactivity()
    checkVisualAudioLifecycle()
    checkSurfaceTermination()
    checkArtworkPalette()
    checkASCIIFlow()
    checkIdentityImages()
} else if CommandLine.arguments.contains("--appearance-self-test") {
    SurfaceAppearance.check()
    checkASCIIFlowAppearance()
} else if CommandLine.arguments.contains("--geometry-self-test") {
    checkGeometry()
} else if CommandLine.arguments.contains("--media-self-test") {
    checkMediaStates()
    checkMediaSourceSelection()
    MusicPlayerEvents.checkDescriptors()
    checkSystemMediaDecoding()
    checkMusicFavorites()
} else if CommandLine.arguments.contains("--music-player-probe") {
    let reading = MusicPlayerEvents.readPlayers()
    for value in reading.snapshots {
        print("\(value.player.name): \(value.playing ? "playing" : "paused"), current track metadata available")
    }
    if let diagnostic = reading.diagnostic { print(diagnostic) }
    if reading.snapshots.isEmpty { print("No independently readable music source") }
} else if CommandLine.arguments.contains("--favorites-self-test") {
    checkMusicFavorites()
} else if CommandLine.arguments.contains("--mirror-self-test") {
    checkMirrorCapture()
    checkMirrorRecording()
} else if CommandLine.arguments.contains("--audio-lifecycle-self-test") {
    checkVisualAudioLifecycle()
    checkSurfaceTermination()
} else if CommandLine.arguments.contains("--visual-audio-probe") {
    exit(runVisualAudioProbe())
} else if CommandLine.arguments.contains("--audio-signal-probe") {
    exit(runAudioSignalProbe())
} else if CommandLine.arguments.contains("--geometry-probe") {
    for screen in NSScreen.screens {
        let geometry = SurfaceGeometry(screen: screen.frame, visible: screen.visibleFrame,
            inset: screen.safeAreaInsets.top, left: screen.auxiliaryTopLeftArea,
            right: screen.auxiliaryTopRightArea, virtual: false)
        print("screen=\(screen.localizedName) scale=\(screen.backingScaleFactor) inset=\(screen.safeAreaInsets.top) gap=\(geometry.gap) collapsed=\(geometry.frame(expanded: false))")
    }
} else if CommandLine.arguments.contains("--media-probe") {
    let observer = SystemMediaAdapter()
    observer.onSnapshot = { snapshot in
        print("media state=\(snapshot.state) source=\(snapshot.sourceName ?? "none") title=\(snapshot.title) artwork=\(snapshot.artwork != nil)")
        fflush(stdout)
    }
    observer.onFailure = { print("media error: \($0)"); fflush(stdout) }
    observer.start()
    RunLoop.main.run(until: Date().addingTimeInterval(15))
    observer.stop()
} else if CommandLine.arguments.contains("--audio-probe") {
    let observer = AudioActivityAdapter()
    observer.onSnapshot = { snapshot in
        print("audio state=\(snapshot.state) source=\(snapshot.sourceName ?? "none")")
        fflush(stdout)
    }
    observer.start()
    RunLoop.main.run(until: Date().addingTimeInterval(15))
    observer.stop()
} else {
    // Hold an OS lock for the process lifetime, including direct executable launches.
    // Never unlink it: an existing inode must remain shared by concurrent launches.
    let lockPath = NSTemporaryDirectory() + "local.one.surface-spike.lock"
    let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else {
        let alert = NSAlert()
        alert.messageText = "Не удалось запустить ONE"
        alert.informativeText = "Не удалось открыть файл блокировки: " + String(cString: strerror(errno))
        alert.runModal()
        exit(1)
    }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        let error = errno
        close(lockFD)
        if error == EWOULDBLOCK { exit(0) }
        let alert = NSAlert()
        alert.messageText = "Не удалось запустить ONE"
        alert.informativeText = "Не удалось проверить единственный экземпляр: " + String(cString: strerror(error))
        alert.runModal()
        exit(1)
    }
    defer { close(lockFD) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
