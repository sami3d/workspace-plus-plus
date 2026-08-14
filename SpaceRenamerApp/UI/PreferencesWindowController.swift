import AppKit
import Combine
import KeyboardShortcuts
import SpaceRenamerCore

private final class WorkspaceCategoryPopup: NSPopUpButton {
    var storageID = ""
}

private final class CategoryColorWell: NSColorWell {
    var categoryID = ""
}

private final class CategoryDeleteButton: NSButton {
    var categoryID = ""
}

private final class CategoryRenameButton: NSButton {
    var categoryID = ""
}

@MainActor
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate {
    private let monitor: SpaceMonitor
    private let names: NameStore
    private let cloud: CloudSyncManager
    private let table = NSTableView()
    private let categoryTable = NSTableView()
    private let openMenuRecorder = KeyboardShortcuts.RecorderCocoa(for: .openMenu)
    private let moveWindowRecorder = KeyboardShortcuts.RecorderCocoa(for: .moveFocusedWindow)
    private let appIconDisplayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appIconWindowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appSortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(
        value: 0.70,
        minValue: 0.10,
        maxValue: 1.0,
        target: nil,
        action: nil
    )
    private let opacityValueLabel = NSTextField(labelWithString: "70%")
    private let cloudStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let cloudEmailField = NSTextField()
    private let cloudPasswordField = NSSecureTextField()
    private let cloudSignInButton = NSButton(title: "Sign In", target: nil, action: nil)
    private let cloudCreateButton = NSButton(title: "Create Account", target: nil, action: nil)
    private let cloudSyncButton = NSButton(title: "Sync Now", target: nil, action: nil)
    private let cloudRestoreButton = NSButton(title: "Restore from Cloud", target: nil, action: nil)
    private let cloudSignOutButton = NSButton(title: "Sign Out", target: nil, action: nil)
    private let overlayChanged: (Bool) -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(monitor: SpaceMonitor, names: NameStore, cloud: CloudSyncManager,
         overlayChanged: @escaping (Bool) -> Void) {
        self.monitor = monitor
        self.names = names
        self.cloud = cloud
        self.overlayChanged = overlayChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 790),
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
        NotificationCenter.default.publisher(for: .spaceRenamerCategoriesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.table.reloadData()
                self?.categoryTable.reloadData()
            }
            .store(in: &cancellables)
        cloud.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateCloudControls(for: state) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        configureWorkspaceTable()
        configureCategoryTable()

        let tabs = NSTabView()
        let workspaces = NSTabViewItem(identifier: "workspaces")
        workspaces.label = "Workspaces"
        workspaces.view = makeWorkspacesTab()
        let categories = NSTabViewItem(identifier: "categories")
        categories.label = "Categories"
        categories.view = makeCategoriesTab()
        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = makeGeneralTab()
        let cloudTab = NSTabViewItem(identifier: "cloud")
        cloudTab.label = "Cloud Sync"
        cloudTab.view = padded(makeCloudSection())
        tabs.addTabViewItem(workspaces)
        tabs.addTabViewItem(categories)
        tabs.addTabViewItem(general)
        tabs.addTabViewItem(cloudTab)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            tabs.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    private func configureWorkspaceTable() {
        let displayCol = NSTableColumn(identifier: .init("display"))
        displayCol.title = "Monitor"; displayCol.width = 130
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Desktop"; nameCol.width = 160
        let categoryCol = NSTableColumn(identifier: .init("category"))
        categoryCol.title = "Category"; categoryCol.width = 150
        let hotkeyCol = NSTableColumn(identifier: .init("hotkey"))
        hotkeyCol.title = "Hotkey"; hotkeyCol.width = 145
        [displayCol, nameCol, categoryCol, hotkeyCol].forEach {
            table.addTableColumn($0)
        }
        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = 30
    }

    private func configureCategoryTable() {
        let name = NSTableColumn(identifier: .init("categoryName"))
        name.title = "Category name"; name.width = 270
        let color = NSTableColumn(identifier: .init("categoryColor"))
        color.title = "Colour"; color.width = 120
        let rename = NSTableColumn(identifier: .init("categoryRename"))
        rename.title = ""; rename.width = 85
        let delete = NSTableColumn(identifier: .init("categoryDelete"))
        delete.title = ""; delete.width = 85
        [name, color, rename, delete].forEach {
            categoryTable.addTableColumn($0)
        }
        categoryTable.dataSource = self
        categoryTable.delegate = self
        categoryTable.headerView = NSTableHeaderView()
        categoryTable.rowHeight = 34
        categoryTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }

    private func makeWorkspacesTab() -> NSView {
        let explanation = NSTextField(wrappingLabelWithString:
            "Assign a category to each workspace. Its colour is used for the Mission Control label and menu bar name.")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return tabPage(
            [explanation, scroll],
            fullWidth: [explanation, scroll],
            fillsHeight: true
        )
    }

    private func makeCategoriesTab() -> NSView {
        let explanation = NSTextField(wrappingLabelWithString:
            "Categories keep workspace meaning and colour together. Rename or recolour one here and every assigned workspace updates automatically.")
        let scroll = NSScrollView()
        scroll.documentView = categoryTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let add = NSButton(title: "Add Category", target: self, action: #selector(addCategory))
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        return tabPage(
            [explanation, scroll, add],
            fullWidth: [explanation, scroll],
            fillsHeight: true
        )
    }

    private func makeGeneralTab() -> NSView {

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

        let appDisplayLabel = NSTextField(labelWithString: "App icon alignment:")
        let appDisplayOptions: [(String, AppIconDisplayMode)] = [
            ("Left aligned", .leftAligned),
            ("Right aligned", .rightAligned),
        ]
        for (title, mode) in appDisplayOptions {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            appIconDisplayPopup.menu?.addItem(item)
        }
        appIconDisplayPopup.selectItem(withTitle: appDisplayOptions.first {
            $0.1 == names.appIconDisplayMode
        }?.0 ?? appDisplayOptions[0].0)
        appIconDisplayPopup.target = self
        appIconDisplayPopup.action = #selector(changeAppIconDisplayMode(_:))
        let appDisplayRow = NSStackView(views: [appDisplayLabel, appIconDisplayPopup])
        appDisplayRow.orientation = .horizontal
        appDisplayRow.alignment = .centerY
        appDisplayRow.spacing = 8

        let appWindowLabel = NSTextField(labelWithString: "Window display:")
        let appWindowOptions: [(String, AppIconWindowMode)] = [
            ("Only app icons (without window count)", .iconsOnly),
            ("App icon with window counter", .windowCounters),
            ("One app icon for each window", .repeatedIcons),
        ]
        for (title, mode) in appWindowOptions {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            appIconWindowPopup.menu?.addItem(item)
        }
        appIconWindowPopup.selectItem(withTitle: appWindowOptions.first {
            $0.1 == names.appIconWindowMode
        }?.0 ?? appWindowOptions[0].0)
        appIconWindowPopup.target = self
        appIconWindowPopup.action = #selector(changeAppIconWindowMode(_:))
        let appWindowRow = NSStackView(views: [appWindowLabel, appIconWindowPopup])
        appWindowRow.orientation = .horizontal
        appWindowRow.alignment = .centerY
        appWindowRow.spacing = 8

        let appSortLabel = NSTextField(labelWithString: "App icon sorting:")
        let appSortOptions: [(String, AppIconSortMode)] = [
            ("Most windows across all workspaces", .globalWindowCount),
            ("Most windows in this workspace", .workspaceWindowCount),
            ("Application name A–Z", .alphabetical),
        ]
        for (title, mode) in appSortOptions {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            appSortPopup.menu?.addItem(item)
        }
        appSortPopup.selectItem(withTitle: appSortOptions.first {
            $0.1 == names.appIconSortMode
        }?.0 ?? appSortOptions[0].0)
        appSortPopup.target = self
        appSortPopup.action = #selector(changeAppIconSortMode(_:))
        let appSortRow = NSStackView(views: [appSortLabel, appSortPopup])
        appSortRow.orientation = .horizontal
        appSortRow.alignment = .centerY
        appSortRow.spacing = 8

        return tabPage([openMenuRow, moveWindowRow, menuBarModeRow,
                        appDisplayRow, appWindowRow, appSortRow, shortcutToggle,
                        overlayToggle, appWindowsToggle,
                        opacityRow, launchToggle])
    }

    private func tabPage(
        _ views: [NSView],
        fullWidth: [NSView] = [],
        fillsHeight: Bool = false
    ) -> NSView {
        let container = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ]
        constraints.append(
            fillsHeight
                ? stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
                : stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8)
        )
        constraints.append(contentsOf: fullWidth.map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        })
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func padded(_ view: NSView) -> NSView {
        tabPage([view], fullWidth: [view])
    }

    private func makeCloudSection() -> NSView {
        let box = NSBox()
        box.title = "Cloud Sync"
        box.boxType = .primary
        box.translatesAutoresizingMaskIntoConstraints = false

        cloudStatusLabel.maximumNumberOfLines = 2
        cloudStatusLabel.lineBreakMode = .byWordWrapping
        cloudEmailField.placeholderString = "Email"
        cloudPasswordField.placeholderString = "Password (8+ characters)"
        cloudEmailField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        cloudPasswordField.widthAnchor.constraint(equalToConstant: 250).isActive = true

        cloudSignInButton.target = self
        cloudSignInButton.action = #selector(signInToCloud)
        cloudCreateButton.target = self
        cloudCreateButton.action = #selector(createCloudAccount)
        cloudSyncButton.target = self
        cloudSyncButton.action = #selector(syncCloudNow)
        cloudRestoreButton.target = self
        cloudRestoreButton.action = #selector(restoreFromCloud)
        cloudSignOutButton.target = self
        cloudSignOutButton.action = #selector(signOutOfCloud)

        let credentials = NSStackView(views: [cloudEmailField, cloudPasswordField])
        credentials.orientation = .horizontal
        credentials.spacing = 8
        let authButtons = NSStackView(views: [cloudSignInButton, cloudCreateButton])
        authButtons.orientation = .horizontal
        authButtons.spacing = 8
        let syncButtons = NSStackView(views: [
            cloudSyncButton,
            cloudRestoreButton,
            cloudSignOutButton,
        ])
        syncButtons.orientation = .horizontal
        syncButtons.spacing = 8

        let stack = NSStackView(views: [
            cloudStatusLabel,
            credentials,
            authButtons,
            syncButtons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        box.widthAnchor.constraint(equalToConstant: 600).isActive = true
        updateCloudControls(for: cloud.state)
        return box
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

    @objc private func changeAppIconSortMode(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = AppIconSortMode(rawValue: rawValue) else { return }
        names.appIconSortMode = mode
    }

    @objc private func changeAppIconDisplayMode(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = AppIconDisplayMode(rawValue: rawValue) else { return }
        names.appIconDisplayMode = mode
    }

    @objc private func changeAppIconWindowMode(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = AppIconWindowMode(rawValue: rawValue) else { return }
        names.appIconWindowMode = mode
    }

    @objc private func changeWorkspaceCategory(_ sender: WorkspaceCategoryPopup) {
        guard !sender.storageID.isEmpty else { return }
        names.setCategory(sender.selectedItem?.identifier?.rawValue, for: sender.storageID)
        table.reloadData()
    }

    @objc private func addCategory() {
        guard let newName = requestCategoryName(
            title: "Add Category",
            prompt: "Enter a name for the new category.",
            initialValue: ""
        ) else { return }
        names.addCategory(name: newName, colorHex: WorkspaceColor.defaultHex)
        categoryTable.reloadData()
        table.reloadData()
    }

    @objc private func renameCategory(_ sender: CategoryRenameButton) {
        guard let category = names.categories.first(where: { $0.id == sender.categoryID }),
              let newName = requestCategoryName(
                title: "Rename Category",
                prompt: "Enter the complete new name.",
                initialValue: category.name
              ) else { return }
        names.updateCategory(id: category.id, name: newName)
        categoryTable.reloadData()
        table.reloadData()
    }

    private func requestCategoryName(
        title: String,
        prompt: String,
        initialValue: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        field.stringValue = initialValue
        field.placeholderString = "Category name"
        field.isEditable = true
        field.isSelectable = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value
    }

    @objc private func recolorCategory(_ sender: CategoryColorWell) {
        names.updateCategory(
            id: sender.categoryID,
            colorHex: WorkspaceColor.hex(from: sender.color)
        )
        table.reloadData()
    }

    @objc private func deleteCategory(_ sender: CategoryDeleteButton) {
        guard let category = names.categories.first(where: { $0.id == sender.categoryID }) else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete “\(category.name)”?"
        alert.informativeText = "Workspaces using this category will become uncategorised. Their names and hotkeys will not be changed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        names.deleteCategory(id: category.id)
        categoryTable.reloadData()
        table.reloadData()
    }

    @objc private func signInToCloud() {
        let credentials = cloudCredentials()
        guard credentials.valid else { return }
        Task {
            await cloud.signIn(email: credentials.email, password: credentials.password)
            cloudPasswordField.stringValue = ""
        }
    }

    @objc private func createCloudAccount() {
        let credentials = cloudCredentials()
        guard credentials.valid else { return }
        Task {
            await cloud.createAccount(
                email: credentials.email,
                password: credentials.password
            )
            cloudPasswordField.stringValue = ""
        }
    }

    @objc private func syncCloudNow() {
        Task { await cloud.syncNow() }
    }

    @objc private func restoreFromCloud() {
        let alert = NSAlert()
        alert.messageText = "Restore workspace names from cloud?"
        alert.informativeText = "Cloud names and colours will replace matching local workspaces. Matching uses the workspace identity first, then monitor and workspace order."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await cloud.restoreFromCloud() }
    }

    @objc private func signOutOfCloud() {
        Task { await cloud.signOut() }
    }

    private func cloudCredentials() -> (email: String, password: String, valid: Bool) {
        let email = cloudEmailField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = cloudPasswordField.stringValue
        let valid = email.contains("@") && password.count >= 8
        if !valid {
            cloudStatusLabel.stringValue = "Enter a valid email and a password of at least 8 characters."
            cloudStatusLabel.textColor = .systemRed
        }
        return (email, password, valid)
    }

    private func updateCloudControls(for state: CloudSyncState) {
        let signedIn = state.email != nil
        let busy: Bool
        switch state {
        case .syncing: busy = true
        default: busy = false
        }
        cloudEmailField.isHidden = signedIn
        cloudPasswordField.isHidden = signedIn
        cloudSignInButton.isHidden = signedIn
        cloudCreateButton.isHidden = signedIn
        cloudSyncButton.isHidden = !signedIn
        cloudRestoreButton.isHidden = !signedIn
        cloudSignOutButton.isHidden = !signedIn
        cloudSyncButton.isEnabled = !busy
        cloudRestoreButton.isEnabled = !busy
        cloudSignOutButton.isEnabled = !busy
        cloudSignInButton.isEnabled = cloud.isConfigured && !busy
        cloudCreateButton.isEnabled = cloud.isConfigured && !busy

        cloudStatusLabel.textColor = .secondaryLabelColor
        switch state {
        case .unavailable(let message):
            cloudStatusLabel.stringValue = message
        case .signedOut(let message):
            cloudStatusLabel.stringValue = message
                ?? "Sign in to save names, colours, monitor placement and workspace order."
        case .syncing(let email):
            cloudStatusLabel.stringValue = "Syncing \(email)…"
        case .signedIn(let email, let lastSync):
            if let lastSync {
                cloudStatusLabel.stringValue = "Signed in as \(email) · Synced \(lastSync.formatted(date: .abbreviated, time: .shortened))"
            } else {
                cloudStatusLabel.stringValue = "Signed in as \(email)"
            }
        case .failed(let email, let message):
            cloudStatusLabel.textColor = .systemRed
            cloudStatusLabel.stringValue = email.map { "\($0): \(message)" } ?? message
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === categoryTable ? names.categories.count : monitor.spaces.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === categoryTable {
            let category = names.categories[row]
            switch tableColumn?.identifier.rawValue {
            case "categoryName":
                return NSTextField(labelWithString: category.name)
            case "categoryColor":
                let well = CategoryColorWell(frame: NSRect(x: 0, y: 0, width: 72, height: 24))
                well.categoryID = category.id
                well.color = WorkspaceColor.color(from: category.colorHex)
                if #available(macOS 14.0, *) { well.supportsAlpha = false }
                well.target = self
                well.action = #selector(recolorCategory(_:))
                return well
            case "categoryRename":
                let button = CategoryRenameButton(
                    title: "Rename",
                    target: self,
                    action: #selector(renameCategory(_:))
                )
                button.categoryID = category.id
                button.bezelStyle = .rounded
                return button
            case "categoryDelete":
                let button = CategoryDeleteButton(title: "Delete", target: self, action: #selector(deleteCategory(_:)))
                button.categoryID = category.id
                button.bezelStyle = .rounded
                return button
            default:
                return nil
            }
        }
        let space = monitor.spaces[row]
        switch tableColumn?.identifier.rawValue {
        case "display":
            let ordinal = monitor.displays.first(where: { $0.id == space.displayID })?.ordinal ?? 1
            return NSTextField(labelWithString:
                DisplayResolver.name(for: space.displayID, ordinal: ordinal))
        case "name":
            return NSTextField(labelWithString: names.name(for: space.storageID, defaultOrdinal: space.ordinal))
        case "category":
            let popup = WorkspaceCategoryPopup(frame: .zero, pullsDown: false)
            popup.storageID = space.storageID
            let none = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
            popup.menu?.addItem(none)
            popup.menu?.addItem(.separator())
            for category in names.categories {
                let item = NSMenuItem(title: category.name, action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(category.id)
                let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                    WorkspaceColor.color(from: category.colorHex).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                    return true
                }
                item.image = swatch
                popup.menu?.addItem(item)
            }
            if let selected = names.categoryID(for: space.storageID),
               let item = popup.menu?.items.first(where: { $0.identifier?.rawValue == selected }) {
                popup.select(item)
            } else {
                popup.selectItem(at: 0)
            }
            popup.target = self
            popup.action = #selector(changeWorkspaceCategory(_:))
            return popup
        case "hotkey":
            return KeyboardShortcuts.RecorderCocoa(for: .space(space.storageID))
        default:
            return nil
        }
    }

}
