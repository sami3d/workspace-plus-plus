import AppKit
import Combine
import KeyboardShortcuts
import SpaceRenamerCore

@MainActor
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let monitor: SpaceMonitor
    private let names: NameStore
    private let table = NSTableView()
    private let openMenuRecorder = KeyboardShortcuts.RecorderCocoa(for: .openMenu)
    private let overlayChanged: (Bool) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: SpaceMonitor, names: NameStore,
         overlayChanged: @escaping (Bool) -> Void) {
        self.monitor = monitor
        self.names = names
        self.overlayChanged = overlayChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Space Renamer Preferences"
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
        let launchToggle = NSButton(checkboxWithTitle: "Launch at Login",
                                    target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchToggle.state = LaunchAtLogin.isEnabled ? .on : .off

        let shortcutToggle = NSButton(checkboxWithTitle: "Use shortcut mode (9 desktops max)",
                                      target: self, action: #selector(toggleShortcutMode(_:)))
        shortcutToggle.state = (names.switchMode == .ctrlDigit) ? .on : .off

        let overlayToggle = NSButton(checkboxWithTitle: "Show name in Mission Control",
                                     target: self, action: #selector(toggleOverlay(_:)))
        overlayToggle.state = names.showMissionControlOverlay ? .on : .off

        let displayCol = NSTableColumn(identifier: .init("display"))
        displayCol.title = "Monitor"; displayCol.width = 120
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Desktop"; nameCol.width = 140
        let hotkeyCol = NSTableColumn(identifier: .init("hotkey"))
        hotkeyCol.title = "Hotkey"; hotkeyCol.width = 170
        table.addTableColumn(displayCol)
        table.addTableColumn(nameCol)
        table.addTableColumn(hotkeyCol)
        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = 30

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let stack = NSStackView(views: [openMenuLabel, openMenuRecorder, scroll,
                                        shortcutToggle, overlayToggle, launchToggle])
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
            scroll.widthAnchor.constraint(equalToConstant: 440)
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
        case "hotkey":
            return KeyboardShortcuts.RecorderCocoa(for: .space(space.storageID))
        default:
            return nil
        }
    }
}
