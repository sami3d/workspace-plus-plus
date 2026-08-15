import AppKit
import Combine

@MainActor
final class WorkspaceHistoryViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate {

    private final class Node: NSObject {
        enum Kind {
            case device
            case workspace(CloudWorkspaceHistoryItem)
            case application(WorkspaceCapturedApplication)
            case window(WorkspaceCapturedWindow)
            case tab(WorkspaceBrowserTab)
            case resource(WorkspaceResourceLocator)
        }

        let kind: Kind
        let title: String
        let subtitle: String
        let symbolName: String
        weak var parent: Node?
        var children: [Node]

        init(kind: Kind, title: String, subtitle: String, symbolName: String,
             children: [Node] = []) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.symbolName = symbolName
            self.children = children
            super.init()
            children.forEach { $0.parent = self }
        }
    }

    private let cloud: CloudSyncManager
    private let restorer: WorkspaceSessionRestorer
    private let outline = NSOutlineView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let enabledCheckbox = NSButton(
        checkboxWithTitle: "Save app, window and Chrome tab history to my Workspace++ account",
        target: nil,
        action: nil
    )
    private let saveButton = NSButton(title: "Save All Now", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var roots: [Node] = []
    private var cancellables: Set<AnyCancellable> = []

    init(cloud: CloudSyncManager, restorer: WorkspaceSessionRestorer) {
        self.cloud = cloud
        self.restorer = restorer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        let explanation = NSTextField(wrappingLabelWithString:
            "Workspace sessions are checked every five minutes and uploaded only when their apps, windows or tabs change. Expand a laptop, workspace, app or window to inspect exactly what was saved.")
        explanation.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: .init("history"))
        column.title = "Saved workspaces"
        column.width = 690
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 42
        outline.indentationPerLevel = 18
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelectedResource)
        outline.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder

        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleHistory)
        enabledCheckbox.state = cloud.workspaceHistoryEnabled ? .on : .off
        saveButton.target = self
        saveButton.action = #selector(saveNow)
        saveButton.isEnabled = cloud.workspaceHistoryEnabled
        let refresh = NSButton(title: "Refresh", target: self,
                               action: #selector(refresh))
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        restoreButton.isEnabled = false
        deleteButton.isEnabled = false
        let buttons = NSStackView(views: [saveButton, refresh, restoreButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        let stack = NSStackView(views: [explanation, enabledCheckbox, buttons, statusLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        view = root

        cloud.$workspaceHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.rebuild(items) }
            .store(in: &cancellables)
        cloud.$historyStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.statusLabel.stringValue = status }
            .store(in: &cancellables)
        cloud.$workspaceHistoryEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.enabledCheckbox.state = enabled ? .on : .off
                self?.saveButton.isEnabled = enabled
            }
            .store(in: &cancellables)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = iconForNode(node)
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: node.title)
        title.font = .systemFont(ofSize: 13, weight: weightForNode(node))
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
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selected = selectedWorkspaceItem() != nil
        restoreButton.isEnabled = selected
        deleteButton.isEnabled = selected
    }

    private func rebuild(_ items: [CloudWorkspaceHistoryItem]) {
        let grouped = Dictionary(grouping: items, by: \.deviceID)
        roots = grouped.map { _, deviceItems in
            let ordered = deviceItems.sorted {
                ($0.snapshot.displayOrdinal, $0.snapshot.spaceOrdinal)
                    < ($1.snapshot.displayOrdinal, $1.snapshot.spaceOrdinal)
            }
            let latest = ordered.map(\.capturedAt).max() ?? .distantPast
            let workspaces = ordered.map(workspaceNode)
            return Node(
                kind: .device,
                title: ordered.first?.deviceName ?? "Mac",
                subtitle: "\(ordered.count) workspaces · Last saved \(formatted(latest))",
                symbolName: "laptopcomputer",
                children: workspaces
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        outline.reloadData()
        // Device rows are the useful top-level overview, so keep them open by
        // default. Deeper rows remain user-controlled.
        roots.forEach { outline.expandItem($0) }
    }

    private func workspaceNode(_ item: CloudWorkspaceHistoryItem) -> Node {
        let applications = item.snapshot.applications.map { application in
            let windows = application.windows.map { window in
                var children = window.tabs.sorted { $0.index < $1.index }.map { tab in
                    Node(
                        kind: .tab(tab),
                        title: tab.title.isEmpty ? tab.url : tab.title,
                        subtitle: tab.url,
                        symbolName: tab.isActive ? "globe.badge.chevron.backward" : "globe"
                    )
                }
                if window.tabs.isEmpty, let resource = window.resource {
                    children.append(Node(
                        kind: .resource(resource),
                        title: resource.value,
                        subtitle: resource.kind.rawValue,
                        symbolName: resource.kind == .fileURL ? "doc" : "link"
                    ))
                }
                return Node(
                    kind: .window(window),
                    title: window.title.isEmpty ? "Untitled window" : window.title,
                    subtitle: "\(window.tabs.count) tabs · \(window.confidence.rawValue)",
                    symbolName: "macwindow",
                    children: children
                )
            }
            return Node(
                kind: .application(application),
                title: application.name,
                subtitle: "\(application.windows.count) window\(application.windows.count == 1 ? "" : "s") · \(application.confidence.rawValue)",
                symbolName: "app",
                children: windows
            )
        }
        return Node(
            kind: .workspace(item),
            title: item.snapshot.workspaceName,
            subtitle: "\(item.snapshot.applications.count) apps · \(item.snapshot.totalWindowCount) windows · \(item.snapshot.totalTabCount) tabs · \(formatted(item.capturedAt))",
            symbolName: "rectangle.3.group",
            children: applications
        )
    }

    private func iconForNode(_ node: Node) -> NSImage? {
        if case .application(let application) = node.kind,
           let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: application.bundleIdentifier
           ) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: node.symbolName, accessibilityDescription: nil)
    }

    private func weightForNode(_ node: Node) -> NSFont.Weight {
        switch node.kind {
        case .device: return .semibold
        case .workspace: return .medium
        default: return .regular
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func selectedWorkspaceItem() -> CloudWorkspaceHistoryItem? {
        guard outline.selectedRow >= 0,
              var node = outline.item(atRow: outline.selectedRow) as? Node else { return nil }
        while true {
            if case .workspace(let item) = node.kind { return item }
            guard let parent = node.parent else { return nil }
            node = parent
        }
    }

    @objc private func saveNow() {
        Task { await cloud.captureWorkspaceHistoryNow() }
    }

    @objc private func toggleHistory() {
        cloud.setWorkspaceHistoryEnabled(enabledCheckbox.state == .on)
    }

    @objc private func refresh() {
        Task { await cloud.refreshWorkspaceHistory() }
    }

    @objc private func deleteSelected() {
        guard let item = selectedWorkspaceItem() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete saved “\(item.snapshot.workspaceName)”?"
        alert.informativeText = "This removes the cloud session saved by \(item.deviceName). It stays hidden on every signed-in laptop until that workspace's apps, windows or tabs change. It does not close anything locally."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await cloud.deleteWorkspaceHistory(id: item.id) }
    }

    @objc private func restoreSelected() {
        guard let item = selectedWorkspaceItem() else { return }
        let alert = NSAlert()
        alert.messageText = "Restore “\(item.snapshot.workspaceName)”?"
        alert.informativeText = "Workspace++ will switch to the matching local workspace and reopen its saved apps, windows and Chrome tabs. Existing windows are left untouched."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await restorer.restore(item)
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        }
    }

    @objc private func openSelectedResource() {
        guard outline.clickedRow >= 0,
              let node = outline.item(atRow: outline.clickedRow) as? Node else { return }
        let rawValue: String?
        switch node.kind {
        case .tab(let tab): rawValue = tab.url
        case .resource(let resource): rawValue = resource.value
        default: rawValue = nil
        }
        guard let rawValue, let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}
