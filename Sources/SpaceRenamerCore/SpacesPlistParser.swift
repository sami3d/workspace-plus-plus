import Foundation

public struct ParsedSpace: Equatable {
    /// Runtime handle: decimal string of the plist `ManagedSpaceID`. Valid for
    /// the current session only — macOS renumbers MSIDs across logout/restart,
    /// so this must never be used as a persistence key (it was, until the
    /// 2026-06-09 revision; see `storageID`). Switching and window anchoring
    /// SPIs take this.
    public let id: String
    public let ordinal: Int  // 1-based
    /// The space's `uuid` plist field. Persisted by macOS in
    /// `com.apple.spaces.plist` and stable across logout/restart (it is the
    /// identity macOS itself keys per-desktop wallpapers by). Empty for the
    /// primary desktop.
    public let uuid: String

    /// Restart-stable persistence key: the `uuid`, or the `"primary"` sentinel
    /// for the primary desktop (whose uuid is empty). Names and per-desktop
    /// hotkeys are stored under this.
    public var storageID: String { uuid.isEmpty ? "primary" : uuid }

    public init(id: String, ordinal: Int, uuid: String = "") {
        self.id = id
        self.ordinal = ordinal
        self.uuid = uuid
    }
}

public struct ParsedSpaces: Equatable {
    /// User desktops only (`type == 0`), in Mission Control order. Fullscreen
    /// app tiles (`type == 4`) are excluded — they are transient, not
    /// nameable, and macOS inserts them *mid-array* (right after the space
    /// they were entered from), which would otherwise shift every later
    /// desktop's ordinal and leak phantom "Desktop N" entries into the menu
    /// and the Mission Control overlay.
    public let spaces: [ParsedSpace]
    /// The Current Space's MSID — possibly a fullscreen tile's, in which case
    /// it matches no entry in `spaces` (consumers fall back gracefully).
    public let activeID: String?
    /// Full Ctrl+←/→ traversal order — *all* spaces' MSIDs, including
    /// fullscreen tiles. "Move left/right a space" hops through tiles, so the
    /// relative-arrow switcher must count them (and can navigate out of one).
    public let navigationIDs: [String]

    public init(spaces: [ParsedSpace], activeID: String?,
                navigationIDs: [String]? = nil) {
        self.spaces = spaces
        self.activeID = activeID
        self.navigationIDs = navigationIDs ?? spaces.map { $0.id }
    }
}

public enum SpacesPlistError: Error, Equatable {
    case missingConfiguration
    case noMonitors
    case malformedSpaceEntry
}

public enum SpacesPlistParser {

    public static func parse(_ plist: [String: Any]) throws -> ParsedSpaces {
        guard let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let managementData = config["Management Data"] as? [String: Any] else {
            throw SpacesPlistError.missingConfiguration
        }
        // Primary monitor only; multi-display handling is tracked as a separate Phase B concern.
        guard let monitors = managementData["Monitors"] as? [[String: Any]],
              let primary = monitors.first else {
            throw SpacesPlistError.noMonitors
        }
        let spacesArray = (primary["Spaces"] as? [[String: Any]]) ?? []
        var navigationIDs: [String] = []
        var parsed: [ParsedSpace] = []
        for dict in spacesArray {
            guard let managedID = dict["ManagedSpaceID"] as? Int, managedID > 0 else {
                throw SpacesPlistError.malformedSpaceEntry
            }
            navigationIDs.append(String(managedID))
            // Only user desktops (`type == 0`; absent key ⇒ desktop) are
            // Spaces to us — fullscreen tiles (`type == 4`) stay in the
            // traversal order above but get no ordinal/name/menu row.
            guard (dict["type"] as? Int ?? 0) == 0 else { continue }
            let uuid = (dict["uuid"] as? String) ?? ""
            parsed.append(ParsedSpace(id: String(managedID), ordinal: parsed.count + 1, uuid: uuid))
        }
        let activeID = (primary["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        return ParsedSpaces(spaces: parsed, activeID: activeID.map(String.init),
                            navigationIDs: navigationIDs)
    }
}
