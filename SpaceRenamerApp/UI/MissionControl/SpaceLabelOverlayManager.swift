import AppKit
import Combine
import SpaceRenamerCore

/// Owns one `SpaceLabelWindow` per known Space. Watches `SpaceMonitor.$spaces`
/// (create/destroy as Spaces are added/removed) and `$activeID` (toggle each
/// window between active/preview mode), plus `NotificationCenter`
/// `.spaceRenamerNameDidChange` and `.spaceRenamerColorDidChange` to update
/// each label's text and background without rebuilding its anchored window.
///
/// Enable/disable is driven by the Preferences "Show name in Mission Control"
/// checkbox via `setEnabled(_:)`. When disabled, all windows are torn down and
/// subscriptions cancelled so the feature has zero cost when off.
///
/// See *Design Revision 2026-06-04*.
@MainActor
final class SpaceLabelOverlayManager {
    private let monitor: SpaceMonitor
    private let names: NameStore
    private let anchor: SpaceWindowAnchoring

    private var windows: [String: SpaceLabelWindow] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var nameChangeObserver: NSObjectProtocol?
    private var colorChangeObserver: NSObjectProtocol?
    private var appearanceChangeObserver: NSObjectProtocol?
    private(set) var isEnabled = false

    init(monitor: SpaceMonitor, names: NameStore,
         anchor: SpaceWindowAnchoring = CGSSpaceWindowAnchor()) {
        self.monitor = monitor
        self.names = names
        self.anchor = anchor
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            subscribe()
            sync(spaces: monitor.spaces, activeIDsByDisplay: monitor.activeIDsByDisplay)
        } else {
            cancellables.removeAll()
            if let obs = nameChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                nameChangeObserver = nil
            }
            if let obs = colorChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                colorChangeObserver = nil
            }
            if let obs = appearanceChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                appearanceChangeObserver = nil
            }
            tearDownAllWindows()
        }
    }

    private func subscribe() {
        Publishers.CombineLatest(monitor.$spaces, monitor.$activeIDsByDisplay)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces, activeIDs in
                self?.sync(spaces: spaces, activeIDsByDisplay: activeIDs)
            }
            .store(in: &cancellables)

        nameChangeObserver = NotificationCenter.default.addObserver(
            forName: .spaceRenamerNameDidChange, object: nil, queue: .main
        ) { [weak self] note in
            // The closure is nonisolated by `addObserver` contract even though
            // `.main` queue is used. Extract the Sendable id *here* (the
            // Notification itself is non-Sendable and can't cross into the
            // `Task @MainActor`).
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in
                guard let self else { return }
                // The notification carries the storageID (names are stored by
                // it); windows are keyed by the session MSID.
                guard let space = self.monitor.spaces.first(where: { $0.storageID == id }),
                      let window = self.windows[space.id] else { return }
                window.setName(self.names.name(for: id, defaultOrdinal: space.ordinal))
            }
        }

        colorChangeObserver = NotificationCenter.default.addObserver(
            forName: .spaceRenamerColorDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in
                guard let self,
                      let space = self.monitor.spaces.first(where: { $0.storageID == id }),
                      let window = self.windows[space.id] else { return }
                window.setColor(
                    WorkspaceColor.color(from: self.names.colorHex(for: id))
                )
            }
        }

        appearanceChangeObserver = NotificationCenter.default.addObserver(
            forName: .spaceRenamerOverlayAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Layout constraints differ between the centered-band and
                // full-screen treatments, so recreate and re-anchor the
                // lightweight windows when either preference changes.
                self.tearDownAllWindows()
                self.sync(
                    spaces: self.monitor.spaces,
                    activeIDsByDisplay: self.monitor.activeIDsByDisplay
                )
            }
        }
    }

    private func sync(spaces: [ParsedSpace], activeIDsByDisplay: [String: String]) {
        let live = Set(spaces.map(\.id))

        // Tear down windows whose Space no longer exists.
        for id in Array(windows.keys) where !live.contains(id) {
            windows[id]?.close()
            windows.removeValue(forKey: id)
        }

        // Create / update windows for current Spaces. The active Space's
        // banner is transient (fades after a moment); the non-active windows
        // stay visible for the Mission Control thumbnails.
        for space in spaces {
            guard let screen = DisplayResolver.screen(for: space.displayID) else { continue }
            let name = names.name(for: space.storageID, defaultOrdinal: space.ordinal)
            let color = WorkspaceColor.color(
                from: names.colorHex(for: space.storageID)
            )
            let isActive = (space.id == activeIDsByDisplay[space.displayID])
            if let window = windows[space.id] {
                window.setName(name)
                window.setColor(color)
                window.setIsActiveSpace(isActive)
            } else {
                let window = SpaceLabelWindow(
                    spaceId: space.id,
                    name: name,
                    color: color,
                    backgroundOpacity: CGFloat(
                        names.overlayBackgroundOpacity
                    ),
                    showsAppWindows: names.overlayShowsAppWindows,
                    screen: screen
                )
                window.orderFrontRegardless()
                _ = anchor.anchor(windowNumber: window.windowNumber, toSpaceID: space.id)
                window.startRenderingLoop()
                window.setIsActiveSpace(isActive)
                windows[space.id] = window
            }
        }
    }

    private func tearDownAllWindows() {
        for window in windows.values { window.close() }
        windows.removeAll()
    }
}
