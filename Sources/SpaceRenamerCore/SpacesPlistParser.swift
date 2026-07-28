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
    /// Stable managed-display identifier returned by SkyLight. This maps to
    /// the CoreGraphics display UUID used by `NSScreen`.
    public let displayID: String

    /// Restart-stable persistence key: the `uuid`, or the `"primary"` sentinel
    /// for the main display's primary desktop. A display-qualified fallback is
    /// used for an empty UUID on any additional display.
    public var storageID: String {
        guard uuid.isEmpty else { return uuid }
        return displayID == "Main" || displayID.isEmpty
            ? "primary"
            : "primary@\(displayID)"
    }

    public init(id: String, ordinal: Int, uuid: String = "", displayID: String = "Main") {
        self.id = id
        self.ordinal = ordinal
        self.uuid = uuid
        self.displayID = displayID
    }
}

public struct ParsedDisplay: Equatable {
    public let id: String
    public let ordinal: Int
    public let spaces: [ParsedSpace]
    public let activeID: String?
    public let navigationIDs: [String]

    public init(id: String, ordinal: Int, spaces: [ParsedSpace],
                activeID: String?, navigationIDs: [String]? = nil) {
        self.id = id
        self.ordinal = ordinal
        self.spaces = spaces
        self.activeID = activeID
        self.navigationIDs = navigationIDs ?? spaces.map(\.id)
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
    /// Per-display snapshots in managed-display order.
    public let displays: [ParsedDisplay]

    public init(spaces: [ParsedSpace], activeID: String?,
                navigationIDs: [String]? = nil) {
        self.spaces = spaces
        self.activeID = activeID
        self.navigationIDs = navigationIDs ?? spaces.map { $0.id }
        let displayID = spaces.first?.displayID ?? "Main"
        self.displays = [
            ParsedDisplay(id: displayID, ordinal: 1, spaces: spaces,
                          activeID: activeID, navigationIDs: self.navigationIDs)
        ]
    }

    public init(displays: [ParsedDisplay]) {
        self.displays = displays
        self.spaces = displays.flatMap(\.spaces)
        self.activeID = displays.first?.activeID
        self.navigationIDs = displays.first?.navigationIDs ?? []
    }

    public var activeIDsByDisplay: [String: String] {
        Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            display.activeID.map { (display.id, $0) }
        })
    }

    public func display(containingSpaceID id: String) -> ParsedDisplay? {
        displays.first { display in
            display.navigationIDs.contains(id)
        }
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
        guard let monitors = managementData["Monitors"] as? [[String: Any]],
              !monitors.isEmpty else {
            throw SpacesPlistError.noMonitors
        }
        let displays = try monitors.enumerated().map { offset, monitor -> ParsedDisplay in
            let displayID = (monitor["Display Identifier"] as? String)
                ?? (offset == 0 ? "Main" : "Display-\(offset + 1)")
            let spacesArray = (monitor["Spaces"] as? [[String: Any]]) ?? []
            var navigationIDs: [String] = []
            var parsed: [ParsedSpace] = []
            for dict in spacesArray {
                guard let managedID = dict["ManagedSpaceID"] as? Int, managedID > 0 else {
                    throw SpacesPlistError.malformedSpaceEntry
                }
                navigationIDs.append(String(managedID))
                // Only user desktops (`type == 0`; absent key ⇒ desktop) are
                // Spaces to us. Fullscreen tiles remain in traversal order.
                guard (dict["type"] as? Int ?? 0) == 0 else { continue }
                let uuid = (dict["uuid"] as? String) ?? ""
                parsed.append(ParsedSpace(id: String(managedID),
                                          ordinal: parsed.count + 1,
                                          uuid: uuid,
                                          displayID: displayID))
            }
            let activeID = (monitor["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            return ParsedDisplay(id: displayID, ordinal: offset + 1,
                                 spaces: parsed,
                                 activeID: activeID.map(String.init),
                                 navigationIDs: navigationIDs)
        }
        return ParsedSpaces(displays: displays)
    }
}
