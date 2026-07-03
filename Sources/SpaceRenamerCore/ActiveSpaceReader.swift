import Foundation

/// Reads a live snapshot of the ordered Spaces + the active Space id from the
/// window server. macOS does not keep `com.apple.spaces.plist`'s `Current
/// Space`/`Spaces` live (see design D2 / Revisions 2026-05-17), so the source
/// is the read-only private SkyLight SPI.
public protocol ActiveSpaceReading {
    /// Live ordered Spaces + active id, or `nil` if unavailable.
    func snapshot() -> ParsedSpaces?
}

/// Read-only private SkyLight implementation. Resolves the SPI via `dlsym`
/// (no link-time dependency on a private framework). Verified live on a real
/// machine. The single private-SPI call site in the codebase.
public final class SkyLightActiveSpaceReader: ActiveSpaceReading {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private let mainConn: MainConnFn?
    private let copyDisplaySpaces: CopyDisplaySpacesFn?

    public init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let mc = dlsym(handle, "CGSMainConnectionID"),
              let cds = dlsym(handle, "CGSCopyManagedDisplaySpaces") else {
            self.mainConn = nil
            self.copyDisplaySpaces = nil
            return
        }
        self.mainConn = unsafeBitCast(mc, to: MainConnFn.self)
        self.copyDisplaySpaces = unsafeBitCast(cds, to: CopyDisplaySpacesFn.self)
    }

    public func snapshot() -> ParsedSpaces? {
        guard let mainConn, let copyDisplaySpaces else { return nil }
        guard let unmanaged = copyDisplaySpaces(mainConn()) else { return nil }
        // CGSCopy… returns a +1 retain; takeRetainedValue() hands it to ARC,
        // which releases it on scope exit regardless of the casts below.
        let displays = unmanaged.takeRetainedValue()
        guard let array = displays as? [[String: Any]], let primary = array.first else { return nil }
        let rawSpaces = (primary["Spaces"] as? [[String: Any]]) ?? []
        var navigationIDs: [String] = []
        var spaces: [ParsedSpace] = []
        for dict in rawSpaces {
            guard let msid = dict["ManagedSpaceID"] as? Int, msid > 0 else { continue }
            navigationIDs.append(String(msid))
            // User desktops only (`type == 0`; absent ⇒ desktop). Fullscreen
            // tiles (`type == 4`) are transient, inserted mid-array, and not
            // nameable — they stay in `navigationIDs` for Ctrl+arrow hop
            // counting but must not become menu rows / overlay banners.
            guard (dict["type"] as? Int ?? 0) == 0 else { continue }
            let uuid = (dict["uuid"] as? String) ?? ""
            spaces.append(ParsedSpace(id: String(msid), ordinal: spaces.count + 1, uuid: uuid))
        }
        guard !spaces.isEmpty else { return nil }
        let activeMSID = (primary["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
        return ParsedSpaces(spaces: spaces, activeID: activeMSID.map(String.init),
                            navigationIDs: navigationIDs)
    }
}
