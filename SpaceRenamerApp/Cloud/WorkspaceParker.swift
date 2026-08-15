import ApplicationServices
import CoreGraphics
import Foundation
import SpaceRenamerCore

struct WorkspaceParkResult: Sendable {
    let closedWindowCount: Int
    let skippedWindowCount: Int
}

/// Closes only AX windows whose WindowServer IDs are confirmed to belong to
/// the selected Space. Applications remain running; unsaved-document prompts
/// remain under the owning application's control.
@MainActor
final class WorkspaceParker {
    private typealias GetWindowIDFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let monitor: SpaceMonitor
    private let spaceReader = WindowSpaceReader()
    private let getWindowID: GetWindowIDFn?

    init(monitor: SpaceMonitor) {
        self.monitor = monitor
        let process = dlopen(nil, RTLD_NOW)
        getWindowID = process.flatMap { handle in
            dlsym(handle, "_AXUIElementGetWindow").map {
                unsafeBitCast($0, to: GetWindowIDFn.self)
            }
        }
    }

    func closeWindows(in storageID: String) -> WorkspaceParkResult {
        guard AXIsProcessTrusted(), let getWindowID else {
            return WorkspaceParkResult(closedWindowCount: 0, skippedWindowCount: 0)
        }
        monitor.reload()
        guard let managedSpaceID = monitor.spaces.first(where: { $0.storageID == storageID })?.id,
              let windowInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else {
            return WorkspaceParkResult(closedWindowCount: 0, skippedWindowCount: 0)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var targetsByPID: [pid_t: Set<CGWindowID>] = [:]
        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            guard pid != ownPID,
                  spaceReader.spaceIDs(for: number.intValue).contains(managedSpaceID) else { continue }
            targetsByPID[pid, default: []].insert(CGWindowID(number.uint32Value))
        }

        var closed = 0
        var skipped = 0
        for (pid, targetIDs) in targetsByPID {
            let application = AXUIElementCreateApplication(pid)
            var rawWindows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                application, kAXWindowsAttribute as CFString, &rawWindows
            ) == .success, let windows = rawWindows as? [AXUIElement] else {
                skipped += targetIDs.count
                continue
            }
            for window in windows {
                var windowID: CGWindowID = 0
                guard getWindowID(window, &windowID) == .success,
                      targetIDs.contains(windowID) else { continue }
                var rawCloseButton: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    window, kAXCloseButtonAttribute as CFString, &rawCloseButton
                ) == .success,
                      let closeButton = rawCloseButton,
                      CFGetTypeID(closeButton) == AXUIElementGetTypeID(),
                      AXUIElementPerformAction(
                        unsafeDowncast(closeButton, to: AXUIElement.self),
                        kAXPressAction as CFString
                      ) == .success else {
                    skipped += 1
                    continue
                }
                closed += 1
            }
        }
        return WorkspaceParkResult(closedWindowCount: closed, skippedWindowCount: skipped)
    }
}
