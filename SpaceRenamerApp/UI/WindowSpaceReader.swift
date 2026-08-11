import Foundation

/// Read-only WindowServer lookup for the managed Space IDs containing a
/// window. This is more reliable than inferring the source Space from the
/// window's screen, especially when each display has separate Spaces.
final class WindowSpaceReader {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn =
        @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let mainConnection: MainConnectionFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?

    init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_NOW
        ) else {
            mainConnection = nil
            copySpacesForWindows = nil
            return
        }

        let mainSymbol = dlsym(handle, "SLSMainConnectionID")
            ?? dlsym(handle, "CGSMainConnectionID")
        let copySymbol = dlsym(handle, "SLSCopySpacesForWindows")
            ?? dlsym(handle, "CGSCopySpacesForWindows")
        mainConnection = mainSymbol.map {
            unsafeBitCast($0, to: MainConnectionFn.self)
        }
        copySpacesForWindows = copySymbol.map {
            unsafeBitCast($0, to: CopySpacesForWindowsFn.self)
        }
    }

    func spaceIDs(for windowNumber: Int) -> [String] {
        guard windowNumber > 0, let mainConnection, let copySpacesForWindows,
              let result = copySpacesForWindows(
                mainConnection(),
                0x7,
                [NSNumber(value: windowNumber)] as CFArray
              ) else {
            return []
        }
        return (result.takeRetainedValue() as? [NSNumber] ?? [])
            .map { $0.stringValue }
    }
}
