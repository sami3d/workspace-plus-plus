import Combine
import CryptoKit
import Darwin
import Foundation
import SpaceRenamerCore

@MainActor
final class CloudSyncManager: ObservableObject {
    @Published private(set) var state: CloudSyncState
    @Published private(set) var workspaceHistory: [CloudWorkspaceHistoryItem] = []
    @Published private(set) var historyStatus = "Workspace history has not been loaded."
    @Published private(set) var workspaceHistoryEnabled: Bool

    private let monitor: SpaceMonitor
    private let names: NameStore
    private let client: SupabaseCloudClient?
    private let deviceID: UUID
    private let sessionCapture: WorkspaceSessionCaptureService
    private let defaults: UserDefaults

    private var cancellables: Set<AnyCancellable> = []
    // Notification tokens are created and mutated on the main actor. ARC may
    // invoke `deinit` from a nonisolated context, so this mirrors the Core
    // monitor's documented teardown escape hatch.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var bootstrapTask: Task<Void, Never>?
    private var pendingSyncTask: Task<Void, Never>?
    private var historyLoopTask: Task<Void, Never>?
    private var historyCaptureTask: Task<Void, Never>?
    private var workspaceHistoryRows: [CloudWorkspaceHistoryItem] = []
    private var hasBootstrapped = false
    private var isApplyingCloud = false
    private var lastSuccessfulSync: Date?

    init(monitor: SpaceMonitor, names: NameStore, defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.names = names
        self.defaults = defaults
        self.workspaceHistoryEnabled = defaults.bool(
            forKey: "SpaceRenamer.workspaceHistoryEnabled"
        )
        self.sessionCapture = WorkspaceSessionCaptureService(monitor: monitor, names: names)
        let key = "SpaceRenamer.cloudDeviceID"
        if let stored = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            deviceID = stored
        } else {
            let generated = UUID()
            defaults.set(generated.uuidString, forKey: key)
            deviceID = generated
        }

        if let configuration = CloudConfiguration.bundled() {
            client = SupabaseCloudClient(
                configuration: configuration,
                session: nil
            )
            state = .signedOut(nil)
        } else {
            client = nil
            state = .unavailable("Cloud sync is being connected to the Workspace++ service.")
        }

        subscribeToLocalChanges()
    }

    deinit {
        bootstrapTask?.cancel()
        pendingSyncTask?.cancel()
        historyLoopTask?.cancel()
        historyCaptureTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isConfigured: Bool { client != nil }

    func start() {
        guard let client else { return }
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            // This may display macOS's Keychain authorization dialog. Keeping
            // it out of init lets AppDelegate create and publish the menu-bar
            // item before any system prompt can pause startup.
            let storedSession = await Task.detached(priority: .utility) {
                try? CloudKeychain.loadSession()
            }.value
            await client.restoreSession(storedSession)
            if let session = await client.restoredSession() {
                state = .syncing(email: session.email)
                await synchronize(email: session.email)
                await beginWorkspaceHistorySync()
            } else {
                state = .signedOut(nil)
                historyStatus = "Sign in under Cloud Sync to save or review workspace sessions."
                hasBootstrapped = true
            }
        }
    }

    func createAccount(email: String, password: String) async {
        guard let client else { return }
        do {
            let session = try await client.signUp(
                email: normalizedEmail(email),
                password: password
            )
            state = .syncing(email: session.email)
            await synchronize(email: session.email)
            await beginWorkspaceHistorySync()
        } catch SupabaseCloudClient.ClientError.emailConfirmationRequired {
            state = .signedOut("Check your email to confirm the account, then sign in.")
        } catch {
            state = .failed(email: nil, message: error.localizedDescription)
        }
    }

    func signIn(email: String, password: String) async {
        guard let client else { return }
        do {
            let session = try await client.signIn(
                email: normalizedEmail(email),
                password: password
            )
            state = .syncing(email: session.email)
            await synchronize(email: session.email)
            await beginWorkspaceHistorySync()
        } catch {
            state = .failed(email: nil, message: error.localizedDescription)
        }
    }

    func signOut() async {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        historyLoopTask?.cancel()
        historyLoopTask = nil
        historyCaptureTask?.cancel()
        historyCaptureTask = nil
        workspaceHistory = []
        workspaceHistoryRows = []
        historyStatus = "Sign in to view saved workspace sessions."
        if let client { await client.signOut() }
        hasBootstrapped = true
        state = .signedOut(nil)
    }

    func syncNow() async {
        guard let email = state.email else { return }
        state = .syncing(email: email)
        await synchronize(email: email)
    }

    func captureWorkspaceHistoryNow() async {
        guard workspaceHistoryEnabled else {
            historyStatus = "Turn on Workspace History before saving app, window and tab details."
            return
        }
        guard state.email != nil else {
            historyStatus = "Sign in to save workspace sessions."
            return
        }
        historyCaptureTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await captureAndUploadWorkspaceHistory()
        }
        historyCaptureTask = task
        await task.value
        historyCaptureTask = nil
    }

    func refreshWorkspaceHistory() async {
        guard let client, state.email != nil else { return }
        do {
            workspaceHistoryRows = try await client.fetchWorkspaceSessions()
            workspaceHistory = workspaceHistoryRows.filter { $0.deletedAt == nil }
            historyStatus = workspaceHistory.isEmpty
                ? "No workspace sessions have been saved yet."
                : "\(workspaceHistory.count) saved workspace session\(workspaceHistory.count == 1 ? "" : "s")."
        } catch {
            historyStatus = error.localizedDescription
        }
    }

    func deleteWorkspaceHistory(id: UUID) async {
        guard let client, state.email != nil else { return }
        do {
            try await client.deleteWorkspaceSession(id: id)
            workspaceHistory.removeAll { $0.id == id }
            if let index = workspaceHistoryRows.firstIndex(where: { $0.id == id }) {
                let old = workspaceHistoryRows[index]
                workspaceHistoryRows[index] = CloudWorkspaceHistoryItem(
                    id: old.id,
                    deviceID: old.deviceID,
                    deviceName: old.deviceName,
                    workspaceKey: old.workspaceKey,
                    contentHash: old.contentHash,
                    snapshot: old.snapshot,
                    capturedAt: old.capturedAt,
                    updatedAt: old.updatedAt,
                    deletedAt: Date()
                )
            }
            historyStatus = "Deleted. It stays hidden across laptops until that workspace changes."
        } catch {
            historyStatus = error.localizedDescription
        }
    }

    func setWorkspaceHistoryEnabled(_ enabled: Bool) {
        workspaceHistoryEnabled = enabled
        defaults.set(enabled, forKey: "SpaceRenamer.workspaceHistoryEnabled")
        if enabled, state.email != nil {
            Task { await beginWorkspaceHistorySync() }
        } else {
            historyLoopTask?.cancel()
            historyLoopTask = nil
            historyCaptureTask?.cancel()
            historyCaptureTask = nil
            historyStatus = state.email == nil
                ? "Sign in to view saved workspace sessions."
                : "Automatic Workspace History saving is off. Existing cloud sessions remain available."
        }
    }

    /// Explicit cloud-authoritative restore. Workspace identity is matched
    /// first, then monitor order + workspace order for a different Mac.
    func restoreFromCloud() async {
        guard let client, let email = state.email else { return }
        state = .syncing(email: email)
        do {
            guard let profile = try await client.fetchProfile() else {
                state = .failed(email: email, message: "No cloud backup exists yet.")
                return
            }
            names.applyCloudCategories(profile.snapshot.categories)
            apply(records: profile.snapshot.workspaces)
            hasBootstrapped = true
            state = .signedIn(email: email, lastSync: profile.updatedAt)
        } catch {
            state = .failed(email: email, message: error.localizedDescription)
        }
    }

    private func subscribeToLocalChanges() {
        monitor.$spaces
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleAutomaticSync() }
            .store(in: &cancellables)

        for notificationName in [
            Notification.Name.spaceRenamerNameDidChange,
            Notification.Name.spaceRenamerColorDidChange,
            Notification.Name.spaceRenamerCategoriesDidChange,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleAutomaticSync() }
            }
            observers.append(observer)
        }
    }

    private func beginWorkspaceHistorySync() async {
        await refreshWorkspaceHistory()
        historyLoopTask?.cancel()
        guard workspaceHistoryEnabled else {
            historyStatus = workspaceHistory.isEmpty
                ? "Automatic Workspace History saving is off."
                : "Automatic saving is off · \(workspaceHistory.count) existing session\(workspaceHistory.count == 1 ? "" : "s") available."
            return
        }
        historyLoopTask = Task { [weak self] in
            // Give launch, Chrome, and WindowServer a moment to settle before
            // the first capture. Afterwards, five minutes is frequent enough
            // for recovery without turning normal tab churn into constant
            // network writes. Content hashes suppress unchanged uploads.
            do { try await Task.sleep(for: .seconds(20)) }
            catch { return }
            while let self, !Task.isCancelled {
                await self.captureWorkspaceHistoryNow()
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
            }
        }
    }

    private func captureAndUploadWorkspaceHistory() async {
        guard let client else { return }
        historyStatus = "Capturing applications, windows and browser tabs…"
        let capture = await sessionCapture.captureAll()
        let existing = Dictionary(
            workspaceHistoryRows
                .filter { $0.deviceID == deviceID }
                .map { ($0.workspaceKey, $0.contentHash) },
            uniquingKeysWith: { _, latest in latest }
        )
        let changed = capture.snapshots.compactMap { snapshot
            -> (id: UUID, hash: String, snapshot: WorkspaceSessionSnapshot)? in
            let hash = sessionCapture.contentHash(for: snapshot)
            guard existing[snapshot.workspaceKey] != hash else { return nil }
            return (
                stableSessionID(workspaceKey: snapshot.workspaceKey),
                hash,
                snapshot
            )
        }
        do {
            let device = currentDevice()
            try await client.registerDevice(device)
            try await client.saveWorkspaceSessions(changed, device: device)
            await refreshWorkspaceHistory()
            if changed.isEmpty {
                historyStatus = "Everything is current · checked \(Date().formatted(date: .omitted, time: .shortened))."
            }
            if !capture.warnings.isEmpty {
                historyStatus += " " + capture.warnings.joined(separator: " ")
            }
        } catch {
            historyStatus = error.localizedDescription
        }
    }

    private func currentDevice() -> CloudWorkspaceDevice {
        CloudWorkspaceDevice(
            deviceID: deviceID,
            name: Host.current().localizedName ?? "Mac",
            model: hardwareModel(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "Development",
            lastSeenAt: Date()
        )
    }

    private func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Mac"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return "Mac"
        }
        let content = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: content, as: UTF8.self)
    }

    private func stableSessionID(workspaceKey: String) -> UUID {
        let digest = SHA256.hash(
            data: Data("\(deviceID.uuidString.lowercased()):\(workspaceKey)".utf8)
        )
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func scheduleAutomaticSync() {
        guard hasBootstrapped, !isApplyingCloud, state.email != nil else { return }
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }

            // The debounce phase is complete. Clear its handle before the
            // network request starts so cloud-application notifications cannot
            // cancel the active sync by cancelling `pendingSyncTask`.
            pendingSyncTask = nil
            await self.syncNow()
        }
    }

    private func synchronize(email: String) async {
        guard let client else { return }
        do {
            let local = currentRecords()
            let remote = try await client.fetchProfile()
            let mergedCategories = mergeCategories(remote?.snapshot.categories ?? [])
            names.applyCloudCategories(mergedCategories)
            let merged: [CloudWorkspaceRecord]
            if let remote {
                merged = merge(local: local, remote: remote)
            } else {
                merged = promoteLegacyRecords(local)
            }
            apply(records: merged)
            let snapshot = CloudWorkspaceSnapshot(
                workspaces: merged,
                categories: names.allCategoryRecords
            )
            let saved = try await client.saveProfile(
                snapshot: snapshot,
                deviceID: deviceID
            )
            hasBootstrapped = true
            lastSuccessfulSync = saved.updatedAt
            state = .signedIn(email: email, lastSync: saved.updatedAt)
        } catch where isCancellation(error) {
            // A superseded debounce, sign-out, or shutdown is normal control
            // flow and must never appear as a cloud account failure.
            hasBootstrapped = true
            state = .signedIn(email: email, lastSync: lastSuccessfulSync)
        } catch SupabaseCloudClient.ClientError.noSession {
            pendingSyncTask?.cancel()
            historyLoopTask?.cancel()
            historyCaptureTask?.cancel()
            workspaceHistory = []
            workspaceHistoryRows = []
            hasBootstrapped = true
            state = .signedOut("Your cloud session expired. Sign in again.")
        } catch {
            hasBootstrapped = true
            state = .failed(email: email, message: error.localizedDescription)
        }
    }

    private func currentRecords() -> [CloudWorkspaceRecord] {
        let displayOrdinals = Dictionary(
            uniqueKeysWithValues: monitor.displays.map { ($0.id, $0.ordinal) }
        )
        return monitor.spaces.map { space in
            let displayOrdinal = displayOrdinals[space.displayID] ?? 1
            return CloudWorkspaceRecord(
                storageID: space.storageID,
                name: names.storedName(for: space.storageID),
                colorHex: names.colorHex(for: space.storageID),
                categoryID: names.categoryID(for: space.storageID),
                displayID: space.displayID,
                displayName: DisplayResolver.name(
                    for: space.displayID,
                    ordinal: displayOrdinal
                ),
                displayOrdinal: displayOrdinal,
                spaceOrdinal: space.ordinal,
                modifiedAt: normalizedDate(
                    names.workspaceModifiedAt(for: space.storageID)
                )
            )
        }
    }

    private func merge(
        local: [CloudWorkspaceRecord],
        remote: CloudProfile
    ) -> [CloudWorkspaceRecord] {
        let remoteByID = Dictionary(
            remote.snapshot.workspaces.map { ($0.storageID, $0) },
            uniquingKeysWith: { lhs, rhs in newest(lhs, rhs) }
        )
        let remoteBySlot = Dictionary(
            remote.snapshot.workspaces.map { ($0.slotKey, $0) },
            uniquingKeysWith: { lhs, rhs in newest(lhs, rhs) }
        )
        var matchedRemoteIDs = Set<String>()
        var result = local.map { localRecord -> CloudWorkspaceRecord in
            let remoteRecord = remoteByID[localRecord.storageID]
                ?? remoteBySlot[localRecord.slotKey]
            guard let remoteRecord else { return localRecord }
            matchedRemoteIDs.insert(remoteRecord.storageID)
            let values = newest(localRecord, remoteRecord)
            return relocating(values: values, onto: localRecord)
        }

        // A different Mac can have fewer monitors or Spaces. Preserve its
        // unmatched cloud entries so signing in there cannot erase a larger
        // layout. The originating Mac remains authoritative for removals.
        if remote.sourceDeviceID != deviceID {
            result.append(contentsOf: remote.snapshot.workspaces.filter {
                !matchedRemoteIDs.contains($0.storageID)
                    && !Set(result.map(\.slotKey)).contains($0.slotKey)
            })
        }
        return result.sorted { lhs, rhs in workspaceOrder(lhs, rhs) }
    }

    private func promoteLegacyRecords(
        _ records: [CloudWorkspaceRecord]
    ) -> [CloudWorkspaceRecord] {
        let now = Date()
        return records.map { record in
            guard record.modifiedAt == .cloudEpoch,
                  record.name != nil || record.colorHex != nil else { return record }
            return CloudWorkspaceRecord(
                storageID: record.storageID,
                name: record.name,
                colorHex: record.colorHex,
                categoryID: record.categoryID,
                displayID: record.displayID,
                displayName: record.displayName,
                displayOrdinal: record.displayOrdinal,
                spaceOrdinal: record.spaceOrdinal,
                modifiedAt: now
            )
        }
    }

    private func apply(records: [CloudWorkspaceRecord]) {
        let local = currentRecords()
        let byID = Dictionary(
            records.map { ($0.storageID, $0) },
            uniquingKeysWith: { lhs, rhs in newest(lhs, rhs) }
        )
        let bySlot = Dictionary(
            records.map { ($0.slotKey, $0) },
            uniquingKeysWith: { lhs, rhs in newest(lhs, rhs) }
        )
        isApplyingCloud = true
        defer { isApplyingCloud = false }
        for localRecord in local {
            guard let cloud = byID[localRecord.storageID] ?? bySlot[localRecord.slotKey]
            else { continue }
            names.applyCloudValues(
                for: localRecord.storageID,
                name: cloud.name,
                colorHex: cloud.colorHex,
                categoryID: cloud.categoryID,
                modifiedAt: cloud.modifiedAt
            )
        }
    }

    private func relocating(
        values: CloudWorkspaceRecord,
        onto topology: CloudWorkspaceRecord
    ) -> CloudWorkspaceRecord {
        CloudWorkspaceRecord(
            storageID: topology.storageID,
            name: values.name,
            colorHex: values.colorHex,
            categoryID: values.categoryID,
            displayID: topology.displayID,
            displayName: topology.displayName,
            displayOrdinal: topology.displayOrdinal,
            spaceOrdinal: topology.spaceOrdinal,
            modifiedAt: values.modifiedAt
        )
    }

    private func newest(
        _ lhs: CloudWorkspaceRecord,
        _ rhs: CloudWorkspaceRecord
    ) -> CloudWorkspaceRecord {
        lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
    }

    private func mergeCategories(_ remote: [WorkspaceCategory]) -> [WorkspaceCategory] {
        var byID = Dictionary(uniqueKeysWithValues: names.allCategoryRecords.map { ($0.id, $0) })
        for category in remote {
            if let local = byID[category.id], local.modifiedAt > category.modifiedAt { continue }
            byID[category.id] = category
        }
        return Array(byID.values)
    }

    private func workspaceOrder(
        _ lhs: CloudWorkspaceRecord,
        _ rhs: CloudWorkspaceRecord
    ) -> Bool {
        (lhs.displayOrdinal, lhs.spaceOrdinal)
            < (rhs.displayOrdinal, rhs.spaceOrdinal)
    }

    private func normalizedDate(_ date: Date) -> Date {
        date.timeIntervalSince1970 > 0 ? date : .cloudEpoch
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NSURLErrorDomain
            && cocoaError.code == NSURLErrorCancelled
    }
}

private extension Date {
    static let cloudEpoch = Date(timeIntervalSince1970: 0)
}
