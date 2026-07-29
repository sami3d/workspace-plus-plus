import AppKit
import ApplicationServices

struct FocusedWindow {
    let windowNumber: Int
    let applicationPID: pid_t
    let applicationName: String
    let title: String
    let accessibilityElement: AXUIElement
    let dragPoint: CGPoint
    let managedDisplayID: String?
    let spaceIDs: [String]
}

final class FocusedWindowResolver {
    private typealias GetWindowIDFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let getWindowID: GetWindowIDFn?
    private let windowSpaceReader: WindowSpaceReader

    init(windowSpaceReader: WindowSpaceReader = WindowSpaceReader()) {
        self.windowSpaceReader = windowSpaceReader
        let process = dlopen(nil, RTLD_NOW)
        getWindowID = process.flatMap { handle in
            dlsym(handle, "_AXUIElementGetWindow").map {
                unsafeBitCast($0, to: GetWindowIDFn.self)
            }
        }
    }

    func focusedWindow() -> FocusedWindow? {
        guard AXIsProcessTrusted(), let getWindowID else { return nil }

        let systemWide = AXUIElementCreateSystemWide()

        var applicationValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &applicationValue
        ) == .success, let applicationValue else {
            return nil
        }
        let application = unsafeDowncast(applicationValue, to: AXUIElement.self)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else {
            return nil
        }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)

        var fullScreenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            "AXFullScreen" as CFString,
            &fullScreenValue
        ) == .success, let fullScreenValue {
            if (fullScreenValue as? NSNumber)?.boolValue == true {
                return nil
            }
        }

        var windowID: CGWindowID = 0
        guard getWindowID(window, &windowID) == .success, windowID > 0 else {
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        var titleValue: CFTypeRef?
        let title: String
        if AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleValue
        ) == .success, let titleValue {
            title = titleValue as? String ?? ""
        } else {
            title = ""
        }

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
            ?? "Focused application"
        guard let dragPoint = draggableTitleBarPoint(for: window) else {
            return nil
        }
        return FocusedWindow(
            windowNumber: Int(windowID),
            applicationPID: pid,
            applicationName: appName,
            title: title,
            accessibilityElement: window,
            dragPoint: dragPoint,
            managedDisplayID: managedDisplayID(containing: dragPoint),
            spaceIDs: windowSpaceReader.spaceIDs(for: Int(windowID))
        )
    }

    private func draggableTitleBarPoint(for window: AXUIElement) -> CGPoint? {
        var zoomButtonValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXZoomButtonAttribute as CFString,
            &zoomButtonValue
        ) == .success, let zoomButtonValue {
            let zoomButton = unsafeDowncast(zoomButtonValue, to: AXUIElement.self)
            if let position = pointAttribute(kAXPositionAttribute as CFString, of: zoomButton),
               let size = sizeAttribute(kAXSizeAttribute as CFString, of: zoomButton) {
                return CGPoint(
                    x: position.x + size.width + 8,
                    y: position.y + size.height / 2
                )
            }
        }

        guard let position = pointAttribute(kAXPositionAttribute as CFString, of: window),
              let size = sizeAttribute(kAXSizeAttribute as CFString, of: window) else {
            return nil
        }
        return CGPoint(x: position.x + min(max(100, size.width / 2), size.width - 20),
                       y: position.y + 12)
    }

    private func pointAttribute(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(
            unsafeDowncast(value, to: AXValue.self),
            .cgPoint,
            &point
        ) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(
            unsafeDowncast(value, to: AXValue.self),
            .cgSize,
            &size
        ) else { return nil }
        return size
    }

    private func managedDisplayID(containing point: CGPoint) -> String? {
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return nil
        }
        var displayID = CGDirectDisplayID()
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount) == .success,
              displayCount > 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
