import AppKit
import CoreGraphics
import SpaceRenamerCore

struct SpaceApplicationSummary {
    let identifier: String
    let name: String
    let icon: NSImage
    let windowCount: Int
}

/// Builds a lightweight, on-demand application/window index for the native
/// workspace menu. WindowServer provides owner + window number; the existing
/// SkyLight reader resolves each window number to its managed Space.
@MainActor
final class SpaceApplicationIndex {
    private struct MutableSummary {
        let identifier: String
        let name: String
        let icon: NSImage
        var windowCount: Int
    }

    private let spaceReader = WindowSpaceReader()

    func summariesBySpace(
        sortMode: AppIconSortMode,
        leastUsedFirst: Bool = false
    ) -> [String: [SpaceApplicationSummary]] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            .optionAll,
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var grouped: [String: [String: MutableSummary]] = [:]
        var globalWindowCounts: [String: Int] = [:]

        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  number > 0,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }

            let pid = pid_t(pidNumber.int32Value)
            guard pid != ownPID,
                  hasUsefulSize(info[kCGWindowBounds as String]),
                  let application = NSRunningApplication(processIdentifier: pid),
                  application.activationPolicy == .regular,
                  let icon = application.icon
            else { continue }

            let identifier = application.bundleIdentifier ?? "pid:\(pid)"
            let name = application.localizedName
                ?? (info[kCGWindowOwnerName as String] as? String)
                ?? "Application"
            let spaceIDs = Set(spaceReader.spaceIDs(for: number))
            guard !spaceIDs.isEmpty else { continue }
            // Count each physical window once globally, even if macOS reports
            // it on multiple Spaces (for example, an app assigned to all
            // desktops).
            globalWindowCounts[identifier, default: 0] += 1

            for spaceID in spaceIDs {
                var applications = grouped[spaceID] ?? [:]
                if var existing = applications[identifier] {
                    existing.windowCount += 1
                    applications[identifier] = existing
                } else {
                    applications[identifier] = MutableSummary(
                        identifier: identifier,
                        name: name,
                        icon: icon,
                        windowCount: 1
                    )
                }
                grouped[spaceID] = applications
            }
        }

        return grouped.mapValues { applications in
            applications.values
                .map {
                    SpaceApplicationSummary(
                        identifier: $0.identifier,
                        name: $0.name,
                        icon: $0.icon,
                        windowCount: $0.windowCount
                    )
                }
                .sorted { lhs, rhs in
                    switch sortMode {
                    case .globalWindowCount:
                        let lhsCount = globalWindowCounts[lhs.identifier, default: 0]
                        let rhsCount = globalWindowCounts[rhs.identifier, default: 0]
                        if lhsCount != rhsCount {
                            return leastUsedFirst ? lhsCount < rhsCount : lhsCount > rhsCount
                        }
                    case .workspaceWindowCount:
                        if lhs.windowCount != rhs.windowCount {
                            return leastUsedFirst
                                ? lhs.windowCount < rhs.windowCount
                                : lhs.windowCount > rhs.windowCount
                        }
                    case .alphabetical:
                        break
                    }
                    let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                    return lhs.identifier.localizedCaseInsensitiveCompare(rhs.identifier)
                        == .orderedAscending
                }
        }
    }

    private func hasUsefulSize(_ rawBounds: Any?) -> Bool {
        guard let bounds = rawBounds as? [String: Any],
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else { return true }
        // Exclude invisible bookkeeping, tooltip, and zero-sized windows while
        // retaining ordinary compact utility windows.
        return width >= 80 && height >= 60
    }
}
