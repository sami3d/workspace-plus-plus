import AppKit
import Combine
import KeyboardShortcuts
import SpaceRenamerCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem
    private let monitor: SpaceMonitor
    private let names: NameStore
    private let switcher: SwitcherEngine
    private let openMoveWindowPicker: () -> Void
    private let createWorkspace: () -> Void
    private let openPreferences: () -> Void
    private let applicationIndex = SpaceApplicationIndex()
    private var cancellables: Set<AnyCancellable> = []
    private var commandKeyMonitor: Any?
    private let menu = NSMenu()
    private var perDisplayLabels: PerDisplayMenuBarLabelManager!
    private var forceCustomMenuBarLabel = false

    init(monitor: SpaceMonitor,
         names: NameStore,
         switcher: SwitcherEngine,
         openMoveWindowPicker: @escaping () -> Void,
         createWorkspace: @escaping () -> Void,
         openPreferences: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.monitor = monitor
        self.names = names
        self.switcher = switcher
        self.openMoveWindowPicker = openMoveWindowPicker
        self.createWorkspace = createWorkspace
        self.openPreferences = openPreferences
        super.init()
        menu.delegate = self
        // NSMenu.autoenablesItems defaults to true, which makes AppKit ignore
        // our manual `item.isEnabled = false` and re-enable any item whose
        // target responds to its action. We manage enabled state ourselves
        // (disabled rows for unreachable / >9 desktops, the hint item).
        menu.autoenablesItems = false
        configureNativeStatusItem()
        perDisplayLabels = PerDisplayMenuBarLabelManager(statusItem: statusItem, menu: menu)
        installCommandKeyMonitor()

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
        NotificationCenter.default.publisher(for: .spaceRenamerColorDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &cancellables)
        refreshTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.repairStatusItemIfOffscreen()
        }
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

    /// A private virtual display temporarily changes the menu-bar scene
    /// topology. Recreate our anchor/panels from the final physical-display
    /// snapshot so the Workspace++ control cannot remain invisible.
    func recoverAfterDisplayTransition() {
        monitor.reload()
        recreateStatusItem()
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

    private func configureNativeStatusItem() {
        // A named status item gets a stable, valid menu-bar placement. Anonymous
        // items can inherit a stale off-screen scene after a virtual display is
        // removed, even across process and SystemUIServer restarts.
        statusItem.autosaveName = "WorkspacePlusPlus.main.v2"
        statusItem.isVisible = true
        statusItem.button?.isHidden = false
        statusItem.button?.window?.alphaValue = 1
        setStatusTitle("Desktop")
        if let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "Desktop") {
            icon.isTemplate = true
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageLeading
            statusItem.button?.imageHugsTitle = true
        }
        statusItem.length = NSStatusItem.variableLength
        statusItem.menu = menu
    }

    /// A temporary display can leave AppKit's status-item scene attached to
    /// coordinates that no longer belong to a menu bar. Reusing that button
    /// preserves the bad scene, so remove it from NSStatusBar and create a
    /// genuinely new native item against the settled display topology.
    private func recreateStatusItem() {
        perDisplayLabels?.resetAfterDisplayTransition()
        NSStatusBar.system.removeStatusItem(statusItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureNativeStatusItem()
        perDisplayLabels = PerDisplayMenuBarLabelManager(statusItem: statusItem, menu: menu)
        refreshTitle()
    }

    private func repairStatusItemIfOffscreen() {
        guard let window = statusItem.button?.window else {
            forceCustomMenuBarLabel = true
            refreshTitle()
            return
        }
        let sceneCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let hasDrawableScene = window.frame.width > 1 && window.frame.height > 1
            && NSScreen.screens.contains(where: {
                $0.frame.contains(sceneCenter)
                    && sceneCenter.y > $0.frame.minY + 1
            })
        guard !hasDrawableScene else {
            return
        }
        NSLog("Workspace++: using custom renderer for off-screen status item at %@",
              NSStringFromRect(window.frame))
        forceCustomMenuBarLabel = true
        refreshTitle()
    }

    private func populate() {
        menu.removeAllItems()
        let rightAlignedApps = names.appIconDisplayMode == .rightAligned
        let applicationsBySpace = applicationIndex.summariesBySpace(
            // Count-based orders flow toward the alignment edge: most-used
            // first in the left layout, and most-used last at the far right.
            sortMode: names.appIconSortMode,
            leastUsedFirst: rightAlignedApps
        )

        // Arrow mode reaches any desktop; Ctrl+digit mode only the desktops
        // whose Ctrl+N is enabled & correctly bound (so grey the rest, incl.
        // all >9). See Design Revision 2026-05-18.
        let ctrlDigitMode = names.switchMode == .ctrlDigit
        let reachable: Set<Int> = ctrlDigitMode
            ? SystemShortcutChecker.reachableSwitchToDesktopOrdinals() : []

        for (displayIndex, display) in displaysInMenuOrder().enumerated() {
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
                           reachable: reachable,
                           applicationsBySpace: applicationsBySpace)
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
        let createWorkspace = NSMenuItem(
            title: "Create Workspace (Experimental)…",
            action: #selector(createWorkspaceClicked),
            keyEquivalent: ""
        )
        createWorkspace.target = self
        menu.addItem(createWorkspace)
        let moveWindow = NSMenuItem(
            title: "Move Focused Window…",
            action: #selector(moveWindowClicked),
            keyEquivalent: ""
        )
        moveWindow.target = self
        menu.addItem(moveWindow)
        // Keep these key equivalents out of this status menu. AppKit otherwise
        // reserves a wide shortcut column across every workspace row. The
        // shortcuts themselves are preserved by installCommandKeyMonitor().
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(prefsClicked), keyEquivalent: "")
        prefs.target = self
        menu.addItem(prefs)
        let quit = NSMenuItem(title: "Quit Workspace++", action: #selector(quitClicked), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func installCommandKeyMonitor() {
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case ",":
                self?.openPreferences()
                return nil
            case "q":
                NSApp.terminate(nil)
                return nil
            default:
                return event
            }
        }
    }

    /// The display the menu was opened from leads, so the desktops you can see
    /// are the ones at the top; the rest keep their snapshot order below it.
    private func displaysInMenuOrder() -> [ParsedDisplay] {
        var displays = monitor.displays
        guard displays.count > 1, let index = originDisplayIndex(in: displays) else {
            return displays
        }
        displays.insert(displays.remove(at: index), at: 0)
        return displays
    }

    private func originDisplayIndex(in displays: [ParsedDisplay]) -> Int? {
        if perDisplayLabels.isEnabled,
           let originID = perDisplayLabels.menuOriginDisplayID,
           let index = displays.firstIndex(where: { $0.id == originID }) {
            return index
        }
        // The shared status item is mirrored onto every menu bar, so which one
        // was clicked is only recoverable from where the pointer is.
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) else { return nil }
        return displays.firstIndex {
            DisplayResolver.matches(screen, managedDisplayID: $0.id)
        }
    }

    private func populateSpaces(_ spaces: [ParsedSpace], in targetMenu: NSMenu,
                                activeID: String?, ctrlDigitMode: Bool,
                                reachable: Set<Int>,
                                applicationsBySpace: [String: [SpaceApplicationSummary]]) {
        let menuFont = NSFont.menuFont(ofSize: 0)

        for space in spaces {
            let title = names.name(for: space.storageID, defaultOrdinal: space.ordinal)
            let item = NSMenuItem(title: title, action: #selector(spaceClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            item.indentationLevel = 1
            item.image = workspaceSwatch(
                hex: names.colorHex(for: space.storageID)
            )
            if let category = names.category(for: space.storageID) {
                item.toolTip = "Category: \(category.name)"
            }
            if space.id == activeID { item.state = .on }
            if ctrlDigitMode && !reachable.contains(space.ordinal) {
                item.isEnabled = false
                item.toolTip = space.ordinal > 9
                    ? "Ctrl+1\u{2013}9 can\u{2019}t reach desktop \(space.ordinal). Switch to \u{201C}Move a space\u{201D} mode in Preferences."
                    : "Enable \u{201C}Switch to Desktop \(space.ordinal)\u{201D} (Ctrl+\(space.ordinal)) in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Mission Control, or use \u{201C}Move a space\u{201D} mode."
            }
            let applications = applicationsBySpace[space.id] ?? []
            let shortcut = item.isEnabled
                ? KeyboardShortcuts.getShortcut(for: .space(space.storageID))?.description
                : nil
            if !applications.isEmpty || shortcut != nil {
                item.attributedTitle = workspaceMenuTitle(
                    name: title,
                    applications: applications,
                    shortcut: shortcut,
                    font: menuFont,
                    displayMode: names.appIconDisplayMode,
                    windowMode: names.appIconWindowMode
                )
                let appDescription = applications.map {
                    $0.windowCount > 1 ? "\($0.name) (\($0.windowCount))" : $0.name
                }.joined(separator: ", ")
                if !appDescription.isEmpty {
                    let totalWindows = applications.reduce(0) { $0 + $1.windowCount }
                    let categoryDescription = names.category(for: space.storageID)
                        .map { "Category: \($0.name)\n" } ?? ""
                    item.toolTip = categoryDescription
                        + "\(totalWindows) window\(totalWindows == 1 ? "" : "s") total\n"
                        + appDescription
                }
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

    /// Compact category cue shown immediately before every workspace name.
    /// A subtle outline keeps dark/neutral categories visible in dark menus.
    private func workspaceSwatch(hex: String?) -> NSImage {
        let size = NSSize(width: 11, height: 11)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 2.5, yRadius: 2.5)
            WorkspaceColor.color(from: hex).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A bounded native-menu title: independently truncated workspace name,
    /// followed by compact app icons/counts and an optional shortcut. This
    /// preserves standard menu highlighting, keyboard navigation and actions.
    private func workspaceMenuTitle(
        name: String,
        applications: [SpaceApplicationSummary],
        shortcut: String?,
        font: NSFont,
        displayMode: AppIconDisplayMode,
        windowMode: AppIconWindowMode
    ) -> NSAttributedString {
        switch displayMode {
        case .leftAligned:
            return leftAlignedWorkspaceMenuTitle(
                name: name,
                applications: applications,
                shortcut: shortcut,
                font: font,
                windowMode: windowMode
            )
        case .rightAligned:
            return rightAlignedWorkspaceMenuTitle(
                name: name,
                applications: applications,
                shortcut: shortcut,
                font: font,
                windowMode: windowMode
            )
        }
    }

    private func leftAlignedWorkspaceMenuTitle(
        name: String,
        applications: [SpaceApplicationSummary],
        shortcut: String?,
        font: NSFont,
        windowMode: AppIconWindowMode
    ) -> NSAttributedString {
        let applicationTabX: CGFloat = 285
        // Keep the total inside the native menu's usable content width. A tab
        // beyond this point is clipped by AppKit, which looks like unexplained
        // empty trailing space and hides the total entirely.
        let totalTabX: CGFloat = 400
        let iconSize: CGFloat = 13
        let numberFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: applicationTabX),
            NSTextTab(textAlignment: .right, location: totalTabX),
        ]
        paragraph.lineBreakMode = .byClipping
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .baselineOffset: 1,
        ]

        let shortcutWidth: CGFloat = shortcut.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width + 14
        } ?? 0
        let totalWindowCount = applications.reduce(0) { $0 + $1.windowCount }
        // Preserve the existing detailed total only in counter mode. The two
        // icon-only modes contain no numeric window labels by design.
        let totalText = windowMode == .windowCounters && totalWindowCount > 0
            ? "\(totalWindowCount)" : nil
        let totalWidth: CGFloat = totalText.map {
            ($0 as NSString).size(withAttributes: [.font: numberFont]).width + 16
        } ?? 0
        let availableApplicationWidth = max(
            70,
            totalTabX - applicationTabX - shortcutWidth - totalWidth
        )

        let tokens = appIconTokens(applications, windowMode: windowMode)
        var selected: [AppIconToken] = []
        var applicationWidth: CGFloat = 0
        for token in tokens {
            let countWidth = token.windowCount.map {
                ("\u{2009}\($0)" as NSString)
                    .size(withAttributes: secondaryAttributes).width + 1
            } ?? 0
            let tokenWidth = iconSize + countWidth + 6
            guard selected.count < 10,
                  applicationWidth + tokenWidth <= availableApplicationWidth else { break }
            selected.append(token)
            applicationWidth += tokenWidth
        }
        var hiddenCount = tokens.count - selected.count
        let showsOverflowCount = windowMode == .windowCounters
        var hiddenWidth: CGFloat = showsOverflowCount && hiddenCount > 0
            ? ("+\(hiddenCount)" as NSString)
                .size(withAttributes: secondaryAttributes).width + 7
            : 0
        while !selected.isEmpty,
              applicationWidth + hiddenWidth > availableApplicationWidth {
            let removed = selected.removeLast()
            let removedCountWidth = removed.windowCount.map {
                ("\u{2009}\($0)" as NSString)
                    .size(withAttributes: secondaryAttributes).width + 1
            } ?? 0
            applicationWidth -= iconSize + removedCountWidth + 6
            hiddenCount += 1
            hiddenWidth = showsOverflowCount
                ? ("+\(hiddenCount)" as NSString)
                    .size(withAttributes: secondaryAttributes).width + 7
                : 0
        }

        // Leave a 16-point safety gap before the right-side icon column.
        let nameWidth = applicationTabX - 16
        let visibleName = truncated(name, font: font, maximumWidth: nameWidth)
        let result = NSMutableAttributedString(
            string: visibleName,
            attributes: [.font: font,
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])

        if !selected.isEmpty || shortcut != nil {
            result.append(NSAttributedString(
                string: "\t",
                attributes: [.paragraphStyle: paragraph]
            ))
        }
        if !selected.isEmpty {
            for token in selected {
                let attachment = NSTextAttachment()
                let icon = (token.application.icon.copy() as? NSImage)
                    ?? token.application.icon
                icon.size = NSSize(width: iconSize, height: iconSize)
                attachment.image = icon
                attachment.bounds = NSRect(x: 0, y: -2, width: iconSize, height: iconSize)
                result.append(NSAttributedString(attachment: attachment))
                if let windowCount = token.windowCount, windowCount > 1 {
                    result.append(NSAttributedString(
                        string: "\u{2009}\(windowCount)",
                        attributes: secondaryAttributes
                    ))
                } else if token.windowCount != nil {
                    // A clear text colour is not reliable in NSMenu: AppKit
                    // can replace it while highlighting. Reserve the exact
                    // width with an empty transparent attachment instead, so
                    // there is no “1” glyph that can ever become visible.
                    let spacerWidth = ("\u{2009}1" as NSString)
                        .size(withAttributes: secondaryAttributes).width + 1
                    let spacer = NSTextAttachment()
                    spacer.image = NSImage(size: NSSize(width: spacerWidth, height: 1))
                    spacer.bounds = NSRect(x: 0, y: 0, width: spacerWidth, height: 1)
                    result.append(NSAttributedString(attachment: spacer))
                }
                result.append(NSAttributedString(string: " "))
            }
            if showsOverflowCount && hiddenCount > 0 {
                result.append(NSAttributedString(
                    string: "+\(hiddenCount)",
                    attributes: secondaryAttributes
                ))
            }
        }
        if let shortcut {
            result.append(NSAttributedString(
                string: "  \(shortcut)",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        if let totalText {
            result.append(NSAttributedString(
                string: "\t\(totalText)",
                attributes: [
                    .font: numberFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return result
    }

    /// Right-aligned alternative. The final token is anchored against the
    /// menu's right content edge. Input count-based orders are already least
    /// used → most used, so the most-used app remains visually last. When
    /// space is tight, discard left-edge tokens and retain the rightmost ones.
    private func rightAlignedWorkspaceMenuTitle(
        name: String,
        applications: [SpaceApplicationSummary],
        shortcut: String?,
        font: NSFont,
        windowMode: AppIconWindowMode
    ) -> NSAttributedString {
        let iconColumnStartX: CGFloat = 285
        let iconColumnEndX: CGFloat = 400
        let iconSize: CGFloat = 13
        let iconGap: CGFloat = 5
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: iconColumnEndX),
        ]
        paragraph.lineBreakMode = .byClipping

        let shortcutWidth: CGFloat = shortcut.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width + 12
        } ?? 0
        let availableIconWidth = max(
            iconSize,
            iconColumnEndX - iconColumnStartX - shortcutWidth
        )
        let numberFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .baselineOffset: 1,
        ]
        let tokens = appIconTokens(applications, windowMode: windowMode)
        var selected: [AppIconToken] = []
        var selectedWidth: CGFloat = 0
        // Walk from most-used back toward least-used so the most important
        // right-edge icons always survive a constrained row.
        for token in tokens.reversed() {
            let countWidth = token.windowCount.map {
                ("\u{2009}\($0)" as NSString)
                    .size(withAttributes: countAttributes).width + 1
            } ?? 0
            let tokenWidth = iconSize + countWidth + (selected.isEmpty ? 0 : iconGap)
            guard selected.count < 10,
                  selectedWidth + tokenWidth <= availableIconWidth else { break }
            selected.insert(token, at: 0)
            selectedWidth += tokenWidth
        }

        let visibleName = truncated(
            name,
            font: font,
            maximumWidth: iconColumnStartX - 16
        )
        let result = NSMutableAttributedString(
            string: visibleName,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        guard !selected.isEmpty || shortcut != nil else { return result }
        result.append(NSAttributedString(
            string: "\t",
            attributes: [.paragraphStyle: paragraph]
        ))
        if let shortcut {
            result.append(NSAttributedString(
                string: "\(shortcut)  ",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        for (index, token) in selected.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " "))
            }
            let attachment = NSTextAttachment()
            let icon = (token.application.icon.copy() as? NSImage)
                ?? token.application.icon
            icon.size = NSSize(width: iconSize, height: iconSize)
            attachment.image = icon
            attachment.bounds = NSRect(x: 0, y: -2, width: iconSize, height: iconSize)
            result.append(NSAttributedString(attachment: attachment))
            if let windowCount = token.windowCount, windowCount > 1 {
                result.append(NSAttributedString(
                    string: "\u{2009}\(windowCount)",
                    attributes: countAttributes
                ))
            } else if token.windowCount != nil {
                let spacerWidth = ("\u{2009}1" as NSString)
                    .size(withAttributes: countAttributes).width + 1
                let spacer = NSTextAttachment()
                spacer.image = NSImage(size: NSSize(width: spacerWidth, height: 1))
                spacer.bounds = NSRect(x: 0, y: 0, width: spacerWidth, height: 1)
                result.append(NSAttributedString(attachment: spacer))
            }
        }
        return result
    }

    private struct AppIconToken {
        let application: SpaceApplicationSummary
        /// Non-nil only for the counter presentation. A value of one reserves
        /// its count column with an invisible spacer to keep icons aligned.
        let windowCount: Int?
    }

    private func appIconTokens(
        _ applications: [SpaceApplicationSummary],
        windowMode: AppIconWindowMode
    ) -> [AppIconToken] {
        switch windowMode {
        case .iconsOnly:
            return applications.map { AppIconToken(application: $0, windowCount: nil) }
        case .windowCounters:
            return applications.map {
                AppIconToken(application: $0, windowCount: $0.windowCount)
            }
        case .repeatedIcons:
            return applications.flatMap { application in
                Array(repeating: AppIconToken(application: application, windowCount: nil),
                      count: application.windowCount)
            }
        }
    }

    private func truncated(_ value: String, font: NSFont, maximumWidth: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (value as NSString).size(withAttributes: attributes).width > maximumWidth
        else { return value }
        var result = value
        while !result.isEmpty,
              ((result + "…") as NSString).size(withAttributes: attributes).width > maximumWidth {
            result.removeLast()
        }
        return result + "…"
    }

    private func refreshTitle() {
        let activeLabels = monitor.displays.compactMap {
            display -> (title: String, color: NSColor)? in
            guard let activeID = monitor.activeIDsByDisplay[display.id],
                  let active = display.spaces.first(where: { $0.id == activeID }) else {
                return nil
            }
            return (
                names.name(
                    for: active.storageID,
                    defaultOrdinal: active.ordinal
                ),
                MenuBarTitleStyle.workspaceColor(
                    from: names.colorHex(for: active.storageID)
                )
            )
        }

        if names.menuBarDisplayMode == .perDisplay,
           monitor.displays.count > 1 || forceCustomMenuBarLabel {
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
        if !activeLabels.isEmpty {
            setStatusLabels(activeLabels)
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

    /// Combined mode can show active workspaces from multiple displays. Keep
    /// each name in its own saved colour rather than flattening the whole
    /// status title to a single tint.
    private func setStatusLabels(_ labels: [(title: String, color: NSColor)]) {
        guard let button = statusItem.button else { return }
        let result = NSMutableAttributedString()
        for (index, label) in labels.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "  ·  ",
                    attributes: [
                        .font: button.font ?? NSFont.menuBarFont(ofSize: 0),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
            result.append(MenuBarTitleStyle.attributed(
                label.title,
                font: button.font,
                color: label.color
            ))
        }
        button.attributedTitle = result
    }

    @objc private func spaceClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do {
            try switcher.switch(to: id)
            monitor.refreshAfterSpaceChange(targetID: id)
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

    @objc private func moveWindowClicked() { openMoveWindowPicker() }

    @objc private func createWorkspaceClicked() { createWorkspace() }

    @objc private func quitClicked() { NSApp.terminate(nil) }
}
