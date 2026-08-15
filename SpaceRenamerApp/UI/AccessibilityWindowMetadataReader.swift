import ApplicationServices
import Foundation

struct AccessibilityWindowMetadata {
    let title: String
    let document: String?
    let isMinimized: Bool
}

/// Reads the portable document/page locator exposed by an application's
/// accessibility window. Many document-based and Electron applications put a
/// file URL or web URL in AXDocument even when the WindowServer title alone is
/// not enough to restore the content.
final class AccessibilityWindowMetadataReader {
    private typealias GetWindowIDFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private let getWindowID: GetWindowIDFn?

    init() {
        let process = dlopen(nil, RTLD_NOW)
        getWindowID = process.flatMap { handle in
            dlsym(handle, "_AXUIElementGetWindow").map {
                unsafeBitCast($0, to: GetWindowIDFn.self)
            }
        }
    }

    func metadata(for pid: pid_t) -> [Int: AccessibilityWindowMetadata] {
        guard AXIsProcessTrusted(), let getWindowID else { return [:] }
        let application = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &rawWindows
        ) == .success, let windows = rawWindows as? [AXUIElement] else { return [:] }

        var result: [Int: AccessibilityWindowMetadata] = [:]
        for window in windows {
            var windowID: CGWindowID = 0
            guard getWindowID(window, &windowID) == .success, windowID > 0 else { continue }
            result[Int(windowID)] = AccessibilityWindowMetadata(
                title: string(kAXTitleAttribute as CFString, from: window) ?? "",
                document: string(kAXDocumentAttribute as CFString, from: window),
                isMinimized: boolean(kAXMinimizedAttribute as CFString, from: window) ?? false
            )
        }
        return result
    }

    private func string(_ attribute: CFString, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw as? String, !value.isEmpty else { return nil }
        return value
    }

    private func boolean(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let value = raw as? NSNumber else { return nil }
        return value.boolValue
    }
}

