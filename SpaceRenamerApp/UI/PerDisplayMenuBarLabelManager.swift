import AppKit
import ApplicationServices
import SpaceRenamerCore

enum MenuBarTitleStyle {
    static let skyBlue = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: 1.0)
        }
        return NSColor(calibratedRed: 0.0, green: 0.48, blue: 0.84, alpha: 1.0)
    }

    static func attributed(_ title: String, font: NSFont?,
                           color: NSColor = skyBlue) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: color
            ]
        )
    }

    /// Workspaces without an explicitly assigned colour retain Workspace++'s
    /// familiar sky-blue menu-bar treatment.
    static func workspaceColor(from hex: String?) -> NSColor {
        guard let hex else { return skyBlue }
        return WorkspaceColor.color(from: hex)
    }
}

/// AppKit exposes one system-wide NSStatusItem and mirrors its content and
/// width to every menu bar. In per-display mode it becomes a zero-width,
/// non-interactive anchor; a precisely-sized control ends at that anchor on
/// each screen.
/// This lets "Nini Letter" and "Workspace tool" have independent widths.
@MainActor
final class PerDisplayMenuBarLabelManager: NSObject {
    private final class LabelControl: NSControl {
        private let iconView = NSImageView()
        private var styledTitle = NSAttributedString()
        private var titleSize = NSSize.zero
        var isMenuHighlighted = false {
            didSet { needsDisplay = true }
        }

        static let leadingInset: CGFloat = 6
        static let iconSize: CGFloat = 16
        static let iconTitleGap: CGFloat = 6
        static let trailingInset: CGFloat = 6
        private var leadingInset: CGFloat { Self.leadingInset }
        private var iconSize: CGFloat { Self.iconSize }
        private var iconTitleGap: CGFloat { Self.iconTitleGap }
        private var trailingInset: CGFloat { Self.trailingInset }

        static func width(for title: String, font: NSFont?) -> CGFloat {
            let size = MenuBarTitleStyle.attributed(title, font: font).size()
            return ceil(leadingInset + iconSize + iconTitleGap
                        + size.width + trailingInset)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let icon = NSImage(systemSymbolName: "display",
                               accessibilityDescription: "Desktop")
            icon?.isTemplate = true
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyDown
            iconView.contentTintColor = .labelColor
            addSubview(iconView)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        func update(title: String, color: NSColor, font: NSFont?) -> CGFloat {
            styledTitle = MenuBarTitleStyle.attributed(
                title,
                font: font,
                color: color
            )
            titleSize = styledTitle.size()
            needsDisplay = true
            return Self.width(for: title, font: font)
        }

        override func layout() {
            super.layout()
            iconView.frame = NSRect(
                x: leadingInset,
                y: floor((bounds.height - iconSize) / 2),
                width: iconSize,
                height: iconSize
            )
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if isMenuHighlighted {
                NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? NSColor.white.withAlphaComponent(0.16)
                        : NSColor.black.withAlphaComponent(0.12)
                }.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            }
            styledTitle.draw(at: NSPoint(
                x: leadingInset + iconSize + iconTitleGap,
                y: floor((bounds.height - titleSize.height) / 2)
            ))
        }

        override func mouseDown(with event: NSEvent) {
            sendAction(action, to: target)
        }
    }

    private final class Entry {
        let panel: NSPanel
        let control: LabelControl

        init(panel: NSPanel, control: LabelControl) {
            self.panel = panel
            self.control = control
        }
    }

    private struct ActiveLabel {
        let title: String
        let color: NSColor
    }

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let nativeImage: NSImage?
    private var entries: [String: Entry] = [:]
    private var currentLabels: [String: ActiveLabel] = [:]
    private(set) var isEnabled = false
    /// Display whose per-screen label opened the menu that is about to be
    /// populated. Set before `popUp`, which is what drives `menuNeedsUpdate`.
    private(set) var menuOriginDisplayID: String?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) private var anchorObservers: [NSObjectProtocol] = []
    private weak var observedAnchorWindow: NSWindow?

    init(statusItem: NSStatusItem, menu: NSMenu) {
        self.statusItem = statusItem
        self.menu = menu
        self.nativeImage = statusItem.button?.image
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRebuild() }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        anchorObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !isEnabled else { return }
            isEnabled = true
            statusItem.menu = nil
            // The status item must RESERVE the label's real width in the
            // status bar. A zero-width anchor paints over space macOS
            // believes is free, so other apps' newly added status items get
            // slotted underneath our label. rebuildPanels() keeps the length
            // in sync with the widest per-display label.
            statusItem.button?.image = nil
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            statusItem.button?.isEnabled = false
            statusItem.button?.alphaValue = 0
            scheduleRebuild()
        } else {
            // Always restore the native item, even if our bookkeeping already
            // says per-display mode is off. A temporary display transition can
            // invalidate the status-bar scene while leaving `isEnabled` false.
            if isEnabled {
                entries.values.forEach { $0.panel.orderOut(nil) }
                stopObservingAnchorWindow()
            }
            isEnabled = false
            restoreNativeStatusItem()
        }
    }

    private func restoreNativeStatusItem() {
        statusItem.isVisible = true
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.isHidden = false
        statusItem.button?.window?.alphaValue = 1
        statusItem.button?.alphaValue = 1
        statusItem.button?.isEnabled = true
        statusItem.button?.image = nativeImage
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        statusItem.menu = menu
    }

    /// Re-establish the native status item after a temporary display has been
    /// attached and removed. WindowServer can discard the status-item scene
    /// during that transition while `isEnabled` still reflects the old
    /// topology; `setEnabled(false)` would then be skipped by its guard.
    func resetAfterDisplayTransition() {
        entries.values.forEach { $0.panel.close() }
        entries.removeAll()
        currentLabels.removeAll()
        stopObservingAnchorWindow()
        isEnabled = false

        restoreNativeStatusItem()
    }

    func update(displays: [ParsedDisplay],
                activeIDsByDisplay: [String: String],
                names: NameStore) {
        currentLabels = Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            guard let activeID = activeIDsByDisplay[display.id],
                  let space = display.spaces.first(where: { $0.id == activeID }) else {
                return nil
            }
            return (
                display.id,
                ActiveLabel(
                    title: names.name(
                        for: space.storageID,
                        defaultOrdinal: space.ordinal
                    ),
                    color: MenuBarTitleStyle.workspaceColor(
                        from: names.colorHex(for: space.storageID)
                    )
                )
            )
        })

        guard isEnabled else { return }
        scheduleRebuild()
    }

    func setMenuHighlighted(_ highlighted: Bool) {
        entries.values.forEach { $0.control.isMenuHighlighted = highlighted }
    }

    func openMenu() {
        let pointerScreen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        }
        let displayID = pointerScreen.flatMap(DisplayResolver.managedDisplayID(for:))
        let entry = displayID.flatMap { entries[$0] } ?? entries.values.first
        guard let entry else { return }
        showMenu(from: entry.control)
    }

    /// Status-item scene windows are positioned after the current run-loop
    /// transaction. A second delayed pass also handles AppKit resizing the
    /// slot after its attributed title/length changes.
    private func scheduleRebuild() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildPanels()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.rebuildPanels()
        }
    }

    /// Other menu bar apps adding/removing status items shifts every slot,
    /// including our anchor, without any screen-parameter notification.
    /// Follow the anchor's scene window so the panels move with it.
    private func observeAnchorWindow(_ window: NSWindow) {
        guard window !== observedAnchorWindow else { return }
        stopObservingAnchorWindow()
        observedAnchorWindow = window
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            anchorObservers.append(center.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleRebuild() }
            })
        }
    }

    private func stopObservingAnchorWindow() {
        anchorObservers.forEach { NotificationCenter.default.removeObserver($0) }
        anchorObservers = []
        observedAnchorWindow = nil
    }

    private func rebuildPanels() {
        guard isEnabled, let anchorButton = statusItem.button,
              let anchorWindow = anchorButton.window else { return }
        observeAnchorWindow(anchorWindow)

        // Reserve the widest label's width so the status bar keeps this
        // stretch of menu bar to itself. Skip the no-op write: changing the
        // length makes AppKit re-lay-out the scene window, which would fire
        // didResize and loop back here.
        let widestLabel = currentLabels.values
            .map { LabelControl.width(for: $0.title, font: anchorButton.font) }
            .max()
        if let widestLabel, abs(statusItem.length - widestLabel) > 0.5 {
            statusItem.length = widestLabel
            // The scene window resizes after this transaction; the delayed
            // scheduleRebuild pass below repositions the panels against the
            // settled geometry.
        }

        let liveDisplayIDs = Set(currentLabels.keys)
        let staleDisplayIDs = entries.keys.filter { !liveDisplayIDs.contains($0) }
        for displayID in staleDisplayIDs {
            entries[displayID]?.panel.close()
            entries.removeValue(forKey: displayID)
        }

        // NSStatusBarButton is hosted in an AppKit scene window. On current
        // macOS releases, convertToScreen() applies the scene transform twice
        // and reports a position near the Apple menu. The window and button
        // frames are already in compatible coordinates, so compose them.
        let sceneFrame = NSRect(
            x: anchorWindow.frame.minX + anchorButton.frame.minX,
            y: anchorWindow.frame.minY + anchorButton.frame.minY,
            width: anchorButton.frame.width,
            height: anchorButton.frame.height
        )
        // A virtual display transition can leave the AppKit scene window at
        // y=-menuBarHeight even though Accessibility still reports the real,
        // reserved status-bar slot. Prefer that screen-space frame whenever
        // the scene frame no longer intersects a physical display.
        let reportedAccessibilityFrame = statusItemAccessibilityFrame()
            ?? anchorButton.accessibilityFrame()
        let primaryScreen = NSScreen.screens.first
        let accessibilityFrame: NSRect
        if let primaryScreen,
           reportedAccessibilityFrame.maxX < primaryScreen.frame.midX {
            accessibilityFrame = NSRect(
                x: primaryScreen.frame.maxX - anchorButton.frame.width,
                y: primaryScreen.frame.maxY - anchorButton.frame.height,
                width: anchorButton.frame.width,
                height: anchorButton.frame.height
            )
        } else {
            accessibilityFrame = reportedAccessibilityFrame
        }
        let sceneCenter = NSPoint(x: sceneFrame.midX, y: sceneFrame.midY)
        let sceneIsOnScreen = sceneFrame.width > 1 && sceneFrame.height > 1
            && NSScreen.screens.contains { $0.frame.contains(sceneCenter) }
        let anchorFrame = sceneIsOnScreen ? sceneFrame : accessibilityFrame
        let referenceScreen = anchorWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) })
            ?? NSScreen.main
        guard let referenceScreen else { return }
        // End at the scene window's trailing edge so the panel sits flush in
        // the reserved slot. Labels narrower than the widest one right-align
        // within it, so they never paint outside the reserved stretch.
        let trailingOffset = referenceScreen.frame.maxX - anchorFrame.maxX
        let verticalInset = max(
            0,
            floor((anchorWindow.frame.height - anchorButton.frame.height) / 2)
        )

        for (displayID, label) in currentLabels {
            guard let screen = DisplayResolver.screen(for: displayID) else { continue }
            let entry = entries[displayID] ?? makeEntry()
            entries[displayID] = entry

            let controlWidth = entry.control.update(
                title: label.title,
                color: label.color,
                font: anchorButton.font
            )
            let anchorRight = sceneIsOnScreen
                ? screen.frame.maxX - trailingOffset
                : fallbackMenuBarRightEdge(on: screen)
            let labelFrame = NSRect(
                x: anchorRight - controlWidth,
                y: screen.frame.maxY - anchorFrame.height - verticalInset,
                width: controlWidth,
                height: anchorFrame.height
            )
            entry.control.frame = NSRect(origin: .zero, size: labelFrame.size)
            entry.control.toolTip = "\(screen.localizedName): \(label.title)"
            entry.panel.setFrame(labelFrame, display: true)
            entry.panel.orderFrontRegardless()
        }
    }

    /// The first visible right-side menu-bar item is the authoritative edge of
    /// free menu-bar space. WindowServer publishes these status-item windows
    /// even when our own AppKit status scene has stale local coordinates.
    private func fallbackMenuBarRightEdge(on screen: NSScreen) -> CGFloat {
        guard let windows = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID
        ) as? [[String: Any]] else { return screen.frame.maxX }

        let candidates = windows.compactMap { window -> CGFloat? in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue
                    == NSWindow.Level.statusBar.rawValue,
                  (window[kCGWindowOwnerName as String] as? String) == "Control Center",
                  let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.height <= 40,
                  bounds.minX >= screen.frame.minX,
                  bounds.minX < screen.frame.maxX else { return nil }
            return bounds.minX
        }
        return (candidates.min() ?? screen.frame.maxX) - 6
    }

    /// AppKit's status-bar scene can retain local/off-screen coordinates after
    /// a display transition. The app's AX menu-bar item still exposes the real
    /// reserved slot in global (top-left-origin) coordinates, which lets the
    /// replacement panel land exactly where the native item should be.
    private func statusItemAccessibilityFrame() -> NSRect? {
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var rawMenuBar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXMenuBarAttribute as CFString, &rawMenuBar
        ) == .success, let rawMenuBar else { return nil }
        let menuBar = unsafeDowncast(rawMenuBar, to: AXUIElement.self)

        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBar, kAXChildrenAttribute as CFString, &rawChildren
        ) == .success,
              let items = rawChildren as? [AXUIElement] else { return nil }

        for item in items {
            var rawDescription: CFTypeRef?
            AXUIElementCopyAttributeValue(
                item, kAXDescriptionAttribute as CFString, &rawDescription
            )
            guard (rawDescription as? String) == "Desktop",
                  let position = axPoint(kAXPositionAttribute as CFString, of: item),
                  let size = axSize(kAXSizeAttribute as CFString, of: item),
                  let primaryTop = NSScreen.screens.first?.frame.maxY else { continue }
            return NSRect(
                x: position.x,
                y: primaryTop - position.y - size.height,
                width: size.width,
                height: size.height
            )
        }
        return nil
    }

    private func axPoint(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func axSize(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func makeEntry() -> Entry {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Keep this independent of AppKit's status-bar scene. A virtual
        // display can leave that scene with a stale transform that remaps an
        // otherwise-correct global panel frame to x=0/y=-menuBarHeight.
        panel.level = .popUpMenu
        // `.transient` keeps this menu-bar replacement out of Mission Control.
        // The per-Space label windows intentionally omit it because those
        // windows are the names rendered inside the workspace thumbnails.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .transient,
            .ignoresCycle
        ]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let control = LabelControl(frame: .zero)
        control.target = self
        control.action = #selector(labelClicked(_:))
        control.setAccessibilityRole(.button)
        control.setAccessibilityLabel("Open Workspace++ menu")
        panel.contentView = control
        return Entry(panel: panel, control: control)
    }

    @objc private func labelClicked(_ sender: LabelControl) {
        showMenu(from: sender)
    }

    private func showMenu(from control: LabelControl) {
        menuOriginDisplayID = entries.first { $0.value.control === control }?.key
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: control.bounds.midX, y: control.bounds.minY),
            in: control
        )
    }
}
