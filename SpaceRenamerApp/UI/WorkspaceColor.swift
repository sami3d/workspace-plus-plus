import AppKit

enum WorkspaceColor {
    static let defaultHex = "3A3A40"

    static func color(from hex: String?) -> NSColor {
        let value = hex ?? defaultHex
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return color(from: defaultHex)
        }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    static func hex(from color: NSColor) -> String {
        guard let converted = color.usingColorSpace(.sRGB) else {
            return defaultHex
        }
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    static func readableTextColor(on background: NSColor) -> NSColor {
        guard let converted = background.usingColorSpace(.sRGB) else {
            return .white
        }
        // Relative luminance approximation tuned for UI contrast.
        let luminance = 0.2126 * converted.redComponent
            + 0.7152 * converted.greenComponent
            + 0.0722 * converted.blueComponent
        return luminance > 0.58 ? .black : .white
    }
}
