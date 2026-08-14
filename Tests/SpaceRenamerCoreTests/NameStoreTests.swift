import XCTest
@testable import SpaceRenamerCore

@MainActor final class NameStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: NameStore!

    // `setUp()` / `tearDown()` on a `@MainActor` XCTestCase: use the
    // `async throws` overrides so the body inherits the class's main-actor
    // isolation (sync overrides are nonisolated on the base and can't touch
    // @MainActor properties). The base implementations are empty, and calling
    // `try await super.setUp()` from this @MainActor override would send `self`
    // across to the nonisolated base — a Swift 6 "sending" error that fires on
    // some toolchain versions (Swift 6.0 in CI). Skipping super is the
    // cross-version-safe fix.
    override func setUp() async throws {
        suiteName = "NameStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = NameStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_unknownSpaceID_returnsDefaultNameUsingOrdinal() {
        XCTAssertEqual(store.name(for: "42", defaultOrdinal: 3), "Desktop 3")
    }

    func test_setName_persists() {
        store.setName("42", "Research")
        XCTAssertEqual(store.name(for: "42", defaultOrdinal: 1), "Research")
    }

    func test_setName_emptyString_revertsToDefault() {
        store.setName("42", "Research")
        store.setName("42", "")
        XCTAssertEqual(store.name(for: "42", defaultOrdinal: 2), "Desktop 2")
    }

    func test_setName_whitespaceOnly_revertsToDefault() {
        store.setName("42", "   ")
        XCTAssertEqual(store.name(for: "42", defaultOrdinal: 4), "Desktop 4")
    }

    func test_forget_removesName() {
        store.setName("42", "Research")
        store.forget("42")
        XCTAssertEqual(store.name(for: "42", defaultOrdinal: 5), "Desktop 5")
    }

    func test_namesSurviveStoreReconstruction() {
        store.setName("42", "Research")
        let reborn = NameStore(defaults: defaults)
        XCTAssertEqual(reborn.name(for: "42", defaultOrdinal: 1), "Research")
    }

    func test_colorDefaultsToNil() {
        XCTAssertNil(store.colorHex(for: "42"))
    }

    func test_defaultCategories_includeRequestedStarterSet() {
        let categoryNames = Set(store.categories.map(\.name))
        XCTAssertTrue(Set([
            "Work", "Hobby", "Zen", "Misc", "Unsorted windows",
            "Personal tasks", "Entertainment", "Medical",
        ]).isSubset(of: categoryNames))
    }

    func test_categoryAssignment_usesCategoryColorAndPersists() {
        let work = store.categories.first { $0.name == "Work" }!
        store.setCategory(work.id, for: "42")
        XCTAssertEqual(store.categoryID(for: "42"), work.id)
        XCTAssertEqual(store.colorHex(for: "42"), work.colorHex)

        let reborn = NameStore(defaults: defaults)
        XCTAssertEqual(reborn.categoryID(for: "42"), work.id)
        XCTAssertEqual(reborn.colorHex(for: "42"), work.colorHex)
    }

    func test_recolourCategory_updatesEveryAssignedWorkspace() {
        let work = store.categories.first { $0.name == "Work" }!
        store.setCategory(work.id, for: "42")
        store.setCategory(work.id, for: "43")
        store.updateCategory(id: work.id, colorHex: "123abc")
        XCTAssertEqual(store.colorHex(for: "42"), "123ABC")
        XCTAssertEqual(store.colorHex(for: "43"), "123ABC")
    }

    func test_deleteCategory_uncategorisesAssignedWorkspaces() {
        let category = store.addCategory(name: "Temporary", colorHex: "123456")
        store.setCategory(category.id, for: "42")
        store.deleteCategory(id: category.id)
        XCTAssertNil(store.categoryID(for: "42"))
        XCTAssertFalse(store.categories.contains { $0.id == category.id })
        XCTAssertTrue(store.allCategoryRecords.first { $0.id == category.id }?.isDeleted == true)
    }

    func test_setColorHex_normalizesAndPersists() {
        store.setColorHex("42", "#2a9df4")
        XCTAssertEqual(store.colorHex(for: "42"), "2A9DF4")
        XCTAssertEqual(
            NameStore(defaults: defaults).colorHex(for: "42"),
            "2A9DF4"
        )
    }

    func test_setColorHex_invalidOrNilRestoresDefault() {
        store.setColorHex("42", "2A9DF4")
        store.setColorHex("42", "not-a-colour")
        XCTAssertNil(store.colorHex(for: "42"))

        store.setColorHex("42", "2A9DF4")
        store.setColorHex("42", nil)
        XCTAssertNil(store.colorHex(for: "42"))
    }

    func test_localNameAndColorEditsRecordModificationTime() {
        XCTAssertEqual(store.workspaceModifiedAt(for: "42"), .distantPast)
        let before = Date()
        store.setName("42", "Research")
        XCTAssertGreaterThanOrEqual(store.workspaceModifiedAt(for: "42"), before)

        let firstEdit = store.workspaceModifiedAt(for: "42")
        store.setColorHex("42", "112233")
        XCTAssertGreaterThanOrEqual(store.workspaceModifiedAt(for: "42"), firstEdit)
    }

    func test_applyCloudValues_persistsValuesAndCloudTimestamp() {
        let cloudDate = Date(timeIntervalSince1970: 1_700_000_000)
        store.applyCloudValues(
            for: "42",
            name: "Cloud Research",
            colorHex: "aabbcc",
            modifiedAt: cloudDate
        )

        let reborn = NameStore(defaults: defaults)
        XCTAssertEqual(reborn.storedName(for: "42"), "Cloud Research")
        XCTAssertEqual(reborn.colorHex(for: "42"), "AABBCC")
        XCTAssertEqual(reborn.workspaceModifiedAt(for: "42"), cloudDate)
    }

    func test_applyCloudValues_nilClearsNameAndColor() {
        store.setName("42", "Local")
        store.setColorHex("42", "112233")
        store.applyCloudValues(
            for: "42",
            name: nil,
            colorHex: nil,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertNil(store.storedName(for: "42"))
        XCTAssertNil(store.colorHex(for: "42"))
    }

    func test_migrateKeys_movesColorsAndExistingNewKeyWins() {
        store.setColorHex("42", "112233")
        store.setColorHex("7", "445566")
        store.setColorHex("UUID-B", "ABCDEF")
        store.migrateKeys(["42": "UUID-A", "7": "UUID-B"])

        XCTAssertEqual(store.colorHex(for: "UUID-A"), "112233")
        XCTAssertEqual(store.colorHex(for: "UUID-B"), "ABCDEF")
        XCTAssertNil(store.colorHex(for: "42"))
        XCTAssertNil(store.colorHex(for: "7"))
    }

    func test_systemShortcutsWarningFlag_defaultsFalse_thenPersists() {
        XCTAssertFalse(store.didWarnAboutSystemShortcuts)
        store.didWarnAboutSystemShortcuts = true
        let reborn = NameStore(defaults: defaults)
        XCTAssertTrue(reborn.didWarnAboutSystemShortcuts)
    }

    func test_switchMode_defaultsToArrow() {
        XCTAssertEqual(store.switchMode, .arrow)
        XCTAssertEqual(SwitchMode.default, .arrow)
    }

    func test_switchMode_roundTripsAcrossReconstruction() {
        store.switchMode = .ctrlDigit
        let reborn = NameStore(defaults: defaults)
        XCTAssertEqual(reborn.switchMode, .ctrlDigit)
    }

    func test_switchMode_invalidStoredValue_fallsBackToDefault() {
        defaults.set("bogus", forKey: "SpaceRenamer.switchMode")
        XCTAssertEqual(NameStore(defaults: defaults).switchMode, .arrow)
    }

    func test_menuBarDisplayMode_defaultsToPerDisplay() {
        XCTAssertEqual(store.menuBarDisplayMode, .perDisplay)
        XCTAssertEqual(MenuBarDisplayMode.default, .perDisplay)
    }

    func test_menuBarDisplayMode_roundTripsAcrossReconstruction() {
        store.menuBarDisplayMode = .combined
        let reborn = NameStore(defaults: defaults)
        XCTAssertEqual(reborn.menuBarDisplayMode, .combined)
    }

    func test_menuBarDisplayMode_invalidStoredValue_fallsBackToDefault() {
        defaults.set("bogus", forKey: "SpaceRenamer.menuBarDisplayMode")
        XCTAssertEqual(NameStore(defaults: defaults).menuBarDisplayMode, .perDisplay)
    }

    func test_appIconSortMode_defaultsToGlobalWindowCount() {
        XCTAssertEqual(store.appIconSortMode, .globalWindowCount)
        XCTAssertEqual(AppIconSortMode.default, .globalWindowCount)
    }

    func test_appIconSortMode_roundTripsAcrossReconstruction() {
        store.appIconSortMode = .alphabetical
        XCTAssertEqual(NameStore(defaults: defaults).appIconSortMode, .alphabetical)
    }

    func test_appIconSortMode_invalidStoredValue_fallsBackToDefault() {
        defaults.set("bogus", forKey: "SpaceRenamer.appIconSortMode")
        XCTAssertEqual(NameStore(defaults: defaults).appIconSortMode, .globalWindowCount)
    }

    func test_appIconDisplayMode_defaultsToLeftAligned() {
        XCTAssertEqual(store.appIconDisplayMode, .leftAligned)
        XCTAssertEqual(AppIconDisplayMode.default, .leftAligned)
    }

    func test_appIconDisplayMode_roundTripsAcrossReconstruction() {
        store.appIconDisplayMode = .rightAligned
        XCTAssertEqual(NameStore(defaults: defaults).appIconDisplayMode, .rightAligned)
    }

    func test_appIconDisplayMode_invalidStoredValue_fallsBackToDefault() {
        defaults.set("bogus", forKey: "SpaceRenamer.appIconDisplayMode")
        XCTAssertEqual(NameStore(defaults: defaults).appIconDisplayMode, .leftAligned)
    }

    func test_appIconWindowMode_defaultsToCountersForLeftAlignment() {
        XCTAssertEqual(store.appIconWindowMode, .windowCounters)
        XCTAssertEqual(AppIconWindowMode.default, .windowCounters)
    }

    func test_appIconWindowMode_preservesLegacyRightAlignedAppearance() {
        store.appIconDisplayMode = .rightAligned
        XCTAssertEqual(store.appIconWindowMode, .iconsOnly)
    }

    func test_appIconWindowMode_roundTripsAcrossReconstruction() {
        store.appIconWindowMode = .repeatedIcons
        XCTAssertEqual(NameStore(defaults: defaults).appIconWindowMode, .repeatedIcons)
    }

    func test_appIconWindowMode_invalidStoredValue_fallsBackToDefault() {
        defaults.set("bogus", forKey: "SpaceRenamer.appIconWindowMode")
        XCTAssertEqual(NameStore(defaults: defaults).appIconWindowMode, .windowCounters)
    }

    func test_migrateKeys_movesNamesToNewKeys() {
        store.setName("42", "Research")
        store.setName("7", "Email")
        store.migrateKeys(["42": "UUID-A", "7": "UUID-B"])
        XCTAssertEqual(store.name(for: "UUID-A", defaultOrdinal: 1), "Research")
        XCTAssertEqual(store.name(for: "UUID-B", defaultOrdinal: 2), "Email")
        XCTAssertEqual(store.name(for: "42", defaultOrdinal: 1), "Desktop 1")
        XCTAssertEqual(store.name(for: "7", defaultOrdinal: 2), "Desktop 2")
    }

    func test_migrateKeys_existingNewKeyWins_oldKeyRemoved() {
        store.setName("42", "Stale")
        store.setName("UUID-A", "Fresh")
        store.migrateKeys(["42": "UUID-A"])
        XCTAssertEqual(store.name(for: "UUID-A", defaultOrdinal: 1), "Fresh")
        XCTAssertEqual(store.name(for: "42", defaultOrdinal: 1), "Desktop 1")
    }

    func test_migrateKeys_unmappedEntriesUntouched() {
        store.setName("99", "Orphan")
        store.migrateKeys(["42": "UUID-A"])
        XCTAssertEqual(store.name(for: "99", defaultOrdinal: 3), "Orphan")
    }

    func test_migrateKeys_persistsAcrossReconstruction() {
        store.setName("42", "Research")
        store.migrateKeys(["42": "UUID-A"])
        let reborn = NameStore(defaults: defaults)
        XCTAssertEqual(reborn.name(for: "UUID-A", defaultOrdinal: 1), "Research")
    }

    func test_didMigrateToUUIDKeys_defaultsFalse_thenPersists() {
        XCTAssertFalse(store.didMigrateToUUIDKeys)
        store.didMigrateToUUIDKeys = true
        let reborn = NameStore(defaults: defaults)
        XCTAssertTrue(reborn.didMigrateToUUIDKeys)
    }

    func test_showMissionControlOverlay_defaultsTrue_thenPersistsExplicitFalse() {
        // Default is on; opt-out by writing false must survive reconstruction.
        XCTAssertTrue(store.showMissionControlOverlay)
        store.showMissionControlOverlay = false
        let reborn = NameStore(defaults: defaults)
        XCTAssertFalse(reborn.showMissionControlOverlay)
    }

    func test_overlayShowsAppWindows_defaultsTrue_thenPersistsFalse() {
        XCTAssertTrue(store.overlayShowsAppWindows)
        store.overlayShowsAppWindows = false
        XCTAssertFalse(NameStore(defaults: defaults).overlayShowsAppWindows)
    }

    func test_overlayBackgroundOpacity_defaultsTo70Percent_andPersists() {
        XCTAssertEqual(store.overlayBackgroundOpacity, 0.70, accuracy: 0.001)
        store.overlayBackgroundOpacity = 0.45
        XCTAssertEqual(
            NameStore(defaults: defaults).overlayBackgroundOpacity,
            0.45,
            accuracy: 0.001
        )
    }

    func test_overlayBackgroundOpacity_clampsToSupportedRange() {
        store.overlayBackgroundOpacity = -1
        XCTAssertEqual(store.overlayBackgroundOpacity, 0.10, accuracy: 0.001)
        store.overlayBackgroundOpacity = 2
        XCTAssertEqual(store.overlayBackgroundOpacity, 1.0, accuracy: 0.001)
    }
}
