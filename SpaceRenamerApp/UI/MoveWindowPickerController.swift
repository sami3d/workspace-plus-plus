import AppKit
import SpaceRenamerCore

@MainActor
final class MoveWindowPickerController: NSWindowController,
                                        NSTableViewDataSource,
                                        NSTableViewDelegate,
                                        NSSearchFieldDelegate {
    private struct Destination {
        let space: ParsedSpace
        let name: String
        let displayName: String
        let isActive: Bool
    }

    private let monitor: SpaceMonitor
    private let names: NameStore
    private let switcher: SwitcherEngine
    private let windowMover: KeyboardWindowMover
    private let focusedWindowResolver: FocusedWindowResolver

    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let windowDescription = NSTextField(labelWithString: "")
    private var destinations: [Destination] = []
    private var filteredDestinations: [Destination] = []
    private var capturedWindow: FocusedWindow?
    private var capturedSourceSpaceID: String?
    private var keyMonitor: Any?

    init(monitor: SpaceMonitor,
         names: NameStore,
         switcher: SwitcherEngine,
         focusedWindowResolver: FocusedWindowResolver = FocusedWindowResolver()) {
        self.monitor = monitor
        self.names = names
        self.switcher = switcher
        self.windowMover = KeyboardWindowMover(switcher: switcher)
        self.focusedWindowResolver = focusedWindowResolver

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Move Window to Workspace"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        setupContent()
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func showPicker() {
        monitor.reload()
        guard let focusedWindow = focusedWindowResolver.focusedWindow() else {
            showError(
                title: "No movable window selected",
                message: "Focus a regular application window and try again. Full-screen and tiled windows cannot be moved."
            )
            return
        }
        capturedWindow = focusedWindow
        capturedSourceSpaceID = sourceSpaceID(for: focusedWindow)
        guard capturedSourceSpaceID != nil else {
            capturedWindow = nil
            showError(
                title: "Couldn’t identify the source workspace",
                message: "Workspace++ could not match this window to an active display."
            )
            return
        }
        windowDescription.stringValue = focusedWindow.title.isEmpty
            ? focusedWindow.applicationName
            : "\(focusedWindow.applicationName) — \(focusedWindow.title)"

        destinations = monitor.spaces.map { space in
            let display = monitor.displays.first { $0.id == space.displayID }
            return Destination(
                space: space,
                name: names.name(for: space.storageID, defaultOrdinal: space.ordinal),
                displayName: DisplayResolver.name(
                    for: space.displayID,
                    ordinal: display?.ordinal ?? 1
                ),
                isActive: monitor.activeIDsByDisplay[space.displayID] == space.id
            )
        }
        searchField.stringValue = ""
        applyFilter()

        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(searchField)
        installKeyMonitor()
    }

    override func close() {
        removeKeyMonitor()
        capturedWindow = nil
        capturedSourceSpaceID = nil
        super.close()
    }

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "Move focused window")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        windowDescription.textColor = .secondaryLabelColor
        windowDescription.lineBreakMode = .byTruncatingMiddle
        searchField.placeholderString = "Search workspaces"
        searchField.delegate = self

        let nameColumn = NSTableColumn(identifier: .init("workspace"))
        nameColumn.title = "Workspace"
        nameColumn.width = 300
        let displayColumn = NSTableColumn(identifier: .init("display"))
        displayColumn.title = "Monitor"
        displayColumn.width = 170
        table.addTableColumn(nameColumn)
        table.addTableColumn(displayColumn)
        table.headerView = nil
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(moveOnly)
        table.target = self

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let hint = NSTextField(
            labelWithString: "↩ Move only    ⌥↩ Move and follow    ↑↓ Choose    Esc Cancel"
        )
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [
            heading,
            windowDescription,
            searchField,
            scrollView,
            hint
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 245)
        ])
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            switch event.keyCode {
            case 53:
                self.close()
                return nil
            case 125:
                self.moveSelection(by: 1)
                return nil
            case 126:
                self.moveSelection(by: -1)
                return nil
            case 36, 76:
                self.performSelectedMove(follow: event.modifierFlags.contains(.option))
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        filteredDestinations = query.isEmpty ? destinations : destinations.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
        }
        table.reloadData()
        if !filteredDestinations.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredDestinations.isEmpty else { return }
        let current = max(0, table.selectedRow)
        let next = min(max(0, current + delta), filteredDestinations.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func performSelectedMove(follow: Bool) {
        guard let capturedWindow, let capturedSourceSpaceID,
              filteredDestinations.indices.contains(table.selectedRow) else {
            return
        }
        let destination = filteredDestinations[table.selectedRow]
        do {
            close()
            try windowMover.move(
                window: capturedWindow,
                from: capturedSourceSpaceID,
                to: destination.space.id,
                follow: follow
            )
        } catch {
            showError(title: "Couldn’t move the window", message: error.localizedDescription)
        }
    }

    private func sourceSpaceID(for window: FocusedWindow) -> String? {
        let activeIDs = Set(monitor.activeIDsByDisplay.values)
        if let exactActiveID = window.spaceIDs.first(where: activeIDs.contains) {
            return exactActiveID
        }

        let knownIDs = Set(monitor.displays.flatMap(\.navigationIDs))
        if let exactWindowID = window.spaceIDs.first(where: knownIDs.contains) {
            return exactWindowID
        }

        if let displayID = window.managedDisplayID,
           let exact = monitor.activeIDsByDisplay.first(where: {
               $0.key.caseInsensitiveCompare(displayID) == .orderedSame
           })?.value {
            return exact
        }
        return monitor.displays.first(where: { display in
            guard let screen = DisplayResolver.screen(for: display.id) else { return false }
            let displayBounds = CGDisplayBounds(
                (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber)?.uint32Value ?? 0
            )
            return displayBounds.contains(window.dragPoint)
        })?.activeID ?? monitor.displays.first?.activeID
    }

    @objc private func moveOnly() {
        performSelectedMove(follow: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredDestinations.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let destination = filteredDestinations[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "workspace":
            text = destination.isActive ? "\(destination.name)  • Current" : destination.name
        case "display":
            text = destination.displayName
        default:
            return nil
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "display" {
            label.textColor = .secondaryLabelColor
        }
        return label
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
