import Foundation

/// Controls how application icons are ordered in each workspace menu row.
/// Count-based modes use application name A–Z as their deterministic tie-break.
public enum AppIconSortMode: String, CaseIterable, Sendable {
    /// Rank an app by its total number of windows across every Space.
    case globalWindowCount
    /// Rank an app by its number of windows in the row's Space.
    case workspaceWindowCount
    /// Ignore window counts and order applications by name.
    case alphabetical

    public static let `default`: Self = .globalWindowCount
}
