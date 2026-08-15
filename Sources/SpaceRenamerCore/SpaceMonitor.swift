import AppKit
import Combine
import os

@MainActor public final class SpaceMonitor {
    @Published public private(set) var spaces: [ParsedSpace] = []
    @Published public private(set) var activeID: String?
    @Published public private(set) var displays: [ParsedDisplay] = []
    @Published public private(set) var activeIDsByDisplay: [String: String] = [:]

    /// `nil` when the last `reload()` succeeded. When non-nil, the most recent
    /// plist read/parse failed and `spaces`/`activeID` retain their previous
    /// (possibly empty) values — the UI can keep showing stale data while
    /// indicating a degraded state. Phase B renders the spec'd degraded
    /// fallback (plain "Desktop N" rows) when this is set.
    @Published public private(set) var lastLoadError: String?

    private static let logger = Logger(subsystem: "SpaceRenamerCore", category: "SpaceMonitor")

    private let plistURL: URL
    private let activeReader: ActiveSpaceReading
    // `nonisolated(unsafe)` is the documented escape hatch for properties of
    // non-`Sendable` types on a `@MainActor` class that must be touched from a
    // `nonisolated deinit`. Here it's accurate: the observer is only ever
    // mutated from the main actor in `init`, and the `deinit` access happens
    // at single-threaded ARC tear-down.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    public init(plistURL: URL? = nil, activeSpaceReader: ActiveSpaceReading = SkyLightActiveSpaceReader()) {
        self.plistURL = plistURL
            ?? FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/com.apple.spaces.plist")
        self.activeReader = activeSpaceReader
        reload()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // WindowServer can deliver this notification before a keyboard-driven
            // Space animation has committed its final active Space. Refresh more
            // than once so menu-bar and Raycast state cannot remain on the source
            // Space until the next Mission Control mouse click.
            Task { @MainActor in self?.refreshAfterSpaceChange() }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Refresh from the live SkyLight snapshot (ordered Spaces + active id).
    /// Falls back to the (lazily-written) plist only if SkyLight is
    /// unavailable, in which case `lastLoadError` reflects the plist read.
    public func reload() {
        if let snap = activeReader.snapshot() {
            self.spaces = snap.spaces
            self.activeID = snap.activeID
            self.displays = snap.displays
            self.activeIDsByDisplay = snap.activeIDsByDisplay
            self.lastLoadError = nil
            return
        }
        // Degraded fallback: SkyLight unavailable — read the plist.
        CFPreferencesAppSynchronize("com.apple.spaces" as CFString)
        do {
            let data = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
            let parsed = try SpacesPlistParser.parse(plist)
            self.spaces = parsed.spaces
            self.activeID = parsed.activeID
            self.displays = parsed.displays
            self.activeIDsByDisplay = parsed.activeIDsByDisplay
            self.lastLoadError = nil
        } catch {
            let description = String(describing: error)
            self.lastLoadError = description
            Self.logger.error("SpaceMonitor: failed to read plist: \(description, privacy: .public)")
        }
    }

    /// Re-read active Space state across the short WindowServer transition.
    /// When a target is supplied (for a switch initiated by Workspace++), stop
    /// as soon as that Space is observed. External switches use all passes.
    public func refreshAfterSpaceChange(targetID: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let delays: [UInt64] = [0, 120_000_000, 220_000_000, 400_000_000,
                                    700_000_000, 1_000_000_000]
            for delay in delays {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled else { return }
                self.reload()
                if let targetID,
                   self.activeIDsByDisplay.values.contains(targetID) {
                    return
                }
            }
        }
    }

    public func ordinal(for id: String) -> Int? {
        spaces.first(where: { $0.id == id })?.ordinal
    }
}
