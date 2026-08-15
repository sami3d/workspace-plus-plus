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
        let response: AuthResponse = try await authRequest(
            path: "auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": existing.refreshToken]
        )
        return try persist(response: response, fallbackEmail: existing.email)
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
