import AppKit
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
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
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
            entries.values.forEach { $0.panel.orderOut(nil) }
            stopObservingAnchorWindow()
            statusItem.button?.alphaValue = 1
            statusItem.button?.isEnabled = true
            statusItem.button?.image = nativeImage
            statusItem.button?.imagePosition = .imageLeading
            statusItem.button?.imageHugsTitle = true
            statusItem.menu = menu
        }
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
        let anchorFrame = NSRect(
            x: anchorWindow.frame.minX + anchorButton.frame.minX,
            y: anchorWindow.frame.minY + anchorButton.frame.minY,
            width: anchorButton.frame.width,
            height: anchorButton.frame.height
        )
        let referenceScreen = anchorWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) })
            ?? NSScreen.main
        guard let referenceScreen else { return }
        // End at the scene window's trailing edge so the panel sits flush in
        // the reserved slot. Labels narrower than the widest one right-align
        // within it, so they never paint outside the reserved stretch.
        let trailingOffset = referenceScreen.frame.maxX - anchorWindow.frame.maxX
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
            let anchorRight = screen.frame.maxX - trailingOffset
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
        panel.level = .statusBar
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
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: control.bounds.midX, y: control.bounds.minY),
            in: control
        )
    }
}
