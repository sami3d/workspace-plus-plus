import AppKit
import Combine
import KeyboardShortcuts
import SpaceRenamerCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let monitor: SpaceMonitor
    private let names: NameStore
    private let switcher: SwitcherEngine
    private let openPreferences: () -> Void
    private var cancellables: Set<AnyCancellable> = []
    private let menu = NSMenu()
    private var perDisplayLabels: PerDisplayMenuBarLabelManager!

    init(monitor: SpaceMonitor,
         names: NameStore,
         switcher: SwitcherEngine,
         openPreferences: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.monitor = monitor
        self.names = names
        self.switcher = switcher
        self.openPreferences = openPreferences
        super.init()
        setStatusTitle("Desktop")
        if let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "Desktop") {
            icon.isTemplate = true                       // adapts to light/dark menu bar + highlight
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageLeading
            statusItem.button?.imageHugsTitle = true     // keep icon next to the name
        }
        menu.delegate = self
        // NSMenu.autoenablesItems defaults to true, which makes AppKit ignore
        // our manual `item.isEnabled = false` and re-enable any item whose
        // target responds to its action. We manage enabled state ourselves
        // (disabled rows for unreachable / >9 desktops, the hint item).
        menu.autoenablesItems = false
        statusItem.menu = menu
        perDisplayLabels = PerDisplayMenuBarLabelManager(statusItem: statusItem, menu: menu)

        Publishers.CombineLatest3(
            monitor.$spaces,
            monitor.$activeIDsByDisplay,
            monitor.$lastLoadError
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.refreshTitle() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .spaceRenamerMenuBarDisplayModeDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .spaceRenamerNameDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        refreshTitle()
    }

    /// Programmatically toggle the status-item menu (used by the global open-menu hotkey
    /// in Task B3). `performClick` TOGGLES: if the menu is already open this closes it —
    /// callers must NOT add extra open/closed state tracking around this.
    func openMenu() {
        if perDisplayLabels.isEnabled {
            perDisplayLabels.openMenu()
        } else {
            statusItem.button?.performClick(nil)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        monitor.reload()
        populate()
        // Immediate title refresh; the Combine sink also fires later (async,
        // idempotent) from reload()'s @Published mutations.
        refreshTitle()
    }

    func menuWillOpen(_ menu: NSMenu) {
        perDisplayLabels.setMenuHighlighted(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        perDisplayLabels.setMenuHighlighted(false)
    }

    // MARK: - Private helpers

    private func populate() {
        menu.removeAllItems()

        // Arrow mode reaches any desktop; Ctrl+digit mode only the desktops
        // whose Ctrl+N is enabled & correctly bound (so grey the rest, incl.
        // all >9). See Design Revision 2026-05-18.
        let ctrlDigitMode = names.switchMode == .ctrlDigit
        let reachable: Set<Int> = ctrlDigitMode
            ? SystemShortcutChecker.reachableSwitchToDesktopOrdinals() : []

        for (displayIndex, display) in monitor.displays.enumerated() {
            if displayIndex > 0 {
                menu.addItem(.separator())
            }
            let displayName = DisplayResolver.name(for: display.id, ordinal: display.ordinal)
            let displayItem = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
            displayItem.isEnabled = false
            menu.addItem(displayItem)
            populateSpaces(display.spaces, in: menu,
                           activeID: display.activeID,
                           ctrlDigitMode: ctrlDigitMode,
                           reachable: reachable)
        }

        if !monitor.spaces.isEmpty {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Hold ⌥ and click a desktop to rename",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        if monitor.lastLoadError != nil {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "⚠︎ Spaces unavailable — showing last known", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(prefsClicked), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let quit = NSMenuItem(title: "Quit Workspace++", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func populateSpaces(_ spaces: [ParsedSpace], in targetMenu: NSMenu,
                                activeID: String?, ctrlDigitMode: Bool,
                                reachable: Set<Int>) {
        let menuFont = NSFont.menuFont(ofSize: 0)
        let widestName = spaces
            .map { (names.name(for: $0.storageID, defaultOrdinal: $0.ordinal) as NSString)
                .size(withAttributes: [.font: menuFont]).width }
            .max() ?? 0
        let shortcutTabX = ceil(widestName) + 36

        for space in spaces {
            let title = names.name(for: space.storageID, defaultOrdinal: space.ordinal)
            let item = NSMenuItem(title: title, action: #selector(spaceClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            item.indentationLevel = 1
            if space.id == activeID { item.state = .on }
            if ctrlDigitMode && !reachable.contains(space.ordinal) {
                item.isEnabled = false
                item.toolTip = space.ordinal > 9
                    ? "Ctrl+1\u{2013}9 can\u{2019}t reach desktop \(space.ordinal). Switch to \u{201C}Move a space\u{201D} mode in Preferences."
                    : "Enable \u{201C}Switch to Desktop \(space.ordinal)\u{201D} (Ctrl+\(space.ordinal)) in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Mission Control, or use \u{201C}Move a space\u{201D} mode."
            }
            // Read-only hint of the per-desktop global hotkey (set in
            // Preferences). Enabled rows only — disabled rows keep the plain
            // title so AppKit's dimming isn't fought. Not a keyEquivalent, so
            // the ⌥-Rename alternate pairing and global hotkeys are untouched.
            if item.isEnabled,
               let shortcut = KeyboardShortcuts.getShortcut(for: .space(space.storageID)) {
                item.attributedTitle = shortcutHintTitle(name: title,
                                                         shortcut: shortcut.description,
                                                         font: menuFont,
                                                         tabX: shortcutTabX)
            }
            targetMenu.addItem(item)

            // ⌥-held alternate row → rename (implemented in Task B3).
            let renameAlt = NSMenuItem(title: "Rename \u{201C}\(title)\u{201D}\u{2026}",
                                       action: #selector(renameClicked(_:)),
                                       keyEquivalent: "")
            renameAlt.target = self
            renameAlt.representedObject = space.storageID  // names are stored by storageID
            renameAlt.keyEquivalentModifierMask = .option
            renameAlt.isAlternate = true
            renameAlt.indentationLevel = 1
            targetMenu.addItem(renameAlt)
        }
    }

    /// `name` left-aligned, `shortcut` in a muted aligned column at `tabX`.
    private func shortcutHintTitle(name: String, shortcut: String,
                                   font: NSFont, tabX: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: tabX)]
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(
            string: name,
            attributes: [.font: font,
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
        result.append(NSAttributedString(
            string: "\t\(shortcut)",
            attributes: [.font: font,
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph]))
        return result
    }

    private func refreshTitle() {
        let activeNames = monitor.displays.compactMap { display -> String? in
            guard let activeID = monitor.activeIDsByDisplay[display.id],
                  let active = display.spaces.first(where: { $0.id == activeID }) else {
                return nil
            }
            return names.name(for: active.storageID, defaultOrdinal: active.ordinal)
        }

        if names.menuBarDisplayMode == .perDisplay, monitor.displays.count > 1 {
            perDisplayLabels.setEnabled(true)
            perDisplayLabels.update(
                displays: monitor.displays,
                activeIDsByDisplay: monitor.activeIDsByDisplay,
                names: names
            )
            return
        }

        perDisplayLabels.setEnabled(false)
        statusItem.length = NSStatusItem.variableLength
        if !activeNames.isEmpty {
            setStatusTitle(activeNames.joined(separator: "  ·  "))
        } else if monitor.lastLoadError != nil {
            setStatusTitle("\u{26A0}\u{FE0E} Desktop")
        } else {
            setStatusTitle("Desktop")
        }
    }

    private func setStatusTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = MenuBarTitleStyle.attributed(title, font: button.font)
    }

    @objc private func spaceClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try switcher.switch(to: id)
        } catch {
            NSLog("Workspace++: switch failed for \(id): \(error)")
        }
    }

    @objc private func renameClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let space = monitor.spaces.first(where: { $0.storageID == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Desktop"
        alert.informativeText = "Enter a new name. Leave blank to revert to \u{201C}Desktop \(space.ordinal)\u{201D}."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = names.name(for: id, defaultOrdinal: space.ordinal)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            names.setName(id, field.stringValue)
            populate()   // NameStore changes don't publish; repopulate explicitly.
            refreshTitle()
        }
    }

    @objc private func prefsClicked() { openPreferences() }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}
