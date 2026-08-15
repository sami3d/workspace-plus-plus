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
    @Published private(set) var workspaceLibrary = WorkspaceLibrary()
    @Published private(set) var libraryStatus = "Workspace Library has not been loaded."

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
    private var historyCaptureTask: Task<Bool, Never>?
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
    var currentDeviceID: UUID { deviceID }

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

    @discardableResult
    func captureWorkspaceHistoryNow() async -> Bool {
        guard workspaceHistoryEnabled else {
            historyStatus = "Turn on Workspace History before saving app, window and tab details."
            return false
        }
        guard state.email != nil else {
            historyStatus = "Sign in to save workspace sessions."
            return false
        }
        historyCaptureTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await captureAndUploadWorkspaceHistory()
        }
        historyCaptureTask = task
        let succeeded = await task.value
        historyCaptureTask = nil
        return succeeded
    }

    func refreshWorkspaceHistory() async {
        guard let client, state.email != nil else { return }
        do {
            var rows = try await client.fetchWorkspaceSessions()
            let activeKeys = reliableActiveWorkspaceKeys()
            var removedSessionCount = 0
            if let activeKeys {
                let stale = rows.filter {
                    $0.deviceID == deviceID
                        && $0.deletedAt == nil
                        && !activeKeys.contains($0.workspaceKey)
                }
                if !stale.isEmpty {
                    try await client.deleteWorkspaceSessions(ids: stale.map(\.id))
                    let removedIDs = Set(stale.map(\.id))
                    let deletedAt = Date()
                    rows = rows.map { item in
                        guard removedIDs.contains(item.id) else { return item }
                        return historyItem(item, deletedAt: deletedAt)
                    }
                    removedSessionCount = stale.count
                }
            }
            workspaceHistoryRows = rows
            workspaceHistory = workspaceHistoryRows.filter { $0.deletedAt == nil }
            historyStatus = workspaceHistory.isEmpty
                ? "No workspace sessions have been saved yet."
                : "\(workspaceHistory.count) saved workspace session\(workspaceHistory.count == 1 ? "" : "s")."
            await refreshWorkspaceLibrary()
            var parkedInstanceCount = 0
            if let activeKeys {
                let staleInstances = workspaceLibrary.instances.filter {
                    $0.deviceID == deviceID
                        && $0.deletedAt == nil
                        && $0.status != .parked
                        && $0.localWorkspaceKey.map { !activeKeys.contains($0) } == true
                }
                for instance in staleInstances {
                    try await client.setInstanceState(
                        id: instance.id,
                        status: .parked,
                        localWorkspaceKey: nil
                    )
                }
                parkedInstanceCount = staleInstances.count
                if parkedInstanceCount > 0 { await refreshWorkspaceLibrary() }
            }
            if removedSessionCount > 0 || parkedInstanceCount > 0 {
                var reconciliationMessages: [String] = []
                if removedSessionCount > 0 {
                    reconciliationMessages.append("Removed \(removedSessionCount) deleted-Space session\(removedSessionCount == 1 ? "" : "s") from this Mac")
                }
                if parkedInstanceCount > 0 {
                    reconciliationMessages.append("parked \(parkedInstanceCount) cloud instance\(parkedInstanceCount == 1 ? "" : "s")")
                }
                historyStatus += " " + reconciliationMessages.joined(separator: " · ") + "."
            }
        } catch {
            historyStatus = error.localizedDescription
        }
    }

    func refreshWorkspaceLibrary() async {
        guard let client, state.email != nil else { return }
        do {
            workspaceLibrary = try await client.fetchWorkspaceLibrary()
            let count = workspaceLibrary.workspaces.filter { $0.deletedAt == nil }.count
            libraryStatus = count == 0
                ? "No cloud workspaces yet. Save workspace history to create them."
                : "\(count) cloud workspace\(count == 1 ? "" : "s") across \(workspaceLibrary.devices.count) Mac\(workspaceLibrary.devices.count == 1 ? "" : "s")."
        } catch {
            libraryStatus = error.localizedDescription
        }
    }

    func parkInstance(_ instance: CloudWorkspaceInstance) async {
        guard let client else { return }
        guard let localWorkspaceKey = instance.localWorkspaceKey else {
            libraryStatus = "This instance is already detached from a local Space."
            return
        }
        guard await captureWorkspaceHistoryNow() else {
            libraryStatus = "Parking stopped because the fresh cloud save failed."
            return
        }
        guard workspaceLibrary.instances.first(where: { $0.id == instance.id })?.headRevisionID != nil else {
            libraryStatus = "Parking stopped because no verified cloud revision exists yet."
            return
        }
        do {
            try await client.setInstanceState(id: instance.id, status: .parked, localWorkspaceKey: nil)
            let closeResult = WorkspaceParker(monitor: monitor).closeWindows(in: localWorkspaceKey)
            await refreshWorkspaceLibrary()
            libraryStatus = "Workspace parked · closed \(closeResult.closedWindowCount) window\(closeResult.closedWindowCount == 1 ? "" : "s")"
            if closeResult.skippedWindowCount > 0 {
                libraryStatus += " · \(closeResult.skippedWindowCount) window\(closeResult.skippedWindowCount == 1 ? "" : "s") must be closed manually"
            }
        } catch {
            libraryStatus = error.localizedDescription
        }
    }

    func deleteLibraryWorkspace(_ workspace: CloudLibraryWorkspace) async {
        guard let client else { return }
        do {
            try await client.deleteLibraryWorkspace(id: workspace.id)
            await refreshWorkspaceLibrary()
            libraryStatus = "Removed from the Workspace Library. Local windows were left untouched."
        } catch {
            libraryStatus = error.localizedDescription
        }
    }

    func bindWorkspace(
        _ workspace: CloudLibraryWorkspace,
        to localWorkspaceKey: String,
        asDuplicate: Bool
    ) async {
        guard let client,
              let revision = workspaceLibrary.latestRevision(for: workspace) else { return }
        let instanceID = asDuplicate
            ? UUID()
            : instanceID(for: localWorkspaceKey)
        let target = monitor.spaces.first { $0.storageID == localWorkspaceKey }
        var snapshot = revision.snapshot
        if let target {
            snapshot = WorkspaceSessionSnapshot(
                workspaceKey: localWorkspaceKey,
                workspaceName: workspace.name,
                categoryName: workspace.categoryName,
                colorHex: workspace.colorHex,
                displayName: monitor.displays.first(where: { $0.id == target.displayID }).map {
                    DisplayResolver.name(for: $0.id, ordinal: $0.ordinal)
                } ?? revision.snapshot.displayName,
                displayOrdinal: monitor.displays.first(where: { $0.id == target.displayID })?.ordinal
                    ?? revision.snapshot.displayOrdinal,
                spaceOrdinal: target.ordinal,
                applications: revision.snapshot.applications
            )
        }
        do {
            let hash = sessionCapture.contentHash(for: snapshot)
            let newRevisionID = stableRevisionID(instanceID: instanceID, hash: hash)
            try await client.saveLibraryRevision(
                workspaceID: workspace.id,
                instanceID: instanceID,
                revisionID: newRevisionID,
                parentRevisionID: revision.id,
                contentHash: hash,
                snapshot: snapshot,
                device: currentDevice(),
                status: .loaded
            )
            rememberWorkspaceID(workspace.id, for: localWorkspaceKey)
            rememberInstanceID(instanceID, for: localWorkspaceKey)
            names.setName(localWorkspaceKey, workspace.name)
            await refreshWorkspaceLibrary()
        } catch {
            libraryStatus = error.localizedDescription
        }
    }

    func requestTransfer(
        workspace: CloudLibraryWorkspace,
        destinationDeviceID: UUID?,
        mode: CloudWorkspaceTransferMode
    ) async {
        guard let client,
              let revision = workspaceLibrary.latestRevision(for: workspace) else { return }
        let source = workspaceLibrary.instances(for: workspace.id)
            .first(where: { $0.deviceID == deviceID && $0.status != .parked })
        do {
            try await client.createTransfer(
                workspaceID: workspace.id,
                revisionID: revision.id,
                sourceInstanceID: source?.id,
                sourceDeviceID: deviceID,
                destinationDeviceID: destinationDeviceID,
                mode: mode
            )
            await refreshWorkspaceLibrary()
            libraryStatus = mode == .move
                ? "Move requested. The source remains intact until the destination accepts and verifies it."
                : "Copy requested. The destination Mac can now launch its own instance."
        } catch {
            libraryStatus = error.localizedDescription
        }
    }

    /// Called only after restore succeeds on the destination. A move then
    /// parks the source instance; a copy leaves both instances loaded.
    func completePendingTransfer(
        for workspace: CloudLibraryWorkspace,
        localWorkspaceKey: String
    ) async {
        guard let client else { return }
        let transfer = workspaceLibrary.transfers.first {
            $0.workspaceID == workspace.id
                && $0.status == .pending
                && ($0.destinationDeviceID == nil || $0.destinationDeviceID == deviceID)
        }
        guard let transfer else { return }
        let destinationInstanceID = instanceID(for: localWorkspaceKey)
        do {
            try await client.completeTransfer(
                id: transfer.id,
                destinationInstanceID: destinationInstanceID
            )
            if transfer.mode == .move, let source = transfer.sourceInstanceID {
                try await client.setInstanceState(id: source, status: .parked, localWorkspaceKey: nil)
            }
            await refreshWorkspaceLibrary()
            libraryStatus = transfer.mode == .move
                ? "Move verified. The destination is loaded and the source is now parked."
                : "Copy verified. Both local instances remain available."
        } catch {
            libraryStatus = "Restored locally, but cloud transfer finalization failed: \(error.localizedDescription)"
        }
    }

    func deleteWorkspaceHistory(id: UUID) async {
        guard let client, state.email != nil else { return }
        do {
            try await client.deleteWorkspaceSession(id: id)
            workspaceHistory.removeAll { $0.id == id }
            if let index = workspaceHistoryRows.firstIndex(where: { $0.id == id }) {
                workspaceHistoryRows[index] = historyItem(
                    workspaceHistoryRows[index],
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
                _ = await self.captureWorkspaceHistoryNow()
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
            }
        }
    }

    private func captureAndUploadWorkspaceHistory() async -> Bool {
        guard let client else { return false }
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
        // Library v2 has its own immutable revision graph. Seed it from an
        // existing v1 history even when the legacy latest-snapshot row has not
        // changed, then append only when this instance's content hash changes.
        let libraryChanges = capture.snapshots.compactMap { snapshot
            -> (hash: String, snapshot: WorkspaceSessionSnapshot)? in
            let hash = sessionCapture.contentHash(for: snapshot)
            let instanceID = instanceID(for: snapshot.workspaceKey)
            let existingHead = workspaceLibrary.instances.first { $0.id == instanceID }?.headRevisionID
            let existingHash = existingHead.flatMap { head in
                workspaceLibrary.revisions.first { $0.id == head }?.contentHash
            }
            guard existingHash != hash else { return nil }
            return (hash, snapshot)
        }
        do {
            let device = currentDevice()
            try await client.registerDevice(device)
            try await client.saveWorkspaceSessions(changed, device: device)
            for item in libraryChanges {
                let workspaceID = workspaceID(for: item.snapshot.workspaceKey)
                let instanceID = instanceID(for: item.snapshot.workspaceKey)
                let revisionID = stableRevisionID(instanceID: instanceID, hash: item.hash)
                let parent = workspaceLibrary.instances.first(where: { $0.id == instanceID })?.headRevisionID
                try await client.saveLibraryRevision(
                    workspaceID: workspaceID,
                    instanceID: instanceID,
                    revisionID: revisionID,
                    parentRevisionID: parent,
                    contentHash: item.hash,
                    snapshot: item.snapshot,
                    device: device,
                    status: .loaded
                )
            }
            await refreshWorkspaceHistory()
            if changed.isEmpty {
                historyStatus = "Everything is current · checked \(Date().formatted(date: .omitted, time: .shortened))."
            }
            if !capture.warnings.isEmpty {
                historyStatus += " " + capture.warnings.joined(separator: " ")
            }
            return true
        } catch {
            historyStatus = error.localizedDescription
            return false
        }
    }

    /// Returns nil when Space discovery is unhealthy. Reconciliation must
    /// never interpret a transient empty/failed read as deletion of every
    /// workspace on the Mac.
    private func reliableActiveWorkspaceKeys() -> Set<String>? {
        monitor.reload()
        guard monitor.lastLoadError == nil, !monitor.spaces.isEmpty else { return nil }
        return Set(monitor.spaces.map(\.storageID))
    }

    private func historyItem(
        _ item: CloudWorkspaceHistoryItem,
        deletedAt: Date?
    ) -> CloudWorkspaceHistoryItem {
        CloudWorkspaceHistoryItem(
            id: item.id,
            deviceID: item.deviceID,
            deviceName: item.deviceName,
            workspaceKey: item.workspaceKey,
            contentHash: item.contentHash,
            snapshot: item.snapshot,
            capturedAt: item.capturedAt,
            updatedAt: item.updatedAt,
            deletedAt: deletedAt
        )
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

    private func workspaceID(for workspaceKey: String) -> UUID {
        let defaultsKey = "SpaceRenamer.cloudWorkspaceIDs.v2"
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let raw = stored[workspaceKey], let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        stored[workspaceKey] = id.uuidString
        defaults.set(stored, forKey: defaultsKey)
        return id
    }

    private func rememberWorkspaceID(_ id: UUID, for workspaceKey: String) {
        let defaultsKey = "SpaceRenamer.cloudWorkspaceIDs.v2"
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        stored[workspaceKey] = id.uuidString
        defaults.set(stored, forKey: defaultsKey)
    }

    private func stableInstanceID(workspaceKey: String) -> UUID {
        stableUUID(seed: "instance:\(deviceID.uuidString.lowercased()):\(workspaceKey)")
    }

    private func instanceID(for workspaceKey: String) -> UUID {
        let defaultsKey = "SpaceRenamer.cloudInstanceIDs.v2"
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let raw = stored[workspaceKey], let id = UUID(uuidString: raw) { return id }
        let id = stableInstanceID(workspaceKey: workspaceKey)
        stored[workspaceKey] = id.uuidString
        defaults.set(stored, forKey: defaultsKey)
        return id
    }

    private func rememberInstanceID(_ id: UUID, for workspaceKey: String) {
        let defaultsKey = "SpaceRenamer.cloudInstanceIDs.v2"
        var stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        stored[workspaceKey] = id.uuidString
        defaults.set(stored, forKey: defaultsKey)
    }

    private func stableRevisionID(instanceID: UUID, hash: String) -> UUID {
        stableUUID(seed: "revision:\(instanceID.uuidString.lowercased()):\(hash)")
    }

    private func stableUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
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
