import XCTest
@testable import SpaceRenamerCore

@MainActor
final class SpaceMonitorTests: XCTestCase {

    private final class FakeActiveSpaceReader: ActiveSpaceReading {
        var result: ParsedSpaces?
        init(_ result: ParsedSpaces?) { self.result = result }
        func snapshot() -> ParsedSpaces? { result }
    }

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures"))
    }

    func test_skyLightSnapshot_drivesSpacesAndActive() throws {
        let snap = ParsedSpaces(spaces: [ParsedSpace(id: "1", ordinal: 1),
                                         ParsedSpace(id: "9", ordinal: 2)],
                                activeID: "9")
        let monitor = SpaceMonitor(plistURL: try fixtureURL("spaces-3"),
                                   activeSpaceReader: FakeActiveSpaceReader(snap))
        // SkyLight wins over the plist (whose Spaces are 1/2/3, Current 2).
        XCTAssertEqual(monitor.spaces.map { $0.id }, ["1", "9"])
        XCTAssertEqual(monitor.activeID, "9")
        XCTAssertNil(monitor.lastLoadError)
    }

    func test_skyLightNil_fallsBackToPlist() throws {
        let monitor = SpaceMonitor(plistURL: try fixtureURL("spaces-3"),
                                   activeSpaceReader: FakeActiveSpaceReader(nil))
        XCTAssertEqual(monitor.spaces.map { $0.id }, ["1", "2", "3"])
        XCTAssertEqual(monitor.activeID, "2")          // degraded: plist Current Space
        XCTAssertNil(monitor.lastLoadError)
    }

    func test_skyLightNil_missingPlist_setsLastError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMT-missing-\(UUID().uuidString).plist")
        let monitor = SpaceMonitor(plistURL: missing,
                                   activeSpaceReader: FakeActiveSpaceReader(nil))
        XCTAssertTrue(monitor.spaces.isEmpty)
        XCTAssertNil(monitor.activeID)
        XCTAssertNotNil(monitor.lastLoadError)
    }

    func test_skyLightNil_malformedPlist_setsLastError() throws {
        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("SMT-bad-\(UUID().uuidString).plist")
        try Data("not a plist".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let monitor = SpaceMonitor(plistURL: bad, activeSpaceReader: FakeActiveSpaceReader(nil))
        XCTAssertTrue(monitor.spaces.isEmpty)
        XCTAssertNil(monitor.activeID)
        XCTAssertNotNil(monitor.lastLoadError)
    }

    func test_reload_picksUpChangedSnapshot() throws {
        let fake = FakeActiveSpaceReader(ParsedSpaces(spaces: [ParsedSpace(id: "1", ordinal: 1)],
                                                      activeID: "1"))
        let monitor = SpaceMonitor(plistURL: try fixtureURL("spaces-3"),
                                   activeSpaceReader: fake)
        XCTAssertEqual(monitor.spaces.map { $0.id }, ["1"])
        // Simulate a desktop being added (new live snapshot) + reload().
        fake.result = ParsedSpaces(spaces: [ParsedSpace(id: "1", ordinal: 1),
                                            ParsedSpace(id: "7", ordinal: 2)],
                                   activeID: "7")
        monitor.reload()
        XCTAssertEqual(monitor.spaces.map { $0.id }, ["1", "7"])
        XCTAssertEqual(monitor.activeID, "7")
    }

    func test_multipleDisplays_publishPerDisplayActiveState() throws {
        let snap = ParsedSpaces(displays: [
            ParsedDisplay(
                id: "BUILT-IN", ordinal: 1,
                spaces: [ParsedSpace(id: "1", ordinal: 1, displayID: "BUILT-IN")],
                activeID: "1"
            ),
            ParsedDisplay(
                id: "EXTERNAL", ordinal: 2,
                spaces: [ParsedSpace(id: "9", ordinal: 1, displayID: "EXTERNAL")],
                activeID: "9"
            ),
        ])
        let monitor = SpaceMonitor(plistURL: try fixtureURL("spaces-3"),
                                   activeSpaceReader: FakeActiveSpaceReader(snap))

        XCTAssertEqual(monitor.displays.map(\.id), ["BUILT-IN", "EXTERNAL"])
        XCTAssertEqual(monitor.activeIDsByDisplay, ["BUILT-IN": "1", "EXTERNAL": "9"])
    }
}
