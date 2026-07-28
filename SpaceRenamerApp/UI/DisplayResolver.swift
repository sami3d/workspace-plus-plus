import AppKit
import CoreGraphics

enum DisplayResolver {
    static func screen(for managedDisplayID: String) -> NSScreen? {
        if managedDisplayID == "Main" {
            return NSScreen.screens.first(where: { directDisplayID(for: $0) == CGMainDisplayID() })
                ?? NSScreen.main
        }
        return NSScreen.screens.first {
            displayUUID(for: $0).caseInsensitiveCompare(managedDisplayID) == .orderedSame
        }
    }

    static func name(for managedDisplayID: String, ordinal: Int) -> String {
        screen(for: managedDisplayID)?.localizedName
            ?? (managedDisplayID == "Main" ? "Main Display" : "Display \(ordinal)")
    }

    static func managedDisplayID(for screen: NSScreen) -> String? {
        displayUUID(for: screen)
    }

    private static func directDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func displayUUID(for screen: NSScreen) -> String {
        guard let id = directDisplayID(for: screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
