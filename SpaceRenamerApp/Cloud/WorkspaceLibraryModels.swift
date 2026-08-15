import Foundation

enum CloudWorkspaceInstanceStatus: String, Codable, CaseIterable, Sendable {
    case loaded
    case focused
    case parked
    case pendingMove = "pending_move"
    case stale
}

enum CloudWorkspaceTransferMode: String, Codable, Sendable {
    case copy
    case move
}

enum CloudWorkspaceTransferStatus: String, Codable, Sendable {
    case pending
    case accepted
    case completed
    case cancelled
    case failed
}

struct CloudLibraryWorkspace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let categoryName: String?
    let colorHex: String?
    let currentRevisionID: UUID?
    let isArchived: Bool
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, categoryName, colorHex, isArchived, createdAt, updatedAt, deletedAt
        case currentRevisionID = "currentRevisionId"
    }
}

struct CloudWorkspaceInstance: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let deviceID: UUID
    let localWorkspaceKey: String?
    let displayName: String?
    let displayOrdinal: Int?
    let spaceOrdinal: Int?
    let status: CloudWorkspaceInstanceStatus
    let headRevisionID: UUID?
    let lastSeenAt: Date
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, localWorkspaceKey, displayName, displayOrdinal, spaceOrdinal
        case status, lastSeenAt, createdAt, updatedAt, deletedAt
        case workspaceID = "workspaceId"
        case deviceID = "deviceId"
        case headRevisionID = "headRevisionId"
    }
}

struct CloudWorkspaceRevision: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let instanceID: UUID?
    let parentRevisionID: UUID?
    let sourceDeviceID: UUID
    let contentHash: String
    let snapshot: WorkspaceSessionSnapshot
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, contentHash, snapshot, createdAt
        case workspaceID = "workspaceId"
        case instanceID = "instanceId"
        case parentRevisionID = "parentRevisionId"
        case sourceDeviceID = "sourceDeviceId"
    }
}

struct CloudWorkspaceTransfer: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let revisionID: UUID
    let sourceInstanceID: UUID?
    let sourceDeviceID: UUID
    let destinationDeviceID: UUID?
    let destinationInstanceID: UUID?
    let mode: CloudWorkspaceTransferMode
    let status: CloudWorkspaceTransferStatus
    let createdAt: Date
    let acceptedAt: Date?
    let completedAt: Date?
    let cancelledAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, mode, status, createdAt, acceptedAt, completedAt, cancelledAt
        case workspaceID = "workspaceId"
        case revisionID = "revisionId"
        case sourceInstanceID = "sourceInstanceId"
        case sourceDeviceID = "sourceDeviceId"
        case destinationDeviceID = "destinationDeviceId"
        case destinationInstanceID = "destinationInstanceId"
    }
}

struct WorkspaceLibrary: Equatable, Sendable {
    var workspaces: [CloudLibraryWorkspace] = []
    var instances: [CloudWorkspaceInstance] = []
    var revisions: [CloudWorkspaceRevision] = []
    var transfers: [CloudWorkspaceTransfer] = []
    var devices: [CloudWorkspaceDevice] = []

    func instances(for workspaceID: UUID) -> [CloudWorkspaceInstance] {
        instances.filter { $0.workspaceID == workspaceID && $0.deletedAt == nil }
    }

    func latestRevision(for workspace: CloudLibraryWorkspace) -> CloudWorkspaceRevision? {
        if let current = workspace.currentRevisionID,
           let exact = revisions.first(where: { $0.id == current }) { return exact }
        return revisions.filter { $0.workspaceID == workspace.id }
            .max { $0.createdAt < $1.createdAt }
    }
}
