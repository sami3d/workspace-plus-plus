import Foundation

/// How application windows are represented beside a workspace name.
public enum AppIconWindowMode: String, CaseIterable, Sendable {
    /// One icon per application, regardless of its number of windows.
    case iconsOnly
    /// One icon per application with its window count beside it.
    case windowCounters
    /// Repeat an application's icon once for every open window.
    case repeatedIcons

    public static let `default`: Self = .windowCounters
}
