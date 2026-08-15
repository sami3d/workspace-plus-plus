import Cocoa
import Combine
import ApplicationServices
import SpaceRenamerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var names: NameStore!
    private var monitor: SpaceMonitor!
    private var switcher: SwitcherEngine!
    private var menuBar: MenuBarController!
    private var hotkeys: HotkeyManager!
    private var overlay: SpaceLabelOverlayManager!
    private var moveWindowPicker: MoveWindowPickerController!
    private var virtualSpaceCreator: VirtualSpaceCreationController!
    private var cloudSync: CloudSyncManager!
    private var historyRestorer: WorkspaceSessionRestorer!
    private var prefs: PreferencesWindowController?
    private var workspaceLibrary: WorkspaceLibraryWindowController?
    private var spaceIDsObserver: AnyCancellable?
    private var raycastSpaceObserver: AnyCancellable?
    private var raycastNameObserver: NSObjectProtocol?
    private var raycastSwitchRequests: RaycastSwitchRequestMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app persists to its own standard UserDefaults domain (keyed by the
        // bundle id). D9: tests use isolated suites; the app must NOT pass its own
        // bundle id as a `suiteName` — UserDefaults rejects that as nonsensical.
        names = NameStore()
        monitor = SpaceMonitor()
        cloudSync = CloudSyncManager(monitor: monitor, names: names)

        // One-shot migration of MSID-keyed names + hotkeys to restart-stable
        // storage IDs (uuid / "primary") — Design Revision 2026-06-09. Needs a
        // live snapshot for the current MSID→storageID mapping; on a degraded
        // launch (no spaces) the flag stays unset and we retry next launch.
        if !names.didMigrateToUUIDKeys, !monitor.spaces.isEmpty {
            let remap = Dictionary(uniqueKeysWithValues: monitor.spaces.map { ($0.id, $0.storageID) })
            names.migrateKeys(remap)
            HotkeyManager.migrateSpaceShortcuts(remap)
            names.didMigrateToUUIDKeys = true
        }
        // Routing switcher reads the user's SwitchMode per call, so the
        // Preferences toggle takes effect on the next switch (no relaunch).
        switcher = SwitcherEngine(
            spaceSwitcher: ModeRoutingSpaceSwitcher(mode: { [weak names] in names?.switchMode ?? .default }),
            lookup: monitor)   // AppDelegate retains `monitor` (SwitcherEngine holds it weakly)
        historyRestorer = WorkspaceSessionRestorer(
            monitor: monitor,
            names: names,
            switcher: switcher
        )

        moveWindowPicker = MoveWindowPickerController(
            monitor: monitor,
            names: names,
            switcher: switcher
        )
        virtualSpaceCreator = VirtualSpaceCreationController(
            monitor: monitor,
            onDisplayTopologyRestored: { [weak self] in
                self?.menuBar.recoverAfterDisplayTransition()
            }
        )
        menuBar = MenuBarController(
            monitor: monitor,
            names: names,
            switcher: switcher,
            openMoveWindowPicker: { [weak self] in self?.moveWindowPicker.showPicker() },
            createWorkspace: { [weak self] in self?.virtualSpaceCreator.requestCreation() },
            openWorkspaceLibrary: { [weak self] in self?.showWorkspaceLibrary() },
            openPreferences: { [weak self] in self?.showPreferences() }
        )

        // The Chrome companion ships inside Workspace++. Keep its stable copy
        // and native-host registration current automatically. Chrome alone
        // owns the remaining one-time extension approval.
        do {
            _ = try ChromeExtensionBridge().installBundledComponents()
        } catch {
            NSLog("Workspace++: Chrome companion preparation failed: %@",
                  error.localizedDescription)
        }

        // Mission Control overlay labels (per-Space window with two visual
        // modes). Disabled by default; enabled via Preferences. The manager
        // is constructed unconditionally so toggling on at runtime needs no
        // additional wiring; setEnabled(true) is what actually spawns windows.
        overlay = SpaceLabelOverlayManager(monitor: monitor, names: names)
        overlay.setEnabled(names.showMissionControlOverlay)

        hotkeys = HotkeyManager()
        // Hotkeys are keyed by storageID (restart-stable); the switcher takes
        // the session MSID — resolve through the live snapshot.
        hotkeys.onSpaceHotkey = { [weak self] storageID in
            guard let self,
                  let id = self.monitor.spaces.first(where: { $0.storageID == storageID })?.id
            else { return }
            do {
                try self.switcher.switch(to: id)
                self.monitor.refreshAfterSpaceChange(targetID: id)
            }
            catch { NSLog("Workspace++: hotkey switch failed: \(error)") }
        }
        hotkeys.onOpenMenu = { [weak self] in self?.menuBar.openMenu() }
        hotkeys.onMoveFocusedWindow = { [weak self] in
            self?.moveWindowPicker.showPicker()
        }
        spaceIDsObserver = monitor.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces in self?.hotkeys.sync(knownIDs: spaces.map { $0.storageID }) }

        // Publish a live, stable-ID index for the local Raycast extension.
        // Unlike the Mission Control menu bridge, this never opens UI or
        // steals focus from Raycast.
        raycastSpaceObserver = Publishers.CombineLatest(monitor.$spaces, monitor.$activeIDsByDisplay)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spaces, activeIDs in
                guard let self else { return }
                RaycastSpaceIndex.write(spaces: spaces,
                                        activeIDsByDisplay: activeIDs,
                                        names: self.names)
            }
        raycastNameObserver = NotificationCenter.default.addObserver(
            forName: .spaceRenamerNameDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.writeRaycastSpaceIndex() }
        }
        raycastSwitchRequests = RaycastSwitchRequestMonitor { [weak self] storageID in
            self?.switchToRaycastStorageID(storageID)
        }

        cloudSync.start()

        // Defer the first-run alerts off the synchronous launch path so the
        // status item appears first and the modal isn't the very first thing
        // the user sees on a cold start (#31).
        DispatchQueue.main.async { [weak self] in
            self?.promptForAccessibilityIfNeeded()
            self?.warnIfSwitchShortcutsDisabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {}

    private func switchToRaycastStorageID(_ storageID: String) {
        guard let managedSpaceID = monitor.spaces
            .first(where: { $0.storageID == storageID })?.id else {
            NSLog("Workspace++: Raycast requested unknown storage ID \(storageID)")
            return
        }
        do {
            try switcher.switch(to: managedSpaceID)
            monitor.refreshAfterSpaceChange(targetID: managedSpaceID)
        } catch {
            NSLog("Workspace++: Raycast switch failed for \(storageID): \(error)")
        }
    }

    private func writeRaycastSpaceIndex() {
        RaycastSpaceIndex.write(spaces: monitor.spaces,
                                activeIDsByDisplay: monitor.activeIDsByDisplay,
                                names: names)
    }

    private func showPreferences() {
        if prefs == nil {
            prefs = PreferencesWindowController(
                monitor: monitor,
                names: names,
                cloud: cloudSync,
                historyRestorer: historyRestorer,
                overlayChanged: { [weak self] enabled in
                    self?.overlay.setEnabled(enabled)
                }
            )
        }
        prefs?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showWorkspaceLibrary() {
        if workspaceLibrary == nil {
            workspaceLibrary = WorkspaceLibraryWindowController(
                cloud: cloudSync,
                restorer: historyRestorer,
                monitor: monitor,
                names: names
            )
        }
        workspaceLibrary?.showWindow(nil)
        workspaceLibrary?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func promptForAccessibilityIfNeeded() {
        // Switching desktops posts a synthesized Ctrl+digit CGEvent, which macOS
        // only delivers if this process is Accessibility-trusted; otherwise the
        // events are silently dropped. AXIsProcessTrustedWithOptions with the
        // prompt option triggers the system prompt when not yet trusted.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { return }

        let alert = NSAlert()
        alert.messageText = "Grant Accessibility access"
        alert.informativeText = "Workspace++ switches desktops by sending the macOS \u{201C}Switch to Desktop\u{201D} keyboard shortcut, which requires Accessibility permission. Enable \u{201C}Workspace++\u{201D} under System Settings \u{2192} Privacy & Security \u{2192} Accessibility, then clicking a desktop will switch. (Ad-hoc development builds may need re-granting after a rebuild.)"
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func warnIfSwitchShortcutsDisabled() {
        guard !names.didWarnAboutSystemShortcuts else { return }
        let mode = names.switchMode
        let enabled: Bool
        switch mode {
        case .arrow:     enabled = SystemShortcutChecker.spaceMoveShortcutsEnabled()
        case .ctrlDigit: enabled = SystemShortcutChecker.switchToDesktopShortcutsEnabled()
        }
        guard !enabled else { return }
        // Set before showing the modal on purpose: a one-shot warning — we do not
        // want to re-prompt every launch if the user force-quits during the alert.
        names.didWarnAboutSystemShortcuts = true

        let alert = NSAlert()
        alert.messageText = "Enable Mission Control shortcuts"
        switch mode {
        case .arrow:
            alert.informativeText = "Workspace++ switches desktops using the \u{201C}Move left a space\u{201D} and \u{201C}Move right a space\u{201D} keyboard shortcuts (Ctrl+\u{2190} / Ctrl+\u{2192}). Enable both in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Mission Control, or clicking a desktop won\u{2019}t switch. (Or pick \u{201C}Switch to Desktop N\u{201D} mode in Preferences.)"
        case .ctrlDigit:
            alert.informativeText = "Workspace++ is set to switch via the \u{201C}Switch to Desktop N\u{201D} shortcuts (Ctrl+1\u{2013}9). Enable them in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Mission Control, or clicking a desktop won\u{2019}t switch. (Or pick \u{201C}Move a space\u{201D} mode in Preferences.)"
        }
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
