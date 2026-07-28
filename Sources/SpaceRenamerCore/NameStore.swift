import Foundation

public extension Notification.Name {
    /// Posted by `NameStore` on every name change (rename or forget). Userinfo
    /// `["id": String]` carries the affected storage key — since *Design
    /// Revision 2026-06-09* that is `ParsedSpace.storageID`. Subscribers can
    /// re-query `name(for:defaultOrdinal:)` without coupling through specific
    /// UI controllers.
    static let spaceRenamerNameDidChange = Notification.Name("SpaceRenamer.nameDidChange")
    static let spaceRenamerMenuBarDisplayModeDidChange =
        Notification.Name("SpaceRenamer.menuBarDisplayModeDidChange")
}

@MainActor
public final class NameStore {
    private let defaults: UserDefaults

    private enum Key {
        static let names = "SpaceRenamer.names"               // [SpaceID: String]
        static let warned = "SpaceRenamer.didWarnSystemShortcuts"
        static let switchMode = "SpaceRenamer.switchMode"     // SwitchMode.rawValue
        static let missionControlOverlay = "SpaceRenamer.showMissionControlOverlay"
        static let migratedToUUIDKeys = "SpaceRenamer.didMigrateToUUIDKeys"
        static let menuBarDisplayMode = "SpaceRenamer.menuBarDisplayMode"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var names: [String: String] {
        get { (defaults.dictionary(forKey: Key.names) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.names) }
    }

    public func name(for spaceID: String, defaultOrdinal: Int) -> String {
        if let custom = names[spaceID], !custom.isEmpty { return custom }
        return "Desktop \(defaultOrdinal)"
    }

    public func setName(_ spaceID: String, _ name: String) {
        var dict = names
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: spaceID)
        } else {
            dict[spaceID] = trimmed
        }
        names = dict
        NotificationCenter.default.post(name: .spaceRenamerNameDidChange,
                                        object: nil, userInfo: ["id": spaceID])
    }

    public func forget(_ spaceID: String) {
        var dict = names
        dict.removeValue(forKey: spaceID)
        names = dict
        NotificationCenter.default.post(name: .spaceRenamerNameDidChange,
                                        object: nil, userInfo: ["id": spaceID])
    }

    /// Rewrites stored names under new keys (`remap[oldKey] = newKey`). Used
    /// once at launch to move MSID-keyed entries to restart-stable
    /// `ParsedSpace.storageID` keys (uuid / `"primary"`) — see *Design Revision
    /// 2026-06-09*. An entry already present under the new key wins; the old
    /// key is removed either way. Entries not in `remap` are untouched.
    public func migrateKeys(_ remap: [String: String]) {
        var dict = names
        for (old, new) in remap {
            guard let value = dict.removeValue(forKey: old) else { continue }
            if dict[new] == nil { dict[new] = value }
        }
        names = dict
    }

    /// One-shot guard for the MSID→storageID key migration (names + hotkeys).
    public var didMigrateToUUIDKeys: Bool {
        get { defaults.bool(forKey: Key.migratedToUUIDKeys) }
        set { defaults.set(newValue, forKey: Key.migratedToUUIDKeys) }
    }

    public var didWarnAboutSystemShortcuts: Bool {
        get { defaults.bool(forKey: Key.warned) }
        set { defaults.set(newValue, forKey: Key.warned) }
    }

    /// Desktop-switch delivery mechanism. Missing/invalid → `SwitchMode.default`.
    public var switchMode: SwitchMode {
        get { defaults.string(forKey: Key.switchMode).flatMap(SwitchMode.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.switchMode) }
    }

    /// Per-Space label window visible (huge) in Mission Control thumbnails.
    /// **On by default** — opt-out via Preferences. (Absent key → `true`; an
    /// explicit `false` written by the user still wins.) See *Design Revision
    /// 2026-06-04*.
    public var showMissionControlOverlay: Bool {
        get {
            if defaults.object(forKey: Key.missionControlOverlay) == nil { return true }
            return defaults.bool(forKey: Key.missionControlOverlay)
        }
        set { defaults.set(newValue, forKey: Key.missionControlOverlay) }
    }

    /// How active Space names are represented when more than one display is
    /// connected. Missing/invalid values use the per-display presentation.
    public var menuBarDisplayMode: MenuBarDisplayMode {
        get {
            defaults.string(forKey: Key.menuBarDisplayMode)
                .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .default
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.menuBarDisplayMode)
            NotificationCenter.default.post(
                name: .spaceRenamerMenuBarDisplayModeDidChange,
                object: nil
            )
        }
    }
}
