import Foundation
import SpaceRenamerCore

/// A small, live, read-only index consumed by the local Raycast extension.
/// Stable storage IDs are exposed instead of session-scoped ManagedSpaceIDs;
/// Workspace++ resolves the storage ID against its current snapshot when a
/// switch URL arrives.
@MainActor
enum RaycastSpaceIndex {
    struct Document: Codable {
        let version: Int
        let generatedAt: Date
        let spaces: [Entry]
    }

    struct Entry: Codable {
        let storageID: String
        let name: String
        let ordinal: Int
        let displayName: String
        let isActive: Bool
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Space Renamer", isDirectory: true)
        .appendingPathComponent("raycast-spaces.json")

    static func write(spaces: [ParsedSpace],
                      activeIDsByDisplay: [String: String],
                      names: NameStore) {
        var displayOrdinals: [String: Int] = [:]
        for space in spaces where displayOrdinals[space.displayID] == nil {
            displayOrdinals[space.displayID] = displayOrdinals.count + 1
        }
        let entries = spaces.map { space in
            Entry(
                storageID: space.storageID,
                name: names.name(for: space.storageID, defaultOrdinal: space.ordinal),
                ordinal: space.ordinal,
                displayName: DisplayResolver.name(
                    for: space.displayID,
                    ordinal: displayOrdinals[space.displayID] ?? 1
                ),
                isActive: activeIDsByDisplay[space.displayID] == space.id
            )
        }
        let document = Document(version: 1, generatedAt: Date(), spaces: entries)

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Workspace++: failed to write Raycast space index: \(error)")
        }
    }
}
