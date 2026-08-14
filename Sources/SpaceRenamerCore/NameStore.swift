import Foundation

public extension Notification.Name {
    /// Posted by `NameStore` on every name change (rename or forget). Userinfo
    /// `["id": String]` carries the affected storage key — since *Design
    /// Revision 2026-06-09* that is `ParsedSpace.storageID`. Subscribers can
    /// re-query `name(for:defaultOrdinal:)` without coupling through specific
    /// UI controllers.
    static let spaceRenamerNameDidChange = Notification.Name("SpaceRenamer.nameDidChange")
    /// Posted whenever a workspace's stored banner colour changes. Userinfo
    /// `["id": String]` carries the stable `ParsedSpace.storageID`.
    static let spaceRenamerColorDidChange = Notification.Name("SpaceRenamer.colorDidChange")
    /// Posted when category definitions or workspace assignments change.
    static let spaceRenamerCategoriesDidChange =
        Notification.Name("SpaceRenamer.categoriesDidChange")
    /// Posted when the Mission Control label layout or background opacity
    /// changes. Subscribers should rebuild the anchored overlay windows.
    static let spaceRenamerOverlayAppearanceDidChange =
        Notification.Name("SpaceRenamer.overlayAppearanceDidChange")
    static let spaceRenamerMenuBarDisplayModeDidChange =
        Notification.Name("SpaceRenamer.menuBarDisplayModeDidChange")
}

public struct WorkspaceCategory: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var colorHex: String
    public var modifiedAt: Date
    public var isDeleted: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        colorHex: String,
        modifiedAt: Date = Date(),
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
    }
}

@MainActor
public final class NameStore {
    private let defaults: UserDefaults

    private enum Key {
        static let names = "SpaceRenamer.names"               // [SpaceID: String]
        static let colors = "SpaceRenamer.colors"             // [SpaceID: RRGGBB]
        static let workspaceModifiedAt = "SpaceRenamer.workspaceModifiedAt"
        static let categories = "SpaceRenamer.categories.v1"
        static let categoryAssignments = "SpaceRenamer.categoryAssignments.v1"
        static let migratedColorsToCategories = "SpaceRenamer.didMigrateColorsToCategories"
        static let warned = "SpaceRenamer.didWarnSystemShortcuts"
        static let switchMode = "SpaceRenamer.switchMode"     // SwitchMode.rawValue
        static let missionControlOverlay = "SpaceRenamer.showMissionControlOverlay"
        static let overlayShowsAppWindows = "SpaceRenamer.overlayShowsAppWindows"
        static let overlayBackgroundOpacity = "SpaceRenamer.overlayBackgroundOpacity"
        static let migratedToUUIDKeys = "SpaceRenamer.didMigrateToUUIDKeys"
        static let menuBarDisplayMode = "SpaceRenamer.menuBarDisplayMode"
        static let appIconSortMode = "SpaceRenamer.appIconSortMode"
        static let appIconDisplayMode = "SpaceRenamer.appIconDisplayMode"
        static let appIconWindowMode = "SpaceRenamer.appIconWindowMode"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateColorsToCategoriesIfNeeded()
        removeCategorizedLegacyColors()
    }

    private var names: [String: String] {
        get { (defaults.dictionary(forKey: Key.names) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.names) }
    }

    private var colors: [String: String] {
        get { (defaults.dictionary(forKey: Key.colors) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Key.colors) }
    }

    private var workspaceModificationDates: [String: TimeInterval] {
        get {
            let raw = defaults.dictionary(forKey: Key.workspaceModifiedAt) ?? [:]
            return raw.reduce(into: [:]) { result, pair in
                if let value = pair.value as? NSNumber {
                    result[pair.key] = value.doubleValue
                }
            }
        }
        set { defaults.set(newValue, forKey: Key.workspaceModifiedAt) }
    }

    private var storedCategories: [WorkspaceCategory] {
        get {
            guard let data = defaults.data(forKey: Key.categories),
                  let decoded = try? JSONDecoder().decode([WorkspaceCategory].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.categories)
            }
        }
    }

    private var categoryAssignments: [String: String] {
        get {
            (defaults.dictionary(forKey: Key.categoryAssignments) as? [String: String]) ?? [:]
        }
        set { defaults.set(newValue, forKey: Key.categoryAssignments) }
    }

    public var categories: [WorkspaceCategory] {
        storedCategories
            .filter { !$0.isDeleted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var allCategoryRecords: [WorkspaceCategory] { storedCategories }

    public func categoryID(for spaceID: String) -> String? {
        guard let id = categoryAssignments[spaceID],
              categories.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    public func category(for spaceID: String) -> WorkspaceCategory? {
        guard let id = categoryID(for: spaceID) else { return nil }
        return categories.first { $0.id == id }
    }

    public func setCategory(_ categoryID: String?, for spaceID: String) {
        var assignments = categoryAssignments
        if let categoryID, categories.contains(where: { $0.id == categoryID }) {
            assignments[spaceID] = categoryID
            // Once represented by a category, discard the legacy one-off
            // colour so deleting/unassigning the category cannot reveal it.
            var legacyColors = colors
            legacyColors.removeValue(forKey: spaceID)
            colors = legacyColors
        } else {
            assignments.removeValue(forKey: spaceID)
        }
        categoryAssignments = assignments
        markWorkspaceModified(spaceID)
        postCategoryChange(spaceID: spaceID)
    }

    @discardableResult
    public func addCategory(name: String, colorHex: String) -> WorkspaceCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = WorkspaceCategory(
            name: trimmed.isEmpty ? "New Category" : trimmed,
            colorHex: Self.normalizedColorHex(colorHex) ?? "3A3A40"
        )
        var records = storedCategories
        records.append(category)
        storedCategories = records
        postCategoryChange()
        return category
    }

    public func updateCategory(id: String, name: String? = nil, colorHex: String? = nil) {
        var records = storedCategories
        guard let index = records.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { records[index].name = trimmed }
        }
        if let normalized = Self.normalizedColorHex(colorHex) {
            records[index].colorHex = normalized
        }
        records[index].modifiedAt = Date()
        storedCategories = records
        postCategoryChange()
    }

    public func deleteCategory(id: String) {
        var records = storedCategories
        guard let index = records.firstIndex(where: { $0.id == id && !$0.isDeleted }) else {
            return
        }
        records[index].isDeleted = true
        records[index].modifiedAt = Date()
        storedCategories = records
        var assignments = categoryAssignments
        let affected = assignments.compactMap { $0.value == id ? $0.key : nil }
        affected.forEach { assignments.removeValue(forKey: $0) }
        categoryAssignments = assignments
        affected.forEach(markWorkspaceModified)
        postCategoryChange()
    }

    public func applyCloudCategories(_ records: [WorkspaceCategory]) {
        var byID = Dictionary(uniqueKeysWithValues: storedCategories.map { ($0.id, $0) })
        for record in records {
            if let local = byID[record.id], local.modifiedAt > record.modifiedAt { continue }
            byID[record.id] = record
        }
        storedCategories = Array(byID.values)
        let validIDs = Set(categories.map(\.id))
        categoryAssignments = categoryAssignments.filter { validIDs.contains($0.value) }
        postCategoryChange()
    }

    private func postCategoryChange(spaceID: String? = nil) {
        let info = spaceID.map { ["id": $0] }
        NotificationCenter.default.post(
            name: .spaceRenamerCategoriesDidChange,
            object: nil,
            userInfo: info
        )
        NotificationCenter.default.post(
            name: .spaceRenamerColorDidChange,
            object: nil,
            userInfo: info
        )
    }

    /// The explicitly saved name, excluding the generated "Desktop N"
    /// fallback. Cloud sync uses this to distinguish a user rename from a
    /// default label.
    public func storedName(for spaceID: String) -> String? {
        names[spaceID]
    }

    /// Timestamp of the newest local name/colour edit for a workspace.
    /// Existing pre-cloud installs intentionally return `distantPast`; the
    /// first cloud merge can then restore newer account data safely.
    public func workspaceModifiedAt(for spaceID: String) -> Date {
        guard let interval = workspaceModificationDates[spaceID] else {
            return .distantPast
        }
        return Date(timeIntervalSince1970: interval)
    }

    private func markWorkspaceModified(_ spaceID: String) {
        var dates = workspaceModificationDates
        dates[spaceID] = Date().timeIntervalSince1970
        workspaceModificationDates = dates
    }

    public func name(for spaceID: String, defaultOrdinal: Int) -> String {
        if let custom = names[spaceID], !custom.isEmpty { return custom }
        return "Desktop \(defaultOrdinal)"
    }

    public func setName(_ spaceID: String, _ name: String) {
        var dict = names
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: spaceID)
        } else {
            dict[spaceID] = trimmed
        }
        names = dict
        markWorkspaceModified(spaceID)
        NotificationCenter.default.post(name: .spaceRenamerNameDidChange,
                                        object: nil, userInfo: ["id": spaceID])
    }

    public func forget(_ spaceID: String) {
        var dict = names
        dict.removeValue(forKey: spaceID)
        names = dict
        markWorkspaceModified(spaceID)
        NotificationCenter.default.post(name: .spaceRenamerNameDidChange,
                                        object: nil, userInfo: ["id": spaceID])
    }

    /// Stored banner colour as a normalized six-digit sRGB hex string, or nil
    /// when the workspace should use Workspace++'s default dark background.
    public func colorHex(for spaceID: String) -> String? {
        category(for: spaceID)?.colorHex ?? colors[spaceID]
    }

    public func setColorHex(_ spaceID: String, _ hex: String?) {
        var dict = colors
        if let normalized = Self.normalizedColorHex(hex) {
            dict[spaceID] = normalized
        } else {
            dict.removeValue(forKey: spaceID)
        }
        colors = dict
        markWorkspaceModified(spaceID)
        NotificationCenter.default.post(
            name: .spaceRenamerColorDidChange,
            object: nil,
            userInfo: ["id": spaceID]
        )
    }

    /// Applies a cloud value while retaining its original modification time.
    /// Notifications are still posted so every visible label updates at once.
    public func applyCloudValues(
        for spaceID: String,
        name: String?,
        colorHex: String?,
        categoryID: String? = nil,
        modifiedAt: Date
    ) {
        var nameDict = names
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { nameDict.removeValue(forKey: spaceID) }
            else { nameDict[spaceID] = trimmed }
        } else {
            nameDict.removeValue(forKey: spaceID)
        }
        names = nameDict

        var colorDict = colors
        let hasValidCategory = categoryID.map {
            id in categories.contains(where: { $0.id == id })
        } ?? false
        if hasValidCategory {
            colorDict.removeValue(forKey: spaceID)
        } else if let normalized = Self.normalizedColorHex(colorHex) {
            colorDict[spaceID] = normalized
        } else {
            colorDict.removeValue(forKey: spaceID)
        }
        colors = colorDict

        var assignments = categoryAssignments
        if let categoryID, categories.contains(where: { $0.id == categoryID }) {
            assignments[spaceID] = categoryID
        } else {
            assignments.removeValue(forKey: spaceID)
        }
        categoryAssignments = assignments

        var dates = workspaceModificationDates
        dates[spaceID] = modifiedAt.timeIntervalSince1970
        workspaceModificationDates = dates

        NotificationCenter.default.post(
            name: .spaceRenamerNameDidChange,
            object: nil,
            userInfo: ["id": spaceID]
        )
        NotificationCenter.default.post(
            name: .spaceRenamerColorDidChange,
            object: nil,
            userInfo: ["id": spaceID]
        )
    }

    private static func normalizedColorHex(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        let validDigits = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        guard value.count == 6,
              value.unicodeScalars.allSatisfy(validDigits.contains) else {
            return nil
        }
        return value.uppercased()
    }

    private func migrateColorsToCategoriesIfNeeded() {
        guard !defaults.bool(forKey: Key.migratedColorsToCategories) else { return }
        let now = Date()
        // Built-in definitions are a baseline, not a user edit. Epoch makes a
        // renamed/recoloured cloud copy win when a new Mac signs in.
        var records = Self.defaultCategories(modifiedAt: Date(timeIntervalSince1970: 0))
        var assignments: [String: String] = [:]
        let knownByColor = Dictionary(
            records.map { ($0.colorHex, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let knownByName = Dictionary(
            records.map { ($0.name.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        for (spaceID, hex) in colors {
            let normalized = Self.normalizedColorHex(hex) ?? "3A3A40"
            let workspaceName = names[spaceID]?.lowercased()
            if let workspaceName, let exact = knownByName[workspaceName] {
                assignments[spaceID] = exact
            } else if let known = knownByColor[normalized] {
                assignments[spaceID] = known
            } else {
                let imported = WorkspaceCategory(
                    name: "Imported #\(normalized)",
                    colorHex: normalized,
                    modifiedAt: now
                )
                records.append(imported)
                assignments[spaceID] = imported.id
            }
        }
        storedCategories = records
        categoryAssignments = assignments
        // Every existing raw colour now has a lossless category equivalent.
        // Keeping both would let the obsolete raw colour reappear later.
        colors = colors.filter { assignments[$0.key] == nil }
        defaults.set(true, forKey: Key.migratedColorsToCategories)
    }

    private func removeCategorizedLegacyColors() {
        let assignments = categoryAssignments
        let cleaned = colors.filter { assignments[$0.key] == nil }
        if cleaned != colors { colors = cleaned }
    }

    private static func defaultCategories(modifiedAt: Date) -> [WorkspaceCategory] {
        [
            WorkspaceCategory(id: "default.work", name: "Work", colorHex: "0433FF", modifiedAt: modifiedAt),
            WorkspaceCategory(id: "default.hobby", name: "Hobby", colorHex: "FF40FF", modifiedAt: modifiedAt),
            WorkspaceCategory(id: "default.zen", name: "Zen", colorHex: "00A800", modifiedAt: modifiedAt),
            WorkspaceCategory(id: "default.misc", name: "Misc", colorHex: "3A3A40", modifiedAt: modifiedAt),
            WorkspaceCategory(id: "default.unsorted", name: "Unsorted windows", colorHex: "FB4A00", modifiedAt: modifiedAt),
            WorkspaceCategory(id: "default.personal", name: "Personal tasks", colorHex: "AA7942", modifiedAt: modifiedAt),
            WorkspaceCategory(id: "default.entertainment", name: "Entertainment", colorHex: "FFFB00", modifiedAt: modifiedAt),
            WorkspaceCategory(id: "default.medical", name: "Medical", colorHex: "00BFCB", modifiedAt: modifiedAt),
        ]
    }

    /// Rewrites stored names under new keys (`remap[oldKey] = newKey`). Used
    /// once at launch to move MSID-keyed entries to restart-stable
    /// `ParsedSpace.storageID` keys (uuid / `"primary"`) — see *Design Revision
    /// 2026-06-09*. An entry already present under the new key wins; the old
    /// key is removed either way. Entries not in `remap` are untouched.
    public func migrateKeys(_ remap: [String: String]) {
        var dict = names
        for (old, new) in remap {
            guard let value = dict.removeValue(forKey: old) else { continue }
            if dict[new] == nil { dict[new] = value }
        }
        names = dict

        var colorDict = colors
        for (old, new) in remap {
            guard let value = colorDict.removeValue(forKey: old) else { continue }
            if colorDict[new] == nil { colorDict[new] = value }
        }
        colors = colorDict

        var assignmentDict = categoryAssignments
        for (old, new) in remap {
            guard let value = assignmentDict.removeValue(forKey: old) else { continue }
            if assignmentDict[new] == nil { assignmentDict[new] = value }
        }
        categoryAssignments = assignmentDict

        var dateDict = workspaceModificationDates
        for (old, new) in remap {
            guard let value = dateDict.removeValue(forKey: old) else { continue }
            if dateDict[new] == nil { dateDict[new] = value }
        }
        workspaceModificationDates = dateDict
    }

    /// One-shot guard for the MSID→storageID key migration (names + hotkeys).
    public var didMigrateToUUIDKeys: Bool {
        get { defaults.bool(forKey: Key.migratedToUUIDKeys) }
        set { defaults.set(newValue, forKey: Key.migratedToUUIDKeys) }
    }

    public var didWarnAboutSystemShortcuts: Bool {
        get { defaults.bool(forKey: Key.warned) }
        set { defaults.set(newValue, forKey: Key.warned) }
    }

    /// Desktop-switch delivery mechanism. Missing/invalid → `SwitchMode.default`.
    public var switchMode: SwitchMode {
        get { defaults.string(forKey: Key.switchMode).flatMap(SwitchMode.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.switchMode) }
    }

    /// Per-Space label window visible (huge) in Mission Control thumbnails.
    /// **On by default** — opt-out via Preferences. (Absent key → `true`; an
    /// explicit `false` written by the user still wins.) See *Design Revision
    /// 2026-06-04*.
    public var showMissionControlOverlay: Bool {
        get {
            if defaults.object(forKey: Key.missionControlOverlay) == nil { return true }
            return defaults.bool(forKey: Key.missionControlOverlay)
        }
        set { defaults.set(newValue, forKey: Key.missionControlOverlay) }
    }

    /// When true, the colour is confined to a centered band so Mission Control
    /// can still show the workspace's app windows. Missing key defaults on.
    public var overlayShowsAppWindows: Bool {
        get {
            if defaults.object(forKey: Key.overlayShowsAppWindows) == nil {
                return true
            }
            return defaults.bool(forKey: Key.overlayShowsAppWindows)
        }
        set {
            defaults.set(newValue, forKey: Key.overlayShowsAppWindows)
            NotificationCenter.default.post(
                name: .spaceRenamerOverlayAppearanceDidChange,
                object: nil
            )
        }
    }

    /// Opacity of the coloured background only. Text always remains fully
    /// opaque. Missing key defaults to 70 percent.
    public var overlayBackgroundOpacity: Double {
        get {
            guard defaults.object(forKey: Key.overlayBackgroundOpacity) != nil else {
                return 0.70
            }
            return min(1, max(0.10, defaults.double(
                forKey: Key.overlayBackgroundOpacity
            )))
        }
        set {
            defaults.set(
                min(1, max(0.10, newValue)),
                forKey: Key.overlayBackgroundOpacity
            )
            NotificationCenter.default.post(
                name: .spaceRenamerOverlayAppearanceDidChange,
                object: nil
            )
        }
    }

    /// How active Space names are represented when more than one display is
    /// connected. Missing/invalid values use the per-display presentation.
    public var menuBarDisplayMode: MenuBarDisplayMode {
        get {
            defaults.string(forKey: Key.menuBarDisplayMode)
                .flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .default
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.menuBarDisplayMode)
            NotificationCenter.default.post(
                name: .spaceRenamerMenuBarDisplayModeDidChange,
                object: nil
            )
        }
    }

    /// Ordering used for the compact app icons in each workspace menu row.
    /// Missing or invalid values prefer the most-used app across all Spaces.
    public var appIconSortMode: AppIconSortMode {
        get {
            defaults.string(forKey: Key.appIconSortMode)
                .flatMap(AppIconSortMode.init(rawValue:)) ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appIconSortMode) }
    }

    /// Detailed left-aligned or compact right-aligned app-icon presentation.
    public var appIconDisplayMode: AppIconDisplayMode {
        get {
            defaults.string(forKey: Key.appIconDisplayMode)
                .flatMap(AppIconDisplayMode.init(rawValue:)) ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appIconDisplayMode) }
    }

    /// Whether app windows are collapsed into one icon, counted beside one
    /// icon, or represented by repeated icons. For backwards compatibility,
    /// an existing right-aligned installation begins in its former icons-only
    /// presentation until the user explicitly chooses another mode.
    public var appIconWindowMode: AppIconWindowMode {
        get {
            if let rawValue = defaults.string(forKey: Key.appIconWindowMode) {
                return AppIconWindowMode(rawValue: rawValue) ?? .default
            }
            return appIconDisplayMode == .rightAligned ? .iconsOnly : .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appIconWindowMode) }
    }
}
