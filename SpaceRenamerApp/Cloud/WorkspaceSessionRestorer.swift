import AppKit
import Foundation
import SpaceRenamerCore

@MainActor
final class WorkspaceSessionRestorer {
    enum RestoreError: LocalizedError {
        case noTargetWorkspace
        case switchFailed

        var errorDescription: String? {
            switch self {
            case .noTargetWorkspace:
                return "No matching local workspace is available."
            case .switchFailed:
                return "Workspace++ could not switch to the restore destination."
            }
        }
    }

    private let monitor: SpaceMonitor
    private let names: NameStore
    private let switcher: SwitcherEngine
    private let chrome = ChromeSessionAdapter()

    init(monitor: SpaceMonitor, names: NameStore, switcher: SwitcherEngine) {
        self.monitor = monitor
        self.names = names
        self.switcher = switcher
    }

    /// Restores into a name-matched local workspace, then the same monitor +
    /// ordinal slot, and finally the currently active workspace. Switching
    /// first means newly-created windows naturally belong to the destination
    /// without private window-placement APIs.
    func restore(_ item: CloudWorkspaceHistoryItem) async throws {
        try await restore(snapshot: item.snapshot)
    }

    func restore(
        snapshot: WorkspaceSessionSnapshot,
        targetStorageID: String? = nil
    ) async throws {
        monitor.reload()
        let explicitTarget = targetStorageID.flatMap { storageID in
            monitor.spaces.first { $0.storageID == storageID }
        }
        guard let target = explicitTarget ?? targetSpace(for: snapshot) else {
            throw RestoreError.noTargetWorkspace
        }
        do {
            try switcher.switch(to: target.id)
        } catch {
            throw RestoreError.switchFailed
        }
        monitor.refreshAfterSpaceChange(targetID: target.id)
        try? await Task.sleep(for: .seconds(1))

        for application in snapshot.applications {
            if application.bundleIdentifier == "com.google.Chrome" {
                try await chrome.restore(windows: application.windows)
                continue
            }
            await restoreApplication(application)
        }
    }

    private func targetSpace(for snapshot: WorkspaceSessionSnapshot) -> ParsedSpace? {
        if let exact = monitor.spaces.first(where: { $0.storageID == snapshot.workspaceKey }) {
            return exact
        }
        if let named = monitor.spaces.first(where: {
            names.name(for: $0.storageID, defaultOrdinal: $0.ordinal)
                .localizedCaseInsensitiveCompare(snapshot.workspaceName) == .orderedSame
        }) {
            return named
        }
        if let display = monitor.displays.first(where: { $0.ordinal == snapshot.displayOrdinal }),
           let slotted = display.spaces.first(where: { $0.ordinal == snapshot.spaceOrdinal }) {
            return slotted
        }
        return monitor.activeID.flatMap { active in
            monitor.spaces.first { $0.id == active }
        }
    }

    private func restoreApplication(_ application: WorkspaceCapturedApplication) async {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        ) else { return }
        let resources = application.windows.compactMap(\.resource).compactMap {
            URL(string: $0.value)
        }
        if resources.isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for resource in resources {
            _ = try? await NSWorkspace.shared.open(
                [resource],
                withApplicationAt: appURL,
                configuration: configuration
            )
        }
    }
}
