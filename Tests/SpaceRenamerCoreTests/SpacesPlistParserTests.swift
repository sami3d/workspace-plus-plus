import XCTest
@testable import SpaceRenamerCore

final class SpacesPlistParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
    }

    func test_singleSpace_isParsed() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-1"))
        XCTAssertEqual(result.spaces.map { $0.id }, ["1"])
        XCTAssertEqual(result.spaces.map { $0.ordinal }, [1])
        XCTAssertEqual(result.activeID, "1")
    }

    func test_threeSpaces_activeIsMiddle() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-3"))
        XCTAssertEqual(result.spaces.map { $0.id }, ["1", "2", "3"])
        XCTAssertEqual(result.spaces.map { $0.ordinal }, [1, 2, 3])
        XCTAssertEqual(result.activeID, "2")
    }

    func test_nineSpaces_fifthActive() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-9"))
        XCTAssertEqual(result.spaces.count, 9)
        XCTAssertEqual(result.spaces.map { $0.id }, ["1","2","3","4","5","6","7","8","9"])
        XCTAssertEqual(result.activeID, "5")
    }

    func test_reorderedSpaces_ordinalsReflectNewOrder() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-reordered"))
        XCTAssertEqual(result.spaces.map { $0.id }, ["3", "1", "2"])
        XCTAssertEqual(result.spaces.map { $0.ordinal }, [1, 2, 3])
        XCTAssertEqual(result.activeID, "1")
    }

    func test_realCapture_defaultDesktopHasStableIDAndIsActive() throws {
        // The default desktop has an empty uuid in the real plist; ManagedSpaceID
        // gives it a stable identity ("1") and makes it detectable as active.
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-real"))
        XCTAssertEqual(result.spaces.map { $0.id }, ["1", "3", "4", "5"])
        XCTAssertEqual(result.spaces.map { $0.ordinal }, [1, 2, 3, 4])
        XCTAssertEqual(result.activeID, "1")
    }

    func test_realCapture_uuidsParsed() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-real"))
        XCTAssertEqual(result.spaces.map { $0.uuid },
                       ["",
                        "9DD24797-CA38-435A-8F4C-1EE03CB1B7CA",
                        "8B3CC061-9B05-4356-A685-81E538C8DBAD",
                        "B39FF9FA-F09B-40AA-9C64-C3C3E8EF661B"])
    }

    func test_storageID_isUUID_orPrimarySentinelWhenUUIDEmpty() throws {
        // The default desktop's uuid is empty in the real plist; its storage
        // identity is the "primary" sentinel. All others use their uuid.
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-real"))
        XCTAssertEqual(result.spaces.map { $0.storageID },
                       ["primary",
                        "9DD24797-CA38-435A-8F4C-1EE03CB1B7CA",
                        "8B3CC061-9B05-4356-A685-81E538C8DBAD",
                        "B39FF9FA-F09B-40AA-9C64-C3C3E8EF661B"])
    }

    func test_spaceEntryWithoutUuidKey_parsesWithEmptyUuid() throws {
        let plist: [String: Any] = [
            "SpacesDisplayConfiguration": [
                "Management Data": [
                    "Monitors": [
                        ["Spaces": [["ManagedSpaceID": 7]]]
                    ]
                ]
            ]
        ]
        let result = try SpacesPlistParser.parse(plist)
        XCTAssertEqual(result.spaces.map { $0.uuid }, [""])
        XCTAssertEqual(result.spaces.map { $0.storageID }, ["primary"])
    }

    // MARK: - Fullscreen-app spaces (type 4)

    // The fixture mirrors a real CGSCopyManagedDisplaySpaces capture taken
    // while an app was fullscreen: macOS inserts a `type = 4` space (the
    // fullscreen tile) *mid-array*, right after the space it was entered from,
    // and makes it the Current Space.

    func test_fullscreenSpace_excludedFromSpaces_ordinalsStayContiguous() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-fullscreen"))
        XCTAssertEqual(result.spaces.map { $0.id }, ["3", "1", "4"])
        XCTAssertEqual(result.spaces.map { $0.ordinal }, [1, 2, 3])
    }

    func test_fullscreenSpace_includedInNavigationIDs_inTraversalOrder() throws {
        // Ctrl+←/→ ("Move left/right a space") traverses fullscreen tiles too,
        // so the arrow switcher needs the *full* order including type-4 spaces.
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-fullscreen"))
        XCTAssertEqual(result.navigationIDs, ["3", "353", "1", "4"])
    }

    func test_currentSpaceIsFullscreen_activeIDPreserved() throws {
        // While the user is in a fullscreen app, the active id is the tile's
        // MSID — deliberately NOT remapped to a desktop. Consumers fall back
        // (generic menu-bar title; overlay shows all desktop banners as
        // non-active, which is correct for the Mission Control thumbnails).
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-fullscreen"))
        XCTAssertEqual(result.activeID, "353")
        XCTAssertFalse(result.spaces.contains { $0.id == "353" })
    }

    func test_navigationIDs_equalSpaceIDs_whenNoFullscreenSpaces() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-real"))
        XCTAssertEqual(result.navigationIDs, result.spaces.map { $0.id })
    }

    func test_emptyPlist_throws() {
        XCTAssertThrowsError(try SpacesPlistParser.parse([:])) { err in
            XCTAssertEqual(err as? SpacesPlistError, .missingConfiguration)
        }
    }

    func test_missingMonitors_throws() {
        let bad: [String: Any] = ["SpacesDisplayConfiguration": ["Management Data": [String: Any]()]]
        XCTAssertThrowsError(try SpacesPlistParser.parse(bad)) { err in
            XCTAssertEqual(err as? SpacesPlistError, .noMonitors)
        }
    }

    func test_spaceEntryMissingManagedSpaceID_throws() {
        let bad: [String: Any] = [
            "SpacesDisplayConfiguration": [
                "Management Data": [
                    "Monitors": [
                        ["Spaces": [["uuid": "x"]]]
                    ]
                ]
            ]
        ]
        XCTAssertThrowsError(try SpacesPlistParser.parse(bad)) { err in
            XCTAssertEqual(err as? SpacesPlistError, .malformedSpaceEntry)
        }
    }

    func test_spaceEntryWithNonPositiveManagedSpaceID_throws() {
        let bad: [String: Any] = [
            "SpacesDisplayConfiguration": [
                "Management Data": [
                    "Monitors": [
                        ["Spaces": [["ManagedSpaceID": 0]]]
                    ]
                ]
            ]
        ]
        XCTAssertThrowsError(try SpacesPlistParser.parse(bad)) { err in
            XCTAssertEqual(err as? SpacesPlistError, .malformedSpaceEntry)
        }
    }

    func test_tenSpaces_parsedWithTenOrdinals() throws {
        let result = try SpacesPlistParser.parse(try loadFixture("spaces-10"))
        XCTAssertEqual(result.spaces.map { $0.id }, ["1","2","3","4","5","6","7","8","9","10"])
        XCTAssertEqual(result.spaces.map { $0.ordinal }, Array(1...10))
        XCTAssertEqual(result.activeID, "1")
        // (>9 desktops are fully switchable since Design Revision 2026-05-17c;
        // no shortcut-availability cap remains on ParsedSpace.)
    }

    func test_multipleDisplays_allSpacesParsedAndGrouped() throws {
        let plist: [String: Any] = [
            "SpacesDisplayConfiguration": [
                "Management Data": [
                    "Monitors": [
                        [
                            "Display Identifier": "BUILT-IN",
                            "Current Space": ["ManagedSpaceID": 2],
                            "Spaces": [
                                ["ManagedSpaceID": 1, "uuid": "A"],
                                ["ManagedSpaceID": 2, "uuid": "B"],
                            ],
                        ],
                        [
                            "Display Identifier": "EXTERNAL",
                            "Current Space": ["ManagedSpaceID": 9],
                            "Spaces": [
                                ["ManagedSpaceID": 9, "uuid": "C"],
                                ["ManagedSpaceID": 10, "uuid": "D"],
                            ],
                        ],
                    ]
                ]
            ]
        ]

        let result = try SpacesPlistParser.parse(plist)
        XCTAssertEqual(result.displays.map(\.id), ["BUILT-IN", "EXTERNAL"])
        XCTAssertEqual(result.displays[0].spaces.map(\.id), ["1", "2"])
        XCTAssertEqual(result.displays[1].spaces.map(\.id), ["9", "10"])
        XCTAssertEqual(result.spaces.map(\.displayID),
                       ["BUILT-IN", "BUILT-IN", "EXTERNAL", "EXTERNAL"])
        XCTAssertEqual(result.activeIDsByDisplay,
                       ["BUILT-IN": "2", "EXTERNAL": "9"])
    }
}
