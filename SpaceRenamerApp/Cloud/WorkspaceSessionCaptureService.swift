import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SpaceRenamerCore

@MainActor
final class WorkspaceSessionCaptureService {
    private struct RawWindow {
        let number: Int
        let pid: pid_t
        let bundleIdentifier: String
        let applicationName: String
        let title: String
        let bounds: WorkspaceWindowBounds
        let isOnScreen: Bool
        let spaceIDs: [String]
        let resource: WorkspaceResourceLocator?
    }

    private let monitor: SpaceMonitor
    private let names: NameStore
    private let spaceReader = WindowSpaceReader()
    private let accessibilityReader = AccessibilityWindowMetadataReader()
    private let chrome = ChromeSessionAdapter()

    init(monitor: SpaceMonitor, names: NameStore) {
        self.monitor = monitor
        self.names = names
    }

    func captureAll() async -> WorkspaceSessionCaptureResult {
        monitor.reload()
        let rawWindows = readWindows()
        let chromeWindows: [CapturedChromeWindow]
        let warnings: [String]
        do {
            chromeWindows = try await chrome.capture()
            warnings = []
        } catch {
            chromeWindows = []
            warnings = ["Chrome tabs could not be read: \(error.localizedDescription)"]
        }
        let chromeByWindowNumber = matchChromeWindows(chromeWindows, to: rawWindows)
        let capturedAt = Date()

        let snapshots = monitor.spaces.map { space in
            let display = monitor.displays.first { $0.id == space.displayID }
            let displayOrdinal = display?.ordinal ?? 1
            let windows = rawWindows.filter { $0.spaceIDs.contains(space.id) }
            let grouped = Dictionary(grouping: windows, by: \.bundleIdentifier)
            let applications = grouped.map { bundleID, appWindows in
                makeApplication(
                    bundleID: bundleID,
                    windows: appWindows,
                    chromeByWindowNumber: chromeByWindowNumber
                )
            }.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            return WorkspaceSessionSnapshot(
                workspaceKey: space.storageID,
                workspaceName: names.name(
                    for: space.storageID,
                    defaultOrdinal: space.ordinal
                ),
                categoryName: names.category(for: space.storageID)?.name,
                colorHex: names.colorHex(for: space.storageID),
                displayName: DisplayResolver.name(
                    for: space.displayID,
                    ordinal: displayOrdinal
                ),
                displayOrdinal: displayOrdinal,
                spaceOrdinal: space.ordinal,
                capturedAt: capturedAt,
                applications: applications
            )
        }
        return WorkspaceSessionCaptureResult(snapshots: snapshots, warnings: warnings)
    }

    func contentHash(for snapshot: WorkspaceSessionSnapshot) -> String {
        // capturedAt is deliberately excluded: an unchanged workspace should
        // not generate cloud writes every five minutes.
        struct HashableContent: Encodable {
            let workspaceName: String
            let categoryName: String?
            let colorHex: String?
            let applications: [WorkspaceCapturedApplication]
        }
        let content = HashableContent(
            workspaceName: snapshot.workspaceName,
            categoryName: snapshot.categoryName,
            colorHex: snapshot.colorHex,
            applications: snapshot.applications
        )
        let data = (try? JSONEncoder.cloud.encode(content)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readWindows() -> [RawWindow] {
        guard let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = Set(info.compactMap {
            ($0[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) }
        })
        let accessibilityByPID = Dictionary(uniqueKeysWithValues: pids.map {
            ($0, accessibilityReader.metadata(for: $0))
        })

        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60 else { return nil }
            let pid = pid_t(pidNumber.int32Value)
            guard pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { return nil }
            let bundleID = app.bundleIdentifier ?? "pid:\(pid)"
            let metadata = accessibilityByPID[pid]?[number]
            let title = metadata?.title
                ?? (window[kCGWindowName as String] as? String)
                ?? ""
            return RawWindow(
                number: number,
                pid: pid,
                bundleIdentifier: bundleID,
                applicationName: app.localizedName
                    ?? (window[kCGWindowOwnerName as String] as? String)
                    ?? "Application",
                title: title,
                bounds: WorkspaceWindowBounds(
                    x: bounds.origin.x,
                    y: bounds.origin.y,
                    width: bounds.width,
                    height: bounds.height
                ),
                isOnScreen: (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
                    ?? !(metadata?.isMinimized ?? false),
                spaceIDs: spaceReader.spaceIDs(for: number),
                resource: resourceLocator(from: metadata?.document)
            )
        }
    }

    private func resourceLocator(from rawValue: String?) -> WorkspaceResourceLocator? {
        guard let rawValue, let url = URL(string: rawValue), let scheme = url.scheme else {
            return nil
        }
        let kind: WorkspaceResourceLocator.Kind
        switch scheme.lowercased() {
        case "http", "https": kind = .webURL
        case "file": kind = .fileURL
        default: kind = .appURL
        }
        return WorkspaceResourceLocator(kind: kind, value: rawValue)
    }

    private func makeApplication(
        bundleID: String,
        windows: [RawWindow],
        chromeByWindowNumber: [Int: CapturedChromeWindow]
    ) -> WorkspaceCapturedApplication {
        let sorted = windows.sorted { $0.number < $1.number }
        let capturedWindows = sorted.enumerated().map { index, window in
            if let chromeWindow = chromeByWindowNumber[window.number] {
                let tabs = chromeWindow.tabs.enumerated().map { tabIndex, tab in
                    WorkspaceBrowserTab(
                        id: tab.id,
                        index: tabIndex,
                        title: tab.title,
                        url: tab.url,
                        isActive: tabIndex + 1 == chromeWindow.activeTabIndex,
                        isPinned: nil,
                        groupTitle: nil,
                        groupColor: nil
                    )
                }
                return WorkspaceCapturedWindow(
                    id: chromeWindow.id,
                    index: index,
                    title: chromeWindow.title,
                    bounds: window.bounds,
                    isOnScreen: window.isOnScreen,
                    confidence: .exact,
                    resource: tabs.first(where: \.isActive).map {
                        WorkspaceResourceLocator(kind: .webURL, value: $0.url)
                    },
                    tabs: tabs
                )
            }
            return WorkspaceCapturedWindow(
                id: String(window.number),
                index: index,
                title: window.title,
                bounds: window.bounds,
                isOnScreen: window.isOnScreen,
                confidence: window.resource == nil ? .appOnly : .bestEffort,
                resource: window.resource,
                tabs: []
            )
        }
        let confidence: WorkspaceCaptureConfidence
        if bundleID == "com.google.Chrome", capturedWindows.contains(where: { !$0.tabs.isEmpty }) {
            confidence = .exact
        } else if capturedWindows.contains(where: { $0.resource != nil }) {
            confidence = .bestEffort
        } else {
            confidence = .appOnly
        }
        return WorkspaceCapturedApplication(
            bundleIdentifier: bundleID,
            name: sorted.first?.applicationName ?? bundleID,
            confidence: confidence,
            windows: capturedWindows
        )
    }

    private func matchChromeWindows(
        _ chromeWindows: [CapturedChromeWindow],
        to rawWindows: [RawWindow]
    ) -> [Int: CapturedChromeWindow] {
        let candidates = rawWindows.filter { $0.bundleIdentifier == "com.google.Chrome" }
        var unused = candidates
        var result: [Int: CapturedChromeWindow] = [:]
        for chromeWindow in chromeWindows where chromeWindow.mode != "incognito" {
            let left = chromeWindow.bounds.x
            let top = chromeWindow.bounds.y
            let width = chromeWindow.bounds.width
            let height = chromeWindow.bounds.height
            guard let match = unused.min(by: {
                matchScore($0, title: chromeWindow.title, x: left, y: top,
                           width: width, height: height)
                    < matchScore($1, title: chromeWindow.title, x: left, y: top,
                                 width: width, height: height)
            }) else { continue }
            result[match.number] = chromeWindow
            unused.removeAll { $0.number == match.number }
        }
        return result
    }

    private func matchScore(
        _ window: RawWindow,
        title: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) -> Double {
        let geometry = abs(window.bounds.x - x) + abs(window.bounds.y - y)
            + abs(window.bounds.width - width) + abs(window.bounds.height - height)
        return geometry + (window.title == title ? 0 : 10_000)
    }
}
