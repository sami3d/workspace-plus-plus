import AppKit
import Combine
import SpaceRenamerCore

@MainActor
final class WorkspaceLibraryWindowController: NSWindowController {
    init(
        cloud: CloudSyncManager,
        restorer: WorkspaceSessionRestorer,
        monitor: SpaceMonitor,
        names: NameStore
    ) {
        let content = WorkspaceLibraryViewController(
            cloud: cloud,
            restorer: restorer,
            monitor: monitor,
            names: names
        )
        let window = NSWindow(contentViewController: content)
        window.title = "Workspace Library"
        window.setContentSize(NSSize(width: 980, height: 700))
        window.minSize = NSSize(width: 760, height: 520)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
private final class WorkspaceLibraryViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private enum Filter: String, CaseIterable {
        case all = "All Workspaces"
        case loaded = "Running"
        case parked = "Parked"
        case pending = "Pending Moves"
        case devices = "By Mac"

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .loaded: return "play.circle"
            case .parked: return "archivebox"
            case .pending: return "arrow.left.arrow.right"
            case .devices: return "laptopcomputer.and.iphone"
            }
        }
    }

    private final class Node: NSObject {
        enum Kind {
            case device(CloudWorkspaceDevice)
            case workspace(CloudLibraryWorkspace)
            case instance(CloudWorkspaceInstance)
            case revision(CloudWorkspaceRevision)
            case application(WorkspaceCapturedApplication)
            case window(WorkspaceCapturedWindow)
            case tab(WorkspaceBrowserTab)
        }
        let kind: Kind
        let title: String
        let subtitle: String
        let symbol: String
        weak var parent: Node?
        var children: [Node]

        init(kind: Kind, title: String, subtitle: String, symbol: String, children: [Node] = []) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.symbol = symbol
            self.children = children
            super.init()
            children.forEach { $0.parent = self }
        }
    }

    private let cloud: CloudSyncManager
    private let restorer: WorkspaceSessionRestorer
    private let monitor: SpaceMonitor
    private let names: NameStore
    private let sidebar = NSTableView()
    private let outline = NSOutlineView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let launchButton = NSButton(title: "Launch", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    private let parkButton = NSButton(title: "Park", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy to Mac…", target: nil, action: nil)
    private let moveButton = NSButton(title: "Move to Mac…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var roots: [Node] = []
    private var selectedFilter = Filter.all
    private var cancellables: Set<AnyCancellable> = []

    init(
        cloud: CloudSyncManager,
        restorer: WorkspaceSessionRestorer,
        monitor: SpaceMonitor,
        names: NameStore
    ) {
        self.cloud = cloud
        self.restorer = restorer
        self.monitor = monitor
        self.names = names
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        let sidebarColumn = NSTableColumn(identifier: .init("filter"))
        sidebar.addTableColumn(sidebarColumn)
        sidebar.headerView = nil
        sidebar.rowHeight = 30
        sidebar.dataSource = self
        sidebar.delegate = self
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let column = NSTableColumn(identifier: .init("workspace"))
        column.title = "Cloud workspaces"
        column.width = 720
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 42
        outline.indentationPerLevel = 18
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.target = self
        outline.doubleAction = #selector(openResource)
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true

        split.addArrangedSubview(sidebarScroll)
        split.addArrangedSubview(outlineScroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        for button in [launchButton, duplicateButton, parkButton, copyButton, moveButton, deleteButton] {
            button.target = self
            button.isEnabled = false
        }
        launchButton.action = #selector(launchSelected)
        duplicateButton.action = #selector(duplicateSelected)
        parkButton.action = #selector(parkSelected)
        copyButton.action = #selector(copySelected)
        moveButton.action = #selector(moveSelected)
        deleteButton.action = #selector(deleteSelected)
        let save = NSButton(title: "Save All Now", target: self, action: #selector(saveAll))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let chrome = NSButton(title: "Enable Chrome Integration…", target: self,
                              action: #selector(enableChrome))
        let buttons = NSStackView(views: [launchButton, duplicateButton, parkButton, copyButton, moveButton, deleteButton,
                                         NSView(), chrome, save, refresh])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fill
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2

        let stack = NSStackView(views: [split, buttons, status])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        sidebar.reloadData()
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        cloud.$workspaceLibrary
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        cloud.$libraryStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.status.stringValue = $0 }
            .store(in: &cancellables)
        Task { await cloud.refreshWorkspaceLibrary() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Filter.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let filter = Filter.allCases[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: filter.symbol,
                                              accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: filter.rawValue)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard sidebar.selectedRow >= 0 else { return }
        selectedFilter = Filter.allCases[sidebar.selectedRow]
        rebuild()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView(image: icon(for: node))
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: node.title)
        title.font = .systemFont(ofSize: 13, weight: nodeWeight(node))
        title.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: node.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        icon.translatesAutoresizingMaskIntoConstraints = false
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let hasWorkspace = selectedWorkspace() != nil
        launchButton.isEnabled = hasWorkspace
        duplicateButton.isEnabled = hasWorkspace
        moveButton.isEnabled = hasWorkspace
        copyButton.isEnabled = hasWorkspace
        deleteButton.isEnabled = hasWorkspace
        parkButton.isEnabled = selectedInstance() != nil || hasWorkspace
    }

    private func rebuild() {
        let library = cloud.workspaceLibrary
        var workspaces = library.workspaces.filter { $0.deletedAt == nil }
        switch selectedFilter {
        case .all, .devices: break
        case .loaded:
            workspaces = workspaces.filter { workspace in
                library.instances(for: workspace.id).contains { $0.status == .loaded || $0.status == .focused }
            }
        case .parked:
            workspaces = workspaces.filter { workspace in
                let instances = library.instances(for: workspace.id)
                return workspace.isArchived || (!instances.isEmpty && instances.allSatisfy { $0.status == .parked })
            }
        case .pending:
            let pendingIDs = Set(library.transfers.filter { $0.status == .pending }.map(\.workspaceID))
            workspaces = workspaces.filter { pendingIDs.contains($0.id) }
        }
        let sorted = workspaces.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if selectedFilter == .devices {
            roots = library.devices.map { device in
                let deviceWorkspaceIDs = Set(library.instances.filter {
                    $0.deviceID == device.deviceID && $0.deletedAt == nil
                }.map(\.workspaceID))
                let children = sorted.filter { deviceWorkspaceIDs.contains($0.id) }.map {
                    workspaceNode($0, library: library, deviceID: device.deviceID)
                }
                return Node(
                    kind: .device(device),
                    title: device.name,
                    subtitle: "\(children.count) workspace\(children.count == 1 ? "" : "s") · last seen \(formatted(device.lastSeenAt))",
                    symbol: "laptopcomputer",
                    children: children
                )
            }.filter { !$0.children.isEmpty }
        } else {
            roots = sorted.map { workspaceNode($0, library: library) }
        }
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }
    }

    private func workspaceNode(
        _ workspace: CloudLibraryWorkspace,
        library: WorkspaceLibrary,
        deviceID: UUID? = nil
    ) -> Node {
        let matchingInstances = library.instances(for: workspace.id).filter {
            deviceID == nil || $0.deviceID == deviceID
        }
        let instances = matchingInstances.map { instance -> Node in
            let device = library.devices.first { $0.deviceID == instance.deviceID }
            let head = instance.headRevisionID.flatMap { id in library.revisions.first { $0.id == id } }
            let children = head.map { [revisionNode($0)] } ?? []
            return Node(
                kind: .instance(instance),
                title: device?.name ?? "Mac",
                subtitle: "\(instance.status.rawValue.replacingOccurrences(of: "_", with: " ")) · \(instance.displayName ?? "No local Space") · updated \(formatted(instance.updatedAt))",
                symbol: instance.status == .parked ? "archivebox" : "laptopcomputer",
                children: children
            )
        }
        let latest = library.latestRevision(for: workspace)
        let pending = library.transfers.filter { $0.workspaceID == workspace.id && $0.status == .pending }.count
        let detail = latest.map {
            "\($0.snapshot.applications.count) apps · \($0.snapshot.totalWindowCount) windows · \($0.snapshot.totalTabCount) tabs"
        } ?? "No revision"
        return Node(
            kind: .workspace(workspace),
            title: workspace.name,
            subtitle: "\(detail) · \(instances.count) instance\(instances.count == 1 ? "" : "s")\(pending > 0 ? " · \(pending) pending" : "")",
            symbol: workspace.isArchived ? "archivebox.fill" : "rectangle.3.group",
            children: instances
        )
    }

    private func revisionNode(_ revision: CloudWorkspaceRevision) -> Node {
        let apps = revision.snapshot.applications.map { application in
            let windows = application.windows.map { window in
                let tabs = window.tabs.sorted { $0.index < $1.index }.map { tab in
                    let group = tab.groupTitle.map { " · \($0)" } ?? ""
                    return Node(kind: .tab(tab), title: tab.title.isEmpty ? tab.url : tab.title,
                                subtitle: "\(tab.url)\(group)", symbol: tab.isPinned == true ? "pin" : "globe")
                }
                return Node(kind: .window(window), title: window.title.isEmpty ? "Untitled window" : window.title,
                            subtitle: "\(window.tabs.count) tabs · \(window.confidence.rawValue)",
                            symbol: "macwindow", children: tabs)
            }
            return Node(kind: .application(application), title: application.name,
                        subtitle: "\(application.windows.count) window\(application.windows.count == 1 ? "" : "s")",
                        symbol: "app", children: windows)
        }
        return Node(kind: .revision(revision), title: "Saved \(formatted(revision.createdAt))",
                    subtitle: "\(revision.snapshot.totalWindowCount) windows · \(revision.snapshot.totalTabCount) tabs",
                    symbol: "clock.arrow.circlepath", children: apps)
    }

    private func selectedWorkspace() -> CloudLibraryWorkspace? {
        guard outline.selectedRow >= 0, var node = outline.item(atRow: outline.selectedRow) as? Node else { return nil }
        while true {
            if case .workspace(let workspace) = node.kind { return workspace }
            guard let parent = node.parent else { return nil }
            node = parent
        }
    }

    private func selectedInstance() -> CloudWorkspaceInstance? {
        guard outline.selectedRow >= 0, var node = outline.item(atRow: outline.selectedRow) as? Node else { return nil }
        while true {
            if case .instance(let instance) = node.kind { return instance }
            guard let parent = node.parent else { return nil }
            node = parent
        }
    }

    private func chooseLocalSpace(
        title: String,
        workspaceID: UUID,
        duplicate: Bool
    ) -> String? {
        monitor.reload()
        let popup = NSPopUpButton()
        var occupied: [String: UUID] = [:]
        for instance in cloud.workspaceLibrary.instances where
            instance.deviceID == cloud.currentDeviceID
                && instance.deletedAt == nil
                && instance.status != .parked {
            if let key = instance.localWorkspaceKey, occupied[key] == nil {
                occupied[key] = instance.workspaceID
            }
        }
        let available = monitor.spaces.filter { space in
            guard let owner = occupied[space.storageID] else { return true }
            return !duplicate && owner == workspaceID
        }
        for space in available {
            popup.addItem(withTitle: names.name(for: space.storageID, defaultOrdinal: space.ordinal))
            popup.lastItem?.representedObject = space.storageID
        }
        guard !available.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No unassigned macOS Space is available"
            alert.informativeText = "Create another Space, or park a local workspace instance first. Workspace++ will not overwrite a different binding silently."
            alert.runModal()
            return nil
        }
        popup.frame = NSRect(x: 0, y: 0, width: 340, height: 28)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Choose the macOS Space that should host this local instance. Existing windows in that Space are left untouched."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.selectedItem?.representedObject as? String
    }

    private func performLaunch(duplicate: Bool) {
        guard let workspace = selectedWorkspace(),
              let revision = cloud.workspaceLibrary.latestRevision(for: workspace),
              let target = chooseLocalSpace(
                title: duplicate ? "Duplicate “\(workspace.name)”" : "Launch “\(workspace.name)”",
                workspaceID: workspace.id,
                duplicate: duplicate
              )
        else { return }
        Task {
            await cloud.bindWorkspace(workspace, to: target, asDuplicate: duplicate)
            do {
                try await restorer.restore(snapshot: revision.snapshot, targetStorageID: target)
                await cloud.completePendingTransfer(for: workspace, localWorkspaceKey: target)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func launchSelected() { performLaunch(duplicate: false) }
    @objc private func duplicateSelected() { performLaunch(duplicate: true) }

    @objc private func parkSelected() {
        guard let workspace = selectedWorkspace() else { return }
        let instance = selectedInstance() ?? cloud.workspaceLibrary.instances(for: workspace.id)
            .first { $0.deviceID == cloud.currentDeviceID && $0.status != .parked }
        guard let instance else { return }
        let alert = NSAlert()
        alert.messageText = "Park “\(workspace.name)” in the cloud?"
        alert.informativeText = "Workspace++ will save a fresh cloud revision first, then close only the app windows confirmed to belong to this Space. Apps remain running, and unsaved documents may show their normal save prompt."
        alert.addButton(withTitle: "Park")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await cloud.parkInstance(instance) }
    }

    private func transferSelected(mode: CloudWorkspaceTransferMode) {
        guard let workspace = selectedWorkspace(),
              let revision = cloud.workspaceLibrary.latestRevision(for: workspace) else { return }
        let candidates = cloud.workspaceLibrary.devices.filter { $0.deviceID != cloud.currentDeviceID }
        let popup = NSPopUpButton()
        popup.addItem(withTitle: "Any signed-in Mac")
        for device in candidates {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.representedObject = device.deviceID
        }
        popup.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        let alert = NSAlert()
        alert.messageText = "\(mode == .move ? "Move" : "Copy") “\(workspace.name)” to another Mac?"
        alert.informativeText = mode == .move
            ? "The destination must explicitly accept and launch revision saved \(formatted(revision.createdAt)). The source remains intact until verification."
            : "The destination must explicitly launch revision saved \(formatted(revision.createdAt)). Both instances remain available."
        alert.accessoryView = popup
        alert.addButton(withTitle: mode == .move ? "Request Move" : "Request Copy")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await cloud.requestTransfer(
                workspace: workspace,
                destinationDeviceID: popup.selectedItem?.representedObject as? UUID,
                mode: mode
            )
        }
    }

    @objc private func moveSelected() { transferSelected(mode: .move) }
    @objc private func copySelected() { transferSelected(mode: .copy) }

    @objc private func deleteSelected() {
        guard let workspace = selectedWorkspace() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(workspace.name)” from the cloud Library?"
        alert.informativeText = "This soft-deletes the cloud workspace and hides its revision history. It does not close or delete local app windows."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await cloud.deleteLibraryWorkspace(workspace) }
    }

    @objc private func saveAll() { Task { await cloud.captureWorkspaceHistoryNow() } }
    @objc private func refresh() { Task { await cloud.refreshWorkspaceLibrary() } }

    @objc private func enableChrome() {
        do {
            let path = try ChromeExtensionBridge().installBundledComponents()
            let alert = NSAlert()
            alert.messageText = "Chrome companion is bundled and ready"
            alert.informativeText = "For this development build, open chrome://extensions, enable Developer mode, choose Load unpacked, and select the folder below. The path is already copied. Public releases will use one Chrome Web Store approval instead.\n\n\(path.path)"
            alert.addButton(withTitle: "Open Chrome Extensions")
            alert.addButton(withTitle: "Later")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path.path, forType: .string)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "chrome://extensions") {
                NSWorkspace.shared.open(url)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openResource() {
        guard outline.clickedRow >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? Node,
              case .tab(let tab) = node.kind,
              let url = URL(string: tab.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func icon(for node: Node) -> NSImage {
        if case .application(let app) = node.kind,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil) ?? NSImage()
    }

    private func nodeWeight(_ node: Node) -> NSFont.Weight {
        if case .device = node.kind { return .semibold }
        if case .workspace = node.kind { return .semibold }
        if case .instance = node.kind { return .medium }
        return .regular
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
