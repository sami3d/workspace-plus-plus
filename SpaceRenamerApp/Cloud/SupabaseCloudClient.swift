import Foundation

actor SupabaseCloudClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case emailConfirmationRequired
        case noSession
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Cloud sync is not configured in this build."
            case .emailConfirmationRequired:
                return "Check your email to confirm the account, then sign in."
            case .noSession: return "Sign in to use cloud sync."
            case .invalidResponse: return "The cloud returned an invalid response."
            case .server(let message): return message
            }
        }
    }

    private struct AuthUser: Decodable {
        let id: UUID
        let email: String?
    }

    private struct AuthResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: TimeInterval?
        let expiresAt: TimeInterval?
        let user: AuthUser?
    }

    private struct ErrorResponse: Decodable {
        let message: String?
        let msg: String?
        let errorDescription: String?
        let error: String?
    }

    private struct ProfileRow: Decodable {
        let snapshot: CloudWorkspaceSnapshot
        let sourceDeviceID: UUID
        let updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case snapshot
            case sourceDeviceID = "sourceDeviceId"
            case updatedAt
        }
    }

    private struct ProfileWrite: Encodable {
        let userID: UUID
        let snapshot: CloudWorkspaceSnapshot
        let sourceDeviceID: UUID
        let updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case userID = "userId"
            case snapshot
            case sourceDeviceID = "sourceDeviceId"
            case updatedAt
        }
    }

    private struct DeviceWrite: Encodable {
        let userID: UUID
        let deviceID: UUID
        let name: String
        let model: String
        let operatingSystem: String
        let appVersion: String
        let lastSeenAt: Date

        private enum CodingKeys: String, CodingKey {
            case userID = "userId"
            case deviceID = "deviceId"
            case name, model, operatingSystem, appVersion, lastSeenAt
        }
    }

    private struct SessionWrite: Encodable {
        let id: UUID
        let userID: UUID
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
            case userID = "userId"
            case deviceID = "deviceId"
            case deviceName, workspaceKey, contentHash, snapshot, capturedAt, updatedAt, deletedAt
        }
    }

    private struct SessionDeletion: Encodable {
        let deletedAt: Date
    }

    private struct LibraryWorkspaceWrite: Encodable {
        let id: UUID
        let userID: UUID
        let name: String
        let categoryName: String?
        let colorHex: String?
        let currentRevisionID: UUID
        let isArchived: Bool
        let updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case id, name, categoryName, colorHex, isArchived, updatedAt
            case userID = "userId"
            case currentRevisionID = "currentRevisionId"
        }
    }

    private struct LibraryInstanceWrite: Encodable {
        let id: UUID
        let userID: UUID
        let workspaceID: UUID
        let deviceID: UUID
        let localWorkspaceKey: String?
        let displayName: String?
        let displayOrdinal: Int?
        let spaceOrdinal: Int?
        let status: CloudWorkspaceInstanceStatus
        let headRevisionID: UUID
        let lastSeenAt: Date
        let updatedAt: Date
        let deletedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case id, localWorkspaceKey, displayName, displayOrdinal, spaceOrdinal
            case status, lastSeenAt, updatedAt, deletedAt
            case userID = "userId"
            case workspaceID = "workspaceId"
            case deviceID = "deviceId"
            case headRevisionID = "headRevisionId"
        }
    }

    private struct LibraryRevisionWrite: Encodable {
        let id: UUID
        let userID: UUID
        let workspaceID: UUID
        let instanceID: UUID
        let parentRevisionID: UUID?
        let sourceDeviceID: UUID
        let contentHash: String
        let snapshot: WorkspaceSessionSnapshot
        let createdAt: Date

        private enum CodingKeys: String, CodingKey {
            case id, contentHash, snapshot, createdAt
            case userID = "userId"
            case workspaceID = "workspaceId"
            case instanceID = "instanceId"
            case parentRevisionID = "parentRevisionId"
            case sourceDeviceID = "sourceDeviceId"
        }
    }

    private struct InstanceStatePatch: Encodable {
        let status: CloudWorkspaceInstanceStatus
        let localWorkspaceKey: String?
        let updatedAt: Date
    }

    private struct TransferWrite: Encodable {
        let id: UUID
        let userID: UUID
        let workspaceID: UUID
        let revisionID: UUID
        let sourceInstanceID: UUID?
        let sourceDeviceID: UUID
        let destinationDeviceID: UUID?
        let mode: CloudWorkspaceTransferMode
        let status: CloudWorkspaceTransferStatus
        let createdAt: Date

        private enum CodingKeys: String, CodingKey {
            case id, mode, status, createdAt
            case userID = "userId"
            case workspaceID = "workspaceId"
            case revisionID = "revisionId"
            case sourceInstanceID = "sourceInstanceId"
            case sourceDeviceID = "sourceDeviceId"
            case destinationDeviceID = "destinationDeviceId"
        }
    }

    private struct TransferCompletionPatch: Encodable {
        let status: CloudWorkspaceTransferStatus
        let destinationInstanceID: UUID
        let acceptedAt: Date
        let completedAt: Date

        private enum CodingKeys: String, CodingKey {
            case status, acceptedAt, completedAt
            case destinationInstanceID = "destinationInstanceId"
        }
    }

    private struct LibraryDeletionPatch: Encodable {
        let deletedAt: Date
        let updatedAt: Date
    }

    private let configuration: CloudConfiguration
    private var session: CloudSession?

    init(configuration: CloudConfiguration, session: CloudSession?) {
        self.configuration = configuration
        self.session = session
    }

    func restoredSession() -> CloudSession? { session }

    func restoreSession(_ restoredSession: CloudSession?) {
        session = restoredSession
    }

    func signUp(email: String, password: String) async throws -> CloudSession {
        let response: AuthResponse = try await authRequest(
            path: "auth/v1/signup",
            body: ["email": email, "password": password]
        )
        guard response.accessToken != nil else {
            throw ClientError.emailConfirmationRequired
        }
        return try persist(response: response, fallbackEmail: email)
    }

    func signIn(email: String, password: String) async throws -> CloudSession {
        let response: AuthResponse = try await authRequest(
            path: "auth/v1/token?grant_type=password",
            body: ["email": email, "password": password]
        )
        return try persist(response: response, fallbackEmail: email)
    }

    func signOut() async {
        if let session {
            var request = makeRequest(path: "auth/v1/logout", method: "POST")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        session = nil
        try? CloudKeychain.deleteSession()
    }

    func fetchProfile() async throws -> CloudProfile? {
        let session = try await validSession()
        var components = URLComponents(
            url: configuration.projectURL
                .appendingPathComponent("rest/v1/workspace_profiles"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "snapshot,source_device_id,updated_at"),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAPIHeaders(to: &request, accessToken: session.accessToken)
        let data = try await perform(request)
        let rows = try JSONDecoder.cloud.decode([ProfileRow].self, from: data)
        guard let row = rows.first else { return nil }
        return CloudProfile(
            snapshot: row.snapshot,
            sourceDeviceID: row.sourceDeviceID,
            updatedAt: row.updatedAt
        )
    }

    func saveProfile(
        snapshot: CloudWorkspaceSnapshot,
        deviceID: UUID
    ) async throws -> CloudProfile {
        let session = try await validSession()
        var request = makeRequest(
            path: "rest/v1/workspace_profiles?on_conflict=user_id",
            method: "POST"
        )
        addAPIHeaders(to: &request, accessToken: session.accessToken)
        request.setValue(
            "resolution=merge-duplicates,return=representation",
            forHTTPHeaderField: "Prefer"
        )
        let updatedAt = Date()
        request.httpBody = try JSONEncoder.cloud.encode(ProfileWrite(
            userID: session.userID,
            snapshot: snapshot,
            sourceDeviceID: deviceID,
            updatedAt: updatedAt
        ))
        let data = try await perform(request)
        let rows = try JSONDecoder.cloud.decode([ProfileRow].self, from: data)
        guard let row = rows.first else { throw ClientError.invalidResponse }
        return CloudProfile(
            snapshot: row.snapshot,
            sourceDeviceID: row.sourceDeviceID,
            updatedAt: row.updatedAt
        )
    }

    func registerDevice(_ device: CloudWorkspaceDevice) async throws {
        let session = try await validSession()
        var request = makeRequest(
            path: "rest/v1/workspace_devices?on_conflict=user_id,device_id",
            method: "POST"
        )
        addAPIHeaders(to: &request, accessToken: session.accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder.cloud.encode(DeviceWrite(
            userID: session.userID,
            deviceID: device.deviceID,
            name: device.name,
            model: device.model,
            operatingSystem: device.operatingSystem,
            appVersion: device.appVersion,
            lastSeenAt: device.lastSeenAt
        ))
        _ = try await perform(request)
    }

    func saveWorkspaceSessions(
        _ snapshots: [(id: UUID, hash: String, snapshot: WorkspaceSessionSnapshot)],
        device: CloudWorkspaceDevice
    ) async throws {
        guard !snapshots.isEmpty else { return }
        let session = try await validSession()
        let now = Date()
        let rows = snapshots.map {
            SessionWrite(
                id: $0.id,
                userID: session.userID,
                deviceID: device.deviceID,
                deviceName: device.name,
                workspaceKey: $0.snapshot.workspaceKey,
                contentHash: $0.hash,
                snapshot: $0.snapshot,
                capturedAt: $0.snapshot.capturedAt,
                updatedAt: now,
                deletedAt: nil
            )
        }
        var request = makeRequest(
            path: "rest/v1/workspace_sessions?on_conflict=user_id,device_id,workspace_key",
            method: "POST"
        )
        addAPIHeaders(to: &request, accessToken: session.accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder.cloud.encode(rows)
        _ = try await perform(request)
    }

    func fetchWorkspaceSessions() async throws -> [CloudWorkspaceHistoryItem] {
        let session = try await validSession()
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("rest/v1/workspace_sessions"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,device_id,device_name,workspace_key,content_hash,snapshot,captured_at,updated_at,deleted_at"
            ),
            URLQueryItem(name: "order", value: "captured_at.desc"),
        ]
        guard let url = components?.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAPIHeaders(to: &request, accessToken: session.accessToken)
        let data = try await perform(request)
        return try JSONDecoder.cloud.decode([CloudWorkspaceHistoryItem].self, from: data)
    }

    func deleteWorkspaceSession(id: UUID) async throws {
        try await deleteWorkspaceSessions(ids: [id])
    }

    func deleteWorkspaceSessions(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let session = try await validSession()
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("rest/v1/workspace_sessions"),
            resolvingAgainstBaseURL: false
        )
        let values = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
        components?.queryItems = [
            URLQueryItem(name: "id", value: "in.(\(values))")
        ]
        guard let url = components?.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        addAPIHeaders(to: &request, accessToken: session.accessToken)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder.cloud.encode(SessionDeletion(deletedAt: Date()))
        _ = try await perform(request)
    }

    func saveLibraryRevision(
        workspaceID: UUID,
        instanceID: UUID,
        revisionID: UUID,
        parentRevisionID: UUID?,
        contentHash: String,
        snapshot: WorkspaceSessionSnapshot,
        device: CloudWorkspaceDevice,
        status: CloudWorkspaceInstanceStatus
    ) async throws {
        let auth = try await validSession()
        let now = Date()
        try await registerDevice(device)
        try await upsert(
            table: "cloud_workspaces",
            conflict: "id",
            value: LibraryWorkspaceWrite(
                id: workspaceID,
                userID: auth.userID,
                name: snapshot.workspaceName,
                categoryName: snapshot.categoryName,
                colorHex: snapshot.colorHex,
                currentRevisionID: revisionID,
                isArchived: status == .parked,
                updatedAt: now
            ),
            accessToken: auth.accessToken
        )
        try await upsert(
            table: "workspace_instances",
            conflict: "id",
            value: LibraryInstanceWrite(
                id: instanceID,
                userID: auth.userID,
                workspaceID: workspaceID,
                deviceID: device.deviceID,
                localWorkspaceKey: status == .parked ? nil : snapshot.workspaceKey,
                displayName: snapshot.displayName,
                displayOrdinal: snapshot.displayOrdinal,
                spaceOrdinal: snapshot.spaceOrdinal,
                status: status,
                headRevisionID: revisionID,
                lastSeenAt: now,
                updatedAt: now,
                deletedAt: nil
            ),
            accessToken: auth.accessToken
        )
        try await upsert(
            table: "workspace_revisions",
            conflict: "id",
            value: LibraryRevisionWrite(
                id: revisionID,
                userID: auth.userID,
                workspaceID: workspaceID,
                instanceID: instanceID,
                parentRevisionID: parentRevisionID,
                sourceDeviceID: device.deviceID,
                contentHash: contentHash,
                snapshot: snapshot,
                createdAt: snapshot.capturedAt
            ),
            accessToken: auth.accessToken
        )
    }

    func fetchWorkspaceLibrary() async throws -> WorkspaceLibrary {
        let auth = try await validSession()
        async let workspaces: [CloudLibraryWorkspace] = fetchRows(
            table: "cloud_workspaces",
            select: "id,name,category_name,color_hex,current_revision_id,is_archived,created_at,updated_at,deleted_at",
            order: "updated_at.desc",
            userID: auth.userID,
            accessToken: auth.accessToken
        )
        async let instances: [CloudWorkspaceInstance] = fetchRows(
            table: "workspace_instances",
            select: "id,workspace_id,device_id,local_workspace_key,display_name,display_ordinal,space_ordinal,status,head_revision_id,last_seen_at,created_at,updated_at,deleted_at",
            order: "updated_at.desc",
            userID: auth.userID,
            accessToken: auth.accessToken
        )
        async let revisions: [CloudWorkspaceRevision] = fetchRows(
            table: "workspace_revisions",
            select: "id,workspace_id,instance_id,parent_revision_id,source_device_id,content_hash,snapshot,created_at",
            order: "created_at.desc",
            userID: auth.userID,
            accessToken: auth.accessToken
        )
        async let transfers: [CloudWorkspaceTransfer] = fetchRows(
            table: "workspace_transfers",
            select: "id,workspace_id,revision_id,source_instance_id,source_device_id,destination_device_id,destination_instance_id,mode,status,created_at,accepted_at,completed_at,cancelled_at",
            order: "created_at.desc",
            userID: auth.userID,
            accessToken: auth.accessToken
        )
        async let devices: [CloudWorkspaceDevice] = fetchRows(
            table: "workspace_devices",
            select: "device_id,name,model,operating_system,app_version,last_seen_at",
            order: "last_seen_at.desc",
            userID: auth.userID,
            accessToken: auth.accessToken
        )
        return try await WorkspaceLibrary(
            workspaces: workspaces,
            instances: instances,
            revisions: revisions,
            transfers: transfers,
            devices: devices
        )
    }

    func setInstanceState(
        id: UUID,
        status: CloudWorkspaceInstanceStatus,
        localWorkspaceKey: String?
    ) async throws {
        let auth = try await validSession()
        var request = makeRequest(
            path: "rest/v1/workspace_instances?id=eq.\(id.uuidString.lowercased())&user_id=eq.\(auth.userID.uuidString.lowercased())",
            method: "PATCH"
        )
        addAPIHeaders(to: &request, accessToken: auth.accessToken)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder.cloud.encode(InstanceStatePatch(
            status: status,
            localWorkspaceKey: localWorkspaceKey,
            updatedAt: Date()
        ))
        _ = try await perform(request)
    }

    func createTransfer(
        workspaceID: UUID,
        revisionID: UUID,
        sourceInstanceID: UUID?,
        sourceDeviceID: UUID,
        destinationDeviceID: UUID?,
        mode: CloudWorkspaceTransferMode
    ) async throws {
        let auth = try await validSession()
        try await upsert(
            table: "workspace_transfers",
            conflict: "id",
            value: TransferWrite(
                id: UUID(),
                userID: auth.userID,
                workspaceID: workspaceID,
                revisionID: revisionID,
                sourceInstanceID: sourceInstanceID,
                sourceDeviceID: sourceDeviceID,
                destinationDeviceID: destinationDeviceID,
                mode: mode,
                status: .pending,
                createdAt: Date()
            ),
            accessToken: auth.accessToken
        )
    }

    func completeTransfer(id: UUID, destinationInstanceID: UUID) async throws {
        let auth = try await validSession()
        let now = Date()
        var request = makeRequest(
            path: "rest/v1/workspace_transfers?id=eq.\(id.uuidString.lowercased())&user_id=eq.\(auth.userID.uuidString.lowercased())",
            method: "PATCH"
        )
        addAPIHeaders(to: &request, accessToken: auth.accessToken)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder.cloud.encode(TransferCompletionPatch(
            status: .completed,
            destinationInstanceID: destinationInstanceID,
            acceptedAt: now,
            completedAt: now
        ))
        _ = try await perform(request)
    }

    func deleteLibraryWorkspace(id: UUID) async throws {
        let auth = try await validSession()
        let now = Date()
        var request = makeRequest(
            path: "rest/v1/cloud_workspaces?id=eq.\(id.uuidString.lowercased())&user_id=eq.\(auth.userID.uuidString.lowercased())",
            method: "PATCH"
        )
        addAPIHeaders(to: &request, accessToken: auth.accessToken)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder.cloud.encode(
            LibraryDeletionPatch(deletedAt: now, updatedAt: now)
        )
        _ = try await perform(request)
    }

    private func upsert<T: Encodable>(
        table: String,
        conflict: String,
        value: T,
        accessToken: String
    ) async throws {
        var request = makeRequest(
            path: "rest/v1/\(table)?on_conflict=\(conflict)",
            method: "POST"
        )
        addAPIHeaders(to: &request, accessToken: accessToken)
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder.cloud.encode(value)
        _ = try await perform(request)
    }

    private func fetchRows<T: Decodable>(
        table: String,
        select: String,
        order: String,
        userID: UUID,
        accessToken: String
    ) async throws -> [T] {
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: select),
            URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: order),
        ]
        guard let url = components?.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAPIHeaders(to: &request, accessToken: accessToken)
        return try JSONDecoder.cloud.decode([T].self, from: await perform(request))
    }

    private func authRequest<T: Decodable>(
        path: String,
        body: [String: String]
    ) async throws -> T {
        var request = makeRequest(path: path, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        return try JSONDecoder.cloud.decode(T.self, from: data)
    }

    private func validSession() async throws -> CloudSession {
        guard let existing = session else { throw ClientError.noSession }
        if existing.expiresAt.timeIntervalSinceNow > 60 { return existing }
        do {
            let response: AuthResponse = try await authRequest(
                path: "auth/v1/token?grant_type=refresh_token",
                body: ["refresh_token": existing.refreshToken]
            )
            return try persist(response: response, fallbackEmail: existing.email)
        } catch ClientError.server(let message)
            where message.localizedCaseInsensitiveContains("refresh token") {
            // A password/account action or session rotation on another Mac can
            // invalidate this installation's refresh token. Clear only the
            // stale local credential so Preferences can offer sign-in again.
            session = nil
            try? CloudKeychain.deleteSession()
            throw ClientError.noSession
        }
    }

    private func persist(
        response: AuthResponse,
        fallbackEmail: String
    ) throws -> CloudSession {
        guard
            let accessToken = response.accessToken,
            let refreshToken = response.refreshToken,
            let userID = response.user?.id
        else { throw ClientError.invalidResponse }
        let expiry = response.expiresAt.map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(response.expiresIn ?? 3600)
        let newSession = CloudSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiry,
            userID: userID,
            email: response.user?.email ?? fallbackEmail
        )
        try CloudKeychain.saveSession(newSession)
        session = newSession
        return newSession
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let pieces = path.split(separator: "?", maxSplits: 1).map(String.init)
        var components = URLComponents(
            url: configuration.projectURL.appendingPathComponent(pieces[0]),
            resolvingAgainstBaseURL: false
        )
        if pieces.count == 2 { components?.percentEncodedQuery = pieces[1] }
        // Every call site supplies a static, valid path rooted at a validated
        // project URL, so this fallback cannot occur in a configured build.
        let url = components?.url
            ?? configuration.projectURL.appendingPathComponent(pieces[0])
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func addAPIHeaders(to request: inout URLRequest, accessToken: String) {
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder.cloud.decode(ErrorResponse.self, from: data)
            let message = decoded?.message
                ?? decoded?.msg
                ?? decoded?.errorDescription
                ?? decoded?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ClientError.server(message)
        }
        return data
    }
}
