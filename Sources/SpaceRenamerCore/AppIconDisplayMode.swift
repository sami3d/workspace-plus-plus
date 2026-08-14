import Foundation

/// Horizontal alignment for application icons in the workspace status menu.
public enum AppIconDisplayMode: String, CaseIterable, Sendable {
    /// Icons begin in a fixed column after the workspace name.
    case leftAligned
    /// Icons are packed against the right edge of the menu row.
    case rightAligned

    public static let `default`: Self = .leftAligned
}
