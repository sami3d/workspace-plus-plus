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
    private let opacitySlider = NSSlider(
        value: 0.70,
        minValue: 0.10,
        maxValue: 1.0,
        target: nil,
        action: nil
    )
    private let opacityValueLabel = NSTextField(labelWithString: "70%")
    private let overlayChanged: (Bool) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: SpaceMonitor, names: NameStore,
         overlayChanged: @escaping (Bool) -> Void) {
        self.monitor = monitor
        self.names = names
        self.overlayChanged = overlayChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 660),
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

        let appWindowsToggle = NSButton(
            checkboxWithTitle: "Show app windows behind workspace name",
            target: self,
            action: #selector(toggleOverlayAppWindows(_:))
        )
        appWindowsToggle.state = names.overlayShowsAppWindows ? .on : .off

        let opacityLabel = NSTextField(labelWithString: "Name background opacity:")
        opacitySlider.doubleValue = names.overlayBackgroundOpacity
        opacitySlider.target = self
        opacitySlider.action = #selector(changeOverlayOpacity(_:))
        opacitySlider.isContinuous = false
        opacitySlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        updateOpacityValueLabel()
        let opacityRow = NSStackView(views: [
            opacityLabel,
            opacitySlider,
            opacityValueLabel
        ])
        opacityRow.orientation = .horizontal
        opacityRow.alignment = .centerY
        opacityRow.spacing = 8

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

        let colorLegend = makeColorLegend()
        let stack = NSStackView(views: [openMenuRow, moveWindowRow, scroll,
                                        colorLegend,
                                        menuBarModeRow, shortcutToggle,
                                        overlayToggle, appWindowsToggle,
                                        opacityRow, launchToggle])
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

    private func makeColorLegend() -> NSView {
        let title = NSTextField(
            labelWithString: "Colour legend"
        )
        title.font = NSFont.systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        )

        let categories = [
            ("0433FF", "Work"),
            ("FF40FF", "Hobby"),
            ("00A800", "Empty screens"),
            ("3A3A40", "Mixed"),
            ("FB4A00", "Unsorted windows"),
            ("AA7942", "Personal tasks"),
        ]
        let items = categories.map { makeLegendItem(hex: $0.0, title: $0.1) }
        let grid = NSGridView(views: [
            Array(items[0...2]),
            Array(items[3...5]),
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.xPlacement = .leading
        grid.yPlacement = .center

        let legend = NSStackView(views: [title, grid])
        legend.orientation = .vertical
        legend.alignment = .leading
        legend.spacing = 6
        return legend
    }

    private func makeLegendItem(hex: String, title: String) -> NSView {
        let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = WorkspaceColor.color(from: hex).cgColor
        swatch.layer?.cornerRadius = 3
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 14),
            swatch.heightAnchor.constraint(equalToConstant: 14),
        ])

        let label = NSTextField(labelWithString: title)
        let item = NSStackView(views: [swatch, label])
        item.orientation = .horizontal
        item.alignment = .centerY
        item.spacing = 6
        item.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return item
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

    @objc private func toggleOverlayAppWindows(_ sender: NSButton) {
        names.overlayShowsAppWindows = (sender.state == .on)
    }

    @objc private func changeOverlayOpacity(_ sender: NSSlider) {
        names.overlayBackgroundOpacity = sender.doubleValue
        updateOpacityValueLabel()
    }

    private func updateOpacityValueLabel() {
        opacityValueLabel.stringValue =
            "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
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
