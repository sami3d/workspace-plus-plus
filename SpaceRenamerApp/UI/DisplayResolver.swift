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

    /// True when `screen` is the display `managedDisplayID` refers to. Mirrors
    /// `screen(for:)`, including its `"Main"` alias, so callers can test a
    /// screen against a snapshot's display id without relying on NSScreen
    /// object identity (AppKit hands out fresh instances after reconfigures).
    static func matches(_ screen: NSScreen, managedDisplayID: String) -> Bool {
        if managedDisplayID == "Main" {
            return directDisplayID(for: screen) == CGMainDisplayID()
        }
        return displayUUID(for: screen).caseInsensitiveCompare(managedDisplayID) == .orderedSame
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
