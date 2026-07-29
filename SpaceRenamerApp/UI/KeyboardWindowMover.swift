import AppKit
import ApplicationServices
import SpaceRenamerCore

enum KeyboardWindowMoveError: LocalizedError {
    case applicationUnavailable
    case eventSourceUnavailable
    case mouseEventUnavailable
    case switchFailed
    case returnFailed

    var errorDescription: String? {
        switch self {
        case .applicationUnavailable:
            return "The application that owned the selected window is no longer available."
        case .eventSourceUnavailable, .mouseEventUnavailable:
            return "Workspace++ could not create the required macOS input events."
        case .switchFailed:
            return "Workspace++ could not navigate to the selected workspace."
        case .returnFailed:
            return "The window was moved, but Workspace++ could not return to the original workspace."
        }
    }
}

/// Carries a focused window through Mission Control exactly as a user would:
/// hold its title bar, switch directly through the known Space order, then
/// release. The picker remains destination-based; adjacent navigation is only
/// the internal transport required by macOS's public behaviour.
@MainActor
final class KeyboardWindowMover {
    private let switcher: SwitcherEngine
    private let activeSpaceReader: ActiveSpaceReading

    init(
        switcher: SwitcherEngine,
        activeSpaceReader: ActiveSpaceReading = SkyLightActiveSpaceReader()
    ) {
        self.switcher = switcher
        self.activeSpaceReader = activeSpaceReader
    }

    func move(
        window: FocusedWindow,
        from sourceSpaceID: String,
        to targetSpaceID: String,
        follow: Bool
    ) throws {
        guard sourceSpaceID != targetSpaceID else { return }
        guard let application = NSRunningApplication(
            processIdentifier: window.applicationPID
        ) else {
            throw KeyboardWindowMoveError.applicationUnavailable
        }
        guard let originalPointer = CGEvent(source: nil)?.location,
              let eventSource = CGEventSource(stateID: .hidSystemState) else {
            throw KeyboardWindowMoveError.eventSourceUnavailable
        }

        application.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementPerformAction(window.accessibilityElement, kAXRaiseAction as CFString)
        usleep(120_000)

        guard CGWarpMouseCursorPosition(window.dragPoint) == .success else {
            throw KeyboardWindowMoveError.mouseEventUnavailable
        }
        usleep(80_000)

        let dragStartPoint = CGPoint(x: window.dragPoint.x + 6, y: window.dragPoint.y)
        guard let mouseDown = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: window.dragPoint,
            mouseButton: .left
        ), let dragOut = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: dragStartPoint,
            mouseButton: .left
        ), let dragBack = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: window.dragPoint,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: window.dragPoint,
            mouseButton: .left
        ) else {
            CGWarpMouseCursorPosition(originalPointer)
            throw KeyboardWindowMoveError.mouseEventUnavailable
        }

        mouseDown.post(tap: .cghidEventTap)
        usleep(80_000)
        // Crossing the drag threshold is important: a mouse-down alone can
        // remain a pending title-bar click, which macOS will not carry through
        // a Space transition. Return to the original point before navigating
        // so this does not reposition the window.
        dragOut.post(tap: .cghidEventTap)
        usleep(60_000)
        dragBack.post(tap: .cghidEventTap)
        usleep(100_000)
        do {
            try navigateAndConfirm(to: targetSpaceID)
        } catch {
            mouseUp.post(tap: .cghidEventTap)
            CGWarpMouseCursorPosition(originalPointer)
            throw KeyboardWindowMoveError.switchFailed
        }

        // Let WindowServer finish the last Space animation while the title bar
        // remains held, then release the window in the destination.
        usleep(450_000)
        mouseUp.post(tap: .cghidEventTap)
        usleep(120_000)
        CGWarpMouseCursorPosition(originalPointer)

        guard !follow else { return }
        usleep(180_000)
        do {
            try navigateAndConfirm(to: sourceSpaceID)
        } catch {
            throw KeyboardWindowMoveError.returnFailed
        }
    }

    /// Space transitions can coalesce keystrokes while a title-bar drag is
    /// active. Re-read WindowServer after each attempt and keep navigating
    /// until the requested managed Space ID—not merely an intermediate
    /// desktop—is active.
    private func navigateAndConfirm(to targetSpaceID: String) throws {
        for _ in 0..<12 {
            if isStablyActive(targetSpaceID) { return }
            try switcher.switch(to: targetSpaceID)
            usleep(650_000)
        }
        guard isStablyActive(targetSpaceID) else {
            throw KeyboardWindowMoveError.switchFailed
        }
    }

    /// WindowServer updates its current-Space record before the animation and
    /// queued keyboard events have completely settled. Two matching reads
    /// prevent us from returning early and then drifting into a neighbouring
    /// Space after the mover has finished.
    private func isStablyActive(_ spaceID: String) -> Bool {
        guard isActive(spaceID) else { return false }
        usleep(300_000)
        return isActive(spaceID)
    }

    private func isActive(_ spaceID: String) -> Bool {
        guard let snapshot = activeSpaceReader.snapshot(),
              let display = snapshot.display(containingSpaceID: spaceID) else {
            return false
        }
        return display.activeID == spaceID
    }
}
