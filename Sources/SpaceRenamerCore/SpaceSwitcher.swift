import Foundation

/// Makes a Space the current one. Switching is uncapped (no 9-desktop limit):
/// see design D2 / *Design Revision 2026-05-17c*.
public protocol SpaceSwitching {
    /// Navigate so `managedSpaceID` becomes the current Space.
    ///
    /// Returns `true` iff the switch could be **attempted** (live ordinals
    /// resolved and the keystrokes were posted, or we were already there).
    /// `false` is a knowable synchronous failure (reader unavailable, id not in
    /// the live snapshot, event source unavailable). It does not assert the
    /// view finished animating — verified live on the real machine.
    func setCurrentSpace(managedSpaceID: String) -> Bool
}

/// Relative-navigation switcher. Reads the live ordered Spaces + active Space
/// from SkyLight (read-only), computes the signed ordinal delta to the target,
/// and synthesizes that many Ctrl+← / Ctrl+→ ("Move left/right a space")
/// presses. Those go through the same WindowServer symbolic-hotkey handler as
/// a real keypress, so the switch is the real animated transition — for ANY
/// number of desktops, no SIP. (The SkyLight *write* SPI it replaced only
/// rewrote bookkeeping without moving the screen — proven on a real machine;
/// see *Design Revision 2026-05-17c*.)
public final class RelativeArrowSpaceSwitcher: SpaceSwitching {
    private let reader: ActiveSpaceReading
    private let synthesizer: KeystrokeSynthesizing
    /// Pacing between consecutive arrow presses so the WindowServer animates
    /// each hop instead of coalescing them. Injectable so tests run instantly.
    private let pace: () -> Void

    public init(reader: ActiveSpaceReading = SkyLightActiveSpaceReader(),
                synthesizer: KeystrokeSynthesizing = CGKeystrokeSynthesizer(),
                pace: @escaping () -> Void = { usleep(120_000) }) {
        self.reader = reader
        self.synthesizer = synthesizer
        self.pace = pace
    }

    public func setCurrentSpace(managedSpaceID: String) -> Bool {
        // Positions come from the full Ctrl+arrow traversal order, NOT the
        // desktops-only list: "Move left/right a space" hops through
        // fullscreen tiles too, and the active space may *be* one (switching
        // out of a fullscreen app must still work).
        guard let snap = reader.snapshot(),
              let display = snap.display(containingSpaceID: managedSpaceID),
              let activeID = display.activeID,
              let from = display.navigationIDs.firstIndex(of: activeID),
              let to = display.navigationIDs.firstIndex(of: managedSpaceID) else {
            return false
        }

        let delta = to - from
        guard delta != 0 else { return true }   // already on the target Space

        let keyCode = delta > 0
            ? CGKeystrokeSynthesizer.rightArrowKeyCode
            : CGKeystrokeSynthesizer.leftArrowKeyCode
        let steps = abs(delta)
        for step in 1...steps {
            do {
                try synthesizer.postControlKey(keyCode)
            } catch {
                return false
            }
            if step < steps { pace() }
        }
        return true
    }
}

/// `Ctrl+1…9` ("Switch to Desktop N") switcher — a single instant keystroke,
/// but macOS only defines those hotkeys for desktops 1–9, so it returns
/// `false` for any higher ordinal (the menu greys those rows in this mode).
/// Selected via `SwitchMode.ctrlDigit` (see *Design Revision 2026-05-18*).
public final class CtrlDigitSpaceSwitcher: SpaceSwitching {
    private let reader: ActiveSpaceReading
    private let synthesizer: KeystrokeSynthesizing

    public init(reader: ActiveSpaceReading = SkyLightActiveSpaceReader(),
                synthesizer: KeystrokeSynthesizing = CGKeystrokeSynthesizer()) {
        self.reader = reader
        self.synthesizer = synthesizer
    }

    public func setCurrentSpace(managedSpaceID: String) -> Bool {
        guard let snap = reader.snapshot(),
              let ordinal = snap.spaces.first(where: { $0.id == managedSpaceID })?.ordinal,
              (1...9).contains(ordinal) else { return false }   // Ctrl+1…9 only
        do {
            try synthesizer.postControlDigit(ordinal)
        } catch {
            return false
        }
        return true
    }
}

/// Routes each switch to the arrow or Ctrl+digit switcher based on the
/// user-selected `SwitchMode`. The mode is read **per call**, so flipping the
/// Preferences setting takes effect on the next switch — no relaunch.
public final class ModeRoutingSpaceSwitcher: SpaceSwitching {
    private let arrow: SpaceSwitching
    private let ctrlDigit: SpaceSwitching
    private let mode: () -> SwitchMode

    public init(arrow: SpaceSwitching = RelativeArrowSpaceSwitcher(),
                ctrlDigit: SpaceSwitching = CtrlDigitSpaceSwitcher(),
                mode: @escaping () -> SwitchMode) {
        self.arrow = arrow
        self.ctrlDigit = ctrlDigit
        self.mode = mode
    }

    public func setCurrentSpace(managedSpaceID: String) -> Bool {
        switch mode() {
        case .arrow:     return arrow.setCurrentSpace(managedSpaceID: managedSpaceID)
        case .ctrlDigit: return ctrlDigit.setCurrentSpace(managedSpaceID: managedSpaceID)
        }
    }
}
