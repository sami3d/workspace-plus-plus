import Foundation

enum WorkspaceCaptureConfidence: String, Codable, Sendable {
    case exact
    case bestEffort
    case appOnly
}

struct WorkspaceWindowBounds: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct WorkspaceResourceLocator: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case webURL
        case fileURL
        case appURL
    }

    let kind: Kind
    let value: String
}

struct WorkspaceBrowserTab: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let index: Int
    let title: String
    let url: String
    let isActive: Bool
    let isPinned: Bool?
    let groupKey: String?
    let groupTitle: String?
    let groupColor: String?
    let groupCollapsed: Bool?

    init(
        id: String,
        index: Int,
        title: String,
        url: String,
        isActive: Bool,
        isPinned: Bool?,
        groupKey: String? = nil,
        groupTitle: String?,
        groupColor: String?,
        groupCollapsed: Bool? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.url = url
        self.isActive = isActive
        self.isPinned = isPinned
        self.groupKey = groupKey
        self.groupTitle = groupTitle
        self.groupColor = groupColor
        self.groupCollapsed = groupCollapsed
    }
}

struct WorkspaceCapturedWindow: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let index: Int
    let title: String
    let bounds: WorkspaceWindowBounds
    let isOnScreen: Bool
    let confidence: WorkspaceCaptureConfidence
    let resource: WorkspaceResourceLocator?
    let tabs: [WorkspaceBrowserTab]
}

struct WorkspaceCapturedApplication: Codable, Equatable, Sendable, Identifiable {
    var id: String { bundleIdentifier }

    let bundleIdentifier: String
    let name: String
    let confidence: WorkspaceCaptureConfidence
    let windows: [WorkspaceCapturedWindow]
}

/// A portable description of one macOS Space at one point in time. Runtime
/// window numbers and managed Space IDs are intentionally excluded: neither
/// survives a restart or exists on the destination Mac.
struct WorkspaceSessionSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let workspaceKey: String
    let workspaceName: String
    let categoryName: String?
    let colorHex: String?
    let displayName: String
    let displayOrdinal: Int
    let spaceOrdinal: Int
    let capturedAt: Date
    let applications: [WorkspaceCapturedApplication]

    init(
        version: Int = currentVersion,
        workspaceKey: String,
        workspaceName: String,
        categoryName: String?,
        colorHex: String?,
        displayName: String,
        displayOrdinal: Int,
        spaceOrdinal: Int,
        capturedAt: Date = Date(),
        applications: [WorkspaceCapturedApplication]
    ) {
        self.version = version
        self.workspaceKey = workspaceKey
        self.workspaceName = workspaceName
        self.categoryName = categoryName
        self.colorHex = colorHex
        self.displayName = displayName
        self.displayOrdinal = displayOrdinal
        self.spaceOrdinal = spaceOrdinal
        self.capturedAt = capturedAt
        self.applications = applications
    }

    var totalWindowCount: Int {
        applications.reduce(0) { $0 + $1.windows.count }
    }

    var totalTabCount: Int {
        applications.reduce(0) { partial, application in
            partial + application.windows.reduce(0) { $0 + $1.tabs.count }
        }
    }
}

struct CloudWorkspaceDevice: Codable, Equatable, Sendable, Identifiable {
    var id: UUID { deviceID }

    let deviceID: UUID
    let name: String
    let model: String
    let operatingSystem: String
    let appVersion: String
    let lastSeenAt: Date

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case name, model, operatingSystem, appVersion, lastSeenAt
    }
}

struct CloudWorkspaceHistoryItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let deviceID: UUID
    let deviceName: String
    let workspaceKey: String
    let contentHash: String
    let snapshot: WorkspaceSessionSnapshot
    let capturedAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case deviceID = "deviceId"
        case deviceName, workspaceKey, contentHash, snapshot, capturedAt, updatedAt, deletedAt
    }
}

struct WorkspaceSessionCaptureResult: Sendable {
    let snapshots: [WorkspaceSessionSnapshot]
    let warnings: [String]
}
