import AppKit
import Combine
import KeyboardShortcuts
import SpaceRenamerCore

private final class WorkspaceColorWell: NSColorWell {
    var storageID = ""
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let monitor: SpaceMonitor
    private let names: NameStore
    private let table = NSTableView()
    private let openMenuRecorder = KeyboardShortcuts.RecorderCocoa(for: .openMenu)
    private let moveWindowRecorder = KeyboardShortcuts.RecorderCocoa(for: .moveFocusedWindow)
    private let overlayChanged: (Bool) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: SpaceMonitor, names: NameStore,
         overlayChanged: @escaping (Bool) -> Void) {
        self.monitor = monitor
        self.names = names
        self.overlayChanged = overlayChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Workspace++ Preferences"
        super.init(window: window)
        setupContent()
        // Created at origin (0,0) — Cocoa's bottom-left. Center it on first
        // show; NSWindowController then remembers a user-moved position.
        window.center()
        monitor.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.table.reloadData() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        let openMenuLabel = NSTextField(labelWithString: "Open-menu hotkey:")
        let openMenuRow = NSStackView(views: [openMenuLabel, openMenuRecorder])
        openMenuRow.orientation = .horizontal
        openMenuRow.alignment = .centerY
        openMenuRow.spacing = 8
        let moveWindowLabel = NSTextField(labelWithString: "Move-window picker:")
        let moveWindowRow = NSStackView(views: [moveWindowLabel, moveWindowRecorder])
        moveWindowRow.orientation = .horizontal
        moveWindowRow.alignment = .centerY
        moveWindowRow.spacing = 8
        let launchToggle = NSButton(checkboxWithTitle: "Launch at Login",
                                    target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchToggle.state = LaunchAtLogin.isEnabled ? .on : .off

        let shortcutToggle = NSButton(checkboxWithTitle: "Use shortcut mode (9 desktops max)",
                                      target: self, action: #selector(toggleShortcutMode(_:)))
        shortcutToggle.state = (names.switchMode == .ctrlDigit) ? .on : .off

        let overlayToggle = NSButton(checkboxWithTitle: "Show name in Mission Control",
                                     target: self, action: #selector(toggleOverlay(_:)))
        overlayToggle.state = names.showMissionControlOverlay ? .on : .off

        let menuBarModeLabel = NSTextField(labelWithString: "Menu bar names:")
        let menuBarModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        menuBarModePopup.addItems(withTitles: [
            "Each display separately",
            "Combined on every display"
        ])
        menuBarModePopup.selectItem(at: names.menuBarDisplayMode == .perDisplay ? 0 : 1)
        menuBarModePopup.target = self
        menuBarModePopup.action = #selector(changeMenuBarDisplayMode(_:))
        let menuBarModeRow = NSStackView(views: [menuBarModeLabel, menuBarModePopup])
        menuBarModeRow.orientation = .horizontal
        menuBarModeRow.alignment = .centerY
        menuBarModeRow.spacing = 8

        let displayCol = NSTableColumn(identifier: .init("display"))
        displayCol.title = "Monitor"; displayCol.width = 130
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Desktop"; nameCol.width = 170
        let colorCol = NSTableColumn(identifier: .init("color"))
        colorCol.title = "Colour"; colorCol.width = 90
        let hotkeyCol = NSTableColumn(identifier: .init("hotkey"))
        hotkeyCol.title = "Hotkey"; hotkeyCol.width = 180
        table.addTableColumn(displayCol)
        table.addTableColumn(nameCol)
        table.addTableColumn(colorCol)
        table.addTableColumn(hotkeyCol)
        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = 30

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let stack = NSStackView(views: [openMenuRow, moveWindowRow, scroll,
                                        menuBarModeRow, shortcutToggle,
                                        overlayToggle, launchToggle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            scroll.widthAnchor.constraint(equalToConstant: 600)
        ])
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        LaunchAtLogin.isEnabled = (sender.state == .on)
    }

    @objc private func toggleShortcutMode(_ sender: NSButton) {
        // Checked = Ctrl+1–9 "shortcut mode" (max 9 desktops); unchecked =
        // default arrow mode (any desktop). The status menu rebuilds on open
        // (NSMenuDelegate), so the Ctrl+digit greying reflects this next show.
        names.switchMode = (sender.state == .on) ? .ctrlDigit : .arrow
    }

    @objc private func toggleOverlay(_ sender: NSButton) {
        let on = (sender.state == .on)
        names.showMissionControlOverlay = on
        overlayChanged(on)   // AppDelegate calls overlay.setEnabled(on)
    }

    @objc private func changeMenuBarDisplayMode(_ sender: NSPopUpButton) {
        names.menuBarDisplayMode = sender.indexOfSelectedItem == 0 ? .perDisplay : .combined
    }

    @objc private func changeWorkspaceColor(_ sender: WorkspaceColorWell) {
        guard !sender.storageID.isEmpty else { return }
        names.setColorHex(sender.storageID, WorkspaceColor.hex(from: sender.color))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { monitor.spaces.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let space = monitor.spaces[row]
        switch tableColumn?.identifier.rawValue {
        case "display":
            let ordinal = monitor.displays.first(where: { $0.id == space.displayID })?.ordinal ?? 1
            return NSTextField(labelWithString:
                DisplayResolver.name(for: space.displayID, ordinal: ordinal))
        case "name":
            return NSTextField(labelWithString: names.name(for: space.storageID, defaultOrdinal: space.ordinal))
        case "color":
            let well = WorkspaceColorWell(
                frame: NSRect(x: 0, y: 0, width: 56, height: 24)
            )
            well.storageID = space.storageID
            well.color = WorkspaceColor.color(
                from: names.colorHex(for: space.storageID)
            )
            if #available(macOS 14.0, *) {
                well.supportsAlpha = false
            }
            well.target = self
            well.action = #selector(changeWorkspaceColor(_:))
            well.toolTip = "Choose the background colour for this workspace name"
            return well
        case "hotkey":
            return KeyboardShortcuts.RecorderCocoa(for: .space(space.storageID))
        default:
            return nil
        }
    }
}
