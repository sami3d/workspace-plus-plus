import Foundation

public enum MenuBarDisplayMode: String, CaseIterable, Sendable {
    /// Show each display's active Space name over that display's own menu bar.
    case perDisplay
    /// Show every display's active Space name in one shared status-item title.
    case combined

    public static let `default`: Self = .perDisplay
}
