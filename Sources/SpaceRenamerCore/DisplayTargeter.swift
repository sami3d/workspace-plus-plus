import AppKit
import CoreGraphics
import Foundation

/// Runs a Space-switching action while macOS is targeting the physical
/// display represented by a SkyLight managed-display identifier.
public protocol DisplayTargeting {
    func perform(onManagedDisplayID displayID: String, action: () -> Bool) -> Bool
}

/// macOS directs Mission Control keyboard shortcuts to the display containing
/// the pointer. Temporarily moving the pointer to the requested display makes
/// Ctrl+←/→ and Ctrl+1…9 operate on that display; the pointer is restored after
/// WindowServer has accepted the final keystroke.
public final class CGDisplayTargeter: DisplayTargeting {
    private let settleBeforeAction: () -> Void
    private let settleBeforeRestore: () -> Void

    public init(
        settleBeforeAction: @escaping () -> Void = { usleep(120_000) },
        settleBeforeRestore: @escaping () -> Void = { usleep(350_000) }
    ) {
        self.settleBeforeAction = settleBeforeAction
        self.settleBeforeRestore = settleBeforeRestore
    }

    public func perform(onManagedDisplayID displayID: String, action: () -> Bool) -> Bool {
        guard let targetDisplayID = resolveDisplayID(managedDisplayID: displayID),
              let pointer = CGEvent(source: nil)?.location else {
            return false
        }

        let bounds = CGDisplayBounds(targetDisplayID)
        guard !bounds.isEmpty else { return false }

        // Avoid moving the pointer at all for the common same-display case.
        guard !bounds.contains(pointer) else { return action() }

        let targetPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        guard CGWarpMouseCursorPosition(targetPoint) == .success else {
            return false
        }
        settleBeforeAction()
        defer {
            // Keep the target display focused until the last synthetic event
            // has been consumed, then put the pointer exactly where it was.
            settleBeforeRestore()
            CGWarpMouseCursorPosition(pointer)
        }
        return action()
    }

    private func resolveDisplayID(managedDisplayID: String) -> CGDirectDisplayID? {
        if managedDisplayID == "Main" || managedDisplayID.isEmpty {
            return CGMainDisplayID()
        }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return nil
        }

        return displayIDs.prefix(Int(count)).first { displayID in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
                return false
            }
            return (CFUUIDCreateString(nil, uuid) as String) == managedDisplayID
        }
    }
}
