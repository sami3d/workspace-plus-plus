import XCTest
@testable import SpaceRenamerCore

/// Ctrl+1…9 switcher: posts `postControlDigit(ordinal)` for desktops 1–9,
/// returns false for >9 (no such macOS hotkey) and for resolution failures.
final class CtrlDigitSpaceSwitcherTests: XCTestCase {

    private final class FakeReader: ActiveSpaceReading {
        var result: ParsedSpaces?
        func snapshot() -> ParsedSpaces? { result }
    }

    private final class SpySynth: KeystrokeSynthesizing {
        var digits: [Int] = []
        var keys: [CGKeyCode] = []
        var throwOnDigit = false
        func postControlDigit(_ digit: Int) throws {
            if throwOnDigit { throw KeystrokeError.eventSourceUnavailable }
            digits.append(digit)
        }
        func postControlKey(_ keyCode: CGKeyCode) throws { keys.append(keyCode) }
    }

    private final class SpyDisplayTargeter: DisplayTargeting {
        var displayIDs: [String] = []
        func perform(onManagedDisplayID displayID: String, action: () -> Bool) -> Bool {
            displayIDs.append(displayID)
            return action()
        }
    }

    private func snapshot(_ ids: [String]) -> ParsedSpaces {
        ParsedSpaces(spaces: ids.enumerated().map { ParsedSpace(id: $0.element, ordinal: $0.offset + 1) },
                     activeID: ids.first)
    }

    private func make(_ r: FakeReader, _ s: SpySynth,
                      _ targeter: SpyDisplayTargeter = SpyDisplayTargeter())
        -> CtrlDigitSpaceSwitcher {
        CtrlDigitSpaceSwitcher(reader: r, synthesizer: s, displayTargeter: targeter)
    }

    func test_ordinalWithin1to9_postsControlDigit_returnsTrue() {
        let r = FakeReader(); r.result = snapshot(["a","b","c","d"])  // "c" is ordinal 3
        let s = SpySynth()
        XCTAssertTrue(make(r, s).setCurrentSpace(managedSpaceID: "c"))
        XCTAssertEqual(s.digits, [3])
        XCTAssertTrue(s.keys.isEmpty)
    }

    func test_ordinalAbove9_returnsFalse_noPost() {
        // 11 spaces; target is the 11th → no Ctrl+11 exists.
        let ids = (1...11).map(String.init)
        let r = FakeReader(); r.result = snapshot(ids)
        let s = SpySynth()
        XCTAssertFalse(make(r, s).setCurrentSpace(managedSpaceID: "11"))
        XCTAssertTrue(s.digits.isEmpty)
    }

    func test_readerUnavailable_returnsFalse() {
        let r = FakeReader(); r.result = nil
        let s = SpySynth()
        XCTAssertFalse(make(r, s).setCurrentSpace(managedSpaceID: "a"))
        XCTAssertTrue(s.digits.isEmpty)
    }

    func test_targetNotInSnapshot_returnsFalse() {
        let r = FakeReader(); r.result = snapshot(["a","b"])
        let s = SpySynth()
        XCTAssertFalse(make(r, s).setCurrentSpace(managedSpaceID: "zzz"))
    }

    func test_synthesizerThrows_returnsFalse() {
        let r = FakeReader(); r.result = snapshot(["a","b","c"])
        let s = SpySynth(); s.throwOnDigit = true
        XCTAssertFalse(make(r, s).setCurrentSpace(managedSpaceID: "b"))
    }

    func test_targetOnExternalDisplay_targetsThatDisplay() {
        let r = FakeReader()
        r.result = ParsedSpaces(displays: [
            ParsedDisplay(
                id: "BUILT-IN", ordinal: 1,
                spaces: [ParsedSpace(id: "1", ordinal: 1, displayID: "BUILT-IN")],
                activeID: "1"
            ),
            ParsedDisplay(
                id: "EXTERNAL", ordinal: 2,
                spaces: [
                    ParsedSpace(id: "9", ordinal: 1, displayID: "EXTERNAL"),
                    ParsedSpace(id: "10", ordinal: 2, displayID: "EXTERNAL"),
                ],
                activeID: "9"
            ),
        ])
        let s = SpySynth()
        let targeter = SpyDisplayTargeter()

        XCTAssertTrue(make(r, s, targeter).setCurrentSpace(managedSpaceID: "10"))
        XCTAssertEqual(s.digits, [2])
        XCTAssertEqual(targeter.displayIDs, ["EXTERNAL"])
    }
}
