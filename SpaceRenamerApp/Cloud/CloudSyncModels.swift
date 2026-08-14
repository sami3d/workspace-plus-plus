import Foundation
import SpaceRenamerCore

struct CloudWorkspaceRecord: Codable, Equatable, Sendable {
    let storageID: String
    let name: String?
    let colorHex: String?
    let categoryID: String?
    let displayID: String
    let displayName: String
    let displayOrdinal: Int
    let spaceOrdinal: Int
    let modifiedAt: Date

    // JSONDecoder's convertFromSnakeCase strategy normalizes `storage_id`
    // to `storageId`, not `storageID`. Keep Swift's preferred acronym casing
    // while explicitly matching the normalized JSON keys.
    private enum CodingKeys: String, CodingKey {
        case storageID = "storageId"
        case name
        case colorHex
        case categoryID = "categoryId"
        case displayID = "displayId"
        case displayName
        case displayOrdinal
        case spaceOrdinal
        case modifiedAt
    }

    var slotKey: String { "\(displayOrdinal):\(spaceOrdinal)" }
}

struct CloudWorkspaceSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let capturedAt: Date
    let workspaces: [CloudWorkspaceRecord]
    let categories: [WorkspaceCategory]

    init(
        version: Int = currentVersion,
        capturedAt: Date = Date(),
        workspaces: [CloudWorkspaceRecord],
        categories: [WorkspaceCategory] = []
    ) {
        self.version = version
        self.capturedAt = capturedAt
        self.workspaces = workspaces
        self.categories = categories
    }

    private enum CodingKeys: String, CodingKey {
        case version, capturedAt, workspaces, categories
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        capturedAt = try values.decodeIfPresent(Date.self, forKey: .capturedAt) ?? .distantPast
        workspaces = try values.decode([CloudWorkspaceRecord].self, forKey: .workspaces)
        categories = try values.decodeIfPresent([WorkspaceCategory].self, forKey: .categories) ?? []
    }
}

struct CloudProfile: Codable, Equatable, Sendable {
    let snapshot: CloudWorkspaceSnapshot
    let sourceDeviceID: UUID
    let updatedAt: Date
}

struct CloudSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: UUID
    let email: String

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case userID = "userId"
        case email
    }
}

enum CloudSyncState: Equatable, Sendable {
    case unavailable(String)
    case signedOut(String?)
    case syncing(email: String)
    case signedIn(email: String, lastSync: Date?)
    case failed(email: String?, message: String)

    var email: String? {
        switch self {
        case .syncing(let email), .signedIn(let email, _): return email
        case .failed(let email, _): return email
        case .unavailable, .signedOut: return nil
        }
    }
}
