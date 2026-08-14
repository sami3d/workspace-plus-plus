import Combine
import Foundation
import SpaceRenamerCore

@MainActor
final class CloudSyncManager: ObservableObject {
    @Published private(set) var state: CloudSyncState

    private let monitor: SpaceMonitor
    private let names: NameStore
    private let client: SupabaseCloudClient?
    private let deviceID: UUID

    private var cancellables: Set<AnyCancellable> = []
    // Notification tokens are created and mutated on the main actor. ARC may
    // invoke `deinit` from a nonisolated context, so this mirrors the Core
    // monitor's documented teardown escape hatch.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var bootstrapTask: Task<Void, Never>?
    private var pendingSyncTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var isApplyingCloud = false
    private var lastSuccessfulSync: Date?

    init(monitor: SpaceMonitor, names: NameStore, defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.names = names
        let key = "SpaceRenamer.cloudDeviceID"
        if let stored = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) {
            deviceID = stored
        } else {
            let generated = UUID()
            defaults.set(generated.uuidString, forKey: key)
            deviceID = generated
        }

        if let configuration = CloudConfiguration.bundled() {
            let session = try? CloudKeychain.loadSession()
            client = SupabaseCloudClient(
                configuration: configuration,
                session: session
            )
            state = session.map { .signedIn(email: $0.email, lastSync: nil) }
                ?? .signedOut(nil)
        } else {
            client = nil
            state = .unavailable("Cloud sync is being connected to the Workspace++ service.")
        }

        subscribeToLocalChanges()
    }

    deinit {
        bootstrapTask?.cancel()
        pendingSyncTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isConfigured: Bool { client != nil }

    func start() {
        guard let client else { return }
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            if let session = await client.restoredSession() {
                state = .syncing(email: session.email)
                await synchronize(email: session.email)
            } else {
                state = .signedOut(nil)
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
        } catch {
            state = .failed(email: nil, message: error.localizedDescription)
        }
    }

    func signOut() async {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        if let client { await client.signOut() }
        hasBootstrapped = true
        state = .signedOut(nil)
    }

    func syncNow() async {
        guard let email = state.email else { return }
        state = .syncing(email: email)
        await synchronize(email: email)
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
            uniquingKeysWith: newest
        )
        let remoteBySlot = Dictionary(
            remote.snapshot.workspaces.map { ($0.slotKey, $0) },
            uniquingKeysWith: newest
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
        return result.sorted(by: workspaceOrder)
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
        let byID = Dictionary(records.map { ($0.storageID, $0) }, uniquingKeysWith: newest)
        let bySlot = Dictionary(records.map { ($0.slotKey, $0) }, uniquingKeysWith: newest)
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
