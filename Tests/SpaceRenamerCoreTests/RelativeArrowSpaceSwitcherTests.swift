import XCTest
@testable import SpaceRenamerCore

/// Unit-tests the signed-ordinal-delta logic of the relative-arrow switcher
/// (direction + press count). The keystrokes' visual effect can only be
/// verified on a real machine; the delta math is fully testable here.
final class RelativeArrowSpaceSwitcherTests: XCTestCase {

    private final class FakeReader: ActiveSpaceReading {
        var result: ParsedSpaces?
        func snapshot() -> ParsedSpaces? { result }
    }

    private final class SpySynth: KeystrokeSynthesizing {
        var keys: [CGKeyCode] = []
        var throwAtCall: Int?     // 1-based call index to throw on
        private var calls = 0
        func postControlDigit(_ digit: Int) throws { /* unused by the switcher */ }
        func postControlKey(_ keyCode: CGKeyCode) throws {
            calls += 1
            if let t = throwAtCall, calls == t { throw KeystrokeError.eventSourceUnavailable }
            keys.append(keyCode)
        }
    }

    private let left = CGKeystrokeSynthesizer.leftArrowKeyCode    // 123
    private let right = CGKeystrokeSynthesizer.rightArrowKeyCode  // 124

    /// Mirrors the real-machine SkyLight order from the diagnostic log.
    private func snapshot(active: String) -> ParsedSpaces {
        let ids = ["4", "1", "3", "5", "79", "81", "82", "83", "119", "111", "132"]
        let spaces = ids.enumerated().map { ParsedSpace(id: $0.element, ordinal: $0.offset + 1) }
        return ParsedSpaces(spaces: spaces, activeID: active)
    }

    private func makeSwitcher(_ reader: FakeReader, _ synth: SpySynth) -> RelativeArrowSpaceSwitcher {
        RelativeArrowSpaceSwitcher(reader: reader, synthesizer: synth, pace: {})
    }

    func test_forwardDelta_postsRightArrowThatManyTimes() {
        let reader = FakeReader(); reader.result = snapshot(active: "1")   // ordinal 2
        let synth = SpySynth()
        // target "132" is ordinal 11 → delta +9 → 9 × Ctrl+→
        XCTAssertTrue(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "132"))
        XCTAssertEqual(synth.keys, Array(repeating: right, count: 9))
    }

    func test_backwardDelta_postsLeftArrowThatManyTimes() {
        let reader = FakeReader(); reader.result = snapshot(active: "79")  // ordinal 5
        let synth = SpySynth()
        // target "1" is ordinal 2 → delta -3 → 3 × Ctrl+←
        XCTAssertTrue(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "1"))
        XCTAssertEqual(synth.keys, Array(repeating: left, count: 3))
    }

    func test_alreadyOnTarget_postsNothing_returnsTrue() {
        let reader = FakeReader(); reader.result = snapshot(active: "3")
        let synth = SpySynth()
        XCTAssertTrue(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "3"))
        XCTAssertTrue(synth.keys.isEmpty)
    }

    func test_readerUnavailable_returnsFalse() {
        let reader = FakeReader(); reader.result = nil
        let synth = SpySynth()
        XCTAssertFalse(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "1"))
        XCTAssertTrue(synth.keys.isEmpty)
    }

    func test_noActiveID_returnsFalse() {
        let reader = FakeReader()
        reader.result = ParsedSpaces(spaces: [ParsedSpace(id: "1", ordinal: 1)], activeID: nil)
        let synth = SpySynth()
        XCTAssertFalse(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "1"))
        XCTAssertTrue(synth.keys.isEmpty)
    }

    func test_targetNotInSnapshot_returnsFalse() {
        let reader = FakeReader(); reader.result = snapshot(active: "1")
        let synth = SpySynth()
        XCTAssertFalse(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "99999"))
        XCTAssertTrue(synth.keys.isEmpty)
    }

    // MARK: - Fullscreen-app tiles in the traversal order

    /// Mirrors the real-machine capture with an app fullscreen: the type-4
    /// tile ("353") sits mid-traversal (right after the space it was entered
    /// from). It is absent from `spaces` (not a desktop) but present in
    /// `navigationIDs`, because Ctrl+←/→ hops through it.
    private func fullscreenSnapshot(active: String) -> ParsedSpaces {
        let desktops = ["3", "1", "4", "5"].enumerated()
            .map { ParsedSpace(id: $0.element, ordinal: $0.offset + 1) }
        return ParsedSpaces(spaces: desktops, activeID: active,
                            navigationIDs: ["3", "353", "1", "4", "5"])
    }

    func test_fullscreenTileBetweenSpaces_countsTheExtraHop() {
        let reader = FakeReader(); reader.result = fullscreenSnapshot(active: "3")
        let synth = SpySynth()
        // "3" → "1" is 1 desktop apart, but the tile sits between them in the
        // Ctrl+arrow traversal → 2 hops right, not 1.
        XCTAssertTrue(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "1"))
        XCTAssertEqual(synth.keys, Array(repeating: right, count: 2))
    }

    func test_activeIsFullscreenTile_switchesUsingTraversalOrder() {
        // The user is *in* the fullscreen app: activeID is the tile's MSID,
        // which is not in `spaces` — the switcher must still resolve it via
        // the traversal order. "353" (index 1) → "5" (index 4) = 3 hops right.
        let reader = FakeReader(); reader.result = fullscreenSnapshot(active: "353")
        let synth = SpySynth()
        XCTAssertTrue(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "5"))
        XCTAssertEqual(synth.keys, Array(repeating: right, count: 3))
    }

    func test_synthesizerThrowsMidSequence_returnsFalse() {
        let reader = FakeReader(); reader.result = snapshot(active: "1")  // ordinal 2
        let synth = SpySynth(); synth.throwAtCall = 3   // fail on the 3rd of 9 hops
        XCTAssertFalse(makeSwitcher(reader, synth).setCurrentSpace(managedSpaceID: "132"))
        XCTAssertEqual(synth.keys.count, 2)   // only the first two landed
    }
}
