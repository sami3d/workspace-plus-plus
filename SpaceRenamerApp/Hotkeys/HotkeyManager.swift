import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openMenu = Self("openMenu")
    static let moveFocusedWindow = Self("moveFocusedWindow")
    /// `id` is the restart-stable `ParsedSpace.storageID` (uuid / "primary"),
    /// NOT the session-scoped ManagedSpaceID — Design Revision 2026-06-09.
    static func space(_ id: String) -> Self { Self("space.\(id)") }
}

@MainActor
final class HotkeyManager {
    /// Fired when a Space's hotkey is pressed; argument is the Space id.
    var onSpaceHotkey: ((String) -> Void)?
    /// Fired when the open-menu hotkey is pressed.
    var onOpenMenu: (() -> Void)?
    /// Fired when the move-focused-window picker hotkey is pressed.
    var onMoveFocusedWindow: (() -> Void)?

    private var registeredIDs: Set<String> = []

    init() {
        KeyboardShortcuts.onKeyUp(for: .openMenu) { [weak self] in
            self?.onOpenMenu?()
        }
        KeyboardShortcuts.onKeyUp(for: .moveFocusedWindow) { [weak self] in
            self?.onMoveFocusedWindow?()
        }
    }

    /// One-shot launch migration: move recorded per-Space shortcuts from the
    /// old MSID-keyed names to restart-stable storageID-keyed names
    /// (`remap[msid] = storageID`). Mirrors `NameStore.migrateKeys`: an
    /// already-recorded shortcut under the new name wins; the old entry is
    /// cleared either way.
    static func migrateSpaceShortcuts(_ remap: [String: String]) {
        for (old, new) in remap {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: .space(old)) else { continue }
            if KeyboardShortcuts.getShortcut(for: .space(new)) == nil {
                KeyboardShortcuts.setShortcut(shortcut, for: .space(new))
            }
            KeyboardShortcuts.setShortcut(nil, for: .space(old))
        }
    }

    /// Idempotently register a keyUp handler for each known Space id.
    func sync(knownIDs: [String]) {
        for id in knownIDs where !registeredIDs.contains(id) {
            KeyboardShortcuts.onKeyUp(for: .space(id)) { [weak self] in
                self?.onSpaceHotkey?(id)
            }
            registeredIDs.insert(id)
        }
    }
}
