# Changelog

## 1.3.0 — Workspace Library and Chrome companion

- Adds a dedicated Workspace Library with All, Running, Parked, Pending Moves,
  and By Mac views.
- Models cloud workspaces separately from per-Mac instances and stores immutable
  revisions, so two laptops can work from the same workspace without silently
  overwriting each other.
- Adds explicit Launch, Duplicate, Park, Copy to Mac, and verified Move to Mac
  workflows. A move never parks the source until the destination restore succeeds.
- Parking requires a fresh successful cloud capture, then closes only windows
  that macOS confirms belong to that Space; apps and save prompts remain intact.
- Bundles the Workspace++ Chrome Companion and its signed native messaging host
  inside the app. The companion captures pinned tabs and Chrome tab-group names,
  colours, collapsed state, ordering, and restores them when available.
- Keeps AppleScript Chrome capture as a zero-extension fallback.
- Adds secure Supabase tables for workspaces, instances, revisions, and transfers,
  all protected by forced row-level security and explicit authenticated grants.

All notable changes to this project are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.0] — 2026-08-14

### Fixed
- Automatic cloud sync no longer cancels its own in-flight request or displays
  a misleading red “cancelled” status.

### Added
- App-icon alignment and window representation are now independent settings.
  Both left- and right-aligned layouts can show one icon per app, an icon with
  its window counter, or one repeated app icon for every open window.
- Optional right-aligned app-icon showcase for workspace menu rows. This
  compact mode removes window counts and keeps the most globally used app at
  the far-right edge; the existing detailed left-aligned layout remains the
  default and both modes are selectable in General preferences.
- Workspace menu rows now show compact application icons for windows belonging
  to that Space. A small number beside an icon reports multiple windows from
  the same app; long names and large app sets are bounded with truncation and
  a compact overflow count.
- Workspace categories replace one-off colour selection. Assign Work, Hobby,
  Zen, Misc, Unsorted windows, Personal tasks, Entertainment, Medical, or a
  custom category from each workspace's dropdown.
- A dedicated Categories Preferences tab supports adding, renaming,
  recolouring, and deleting categories. Changes update every assigned
  workspace and are included in cloud sync.
- Preferences is now organised into Workspaces, Categories, General, and
  Cloud Sync tabs.
- Optional Workspace++ accounts and cloud sync for workspace names, colours,
  monitor placement, and per-monitor workspace order. Sync remains local-first,
  works offline, stores sessions in macOS Keychain, and maps a different Mac's
  Spaces by monitor/workspace position when their macOS UUIDs differ.
- Manual **Sync Now** and cloud-authoritative **Restore from Cloud** controls
  in Preferences.
- Dedicated Supabase backend schema with owner-only row-level security. The
  public desktop client contains only a publishable key; no admin/service key.

## [1.1.0] — 2026-08-11

### Added
- **The Workspace++ menu now leads with the display it was opened from.**
  Clicking the label on an external monitor lists that monitor's Spaces first
  and the built-in display's below it, instead of always using a fixed order.
  Per-display mode identifies the clicked label exactly; combined mode falls
  back to the pointer's screen, since macOS mirrors one status item onto every
  menu bar.
- **Move Focused Window** opens a native, keyboard-first workspace picker.
  Search the live Workspace++ names and press Return to move the captured
  window directly to that Space while staying put, or Option-Return to move it
  and follow it to the destination. The picker has its own configurable
  global shortcut and does not require Raycast.
- **Per-workspace banner colours** can be assigned from Preferences. Each
  Mission Control name banner uses its workspace's chosen background colour
  and automatically switches between light and dark text for readability.
- Active workspace names in the menu bar now use their assigned workspace
  colours. Per-display mode updates each monitor independently, while combined
  mode preserves the individual colour of every displayed name.
- Mission Control appearance controls let users choose between a centered name
  band that leaves app windows visible and a full-screen colour wash, and set
  the coloured background opacity from 10 to 100 percent. Text remains fully
  opaque in both layouts.
- Preferences includes a colour-category legend: blue for Work, pink for
  Hobby, green for Empty screens, grey for Mixed, red for Unsorted windows,
  and brown for Personal tasks.

### Fixed
- Move-only now returns to the focused window's exact original managed Space
  instead of inferring it from the monitor. Return navigation is confirmed
  twice after animations settle, preventing a late queued key event from
  leaving the user on a neighbouring Space.
- Mission Control name banners now remain centered and inside the display.
  Names use a consistent large font and wrap into as many as four centered
  lines instead of shrinking long names into small single-line text.

## [1.0.0] — 2026-07-28

### Added
- **Workspace++ public product identity** across the macOS app, Raycast
  extension, documentation, iconography, installer, and GitHub project.
- **Dynamic Raycast search** backed by a live local index. Space names,
  additions, removals, active state, and physical display names update without
  manual Raycast configuration.
- **Per-display menu-bar mode** with one independently sized active Space label
  on each monitor.
- **Combined menu-bar mode** for users who prefer all active display names in a
  single native status item.
- **One-command source installer** that builds and installs Workspace++ and
  imports the Raycast extension when its prerequisites are available.

### Changed
- Active Space names use a sky-blue menu-bar treatment.
- Multi-display parsing and switching tolerate the additional managed-display
  shapes observed on current macOS releases.
- The app is presented as `Workspace++.app` while retaining the historical
  bundle ID, defaults keys, local bridge paths, and Swift module names for
  upgrade compatibility.

### Fixed
- Per-display labels no longer share the longest display's width.
- Removed the invisible native status-item slot that caused excess trailing
  space and intercepted clicks.
- Per-display controls now consume AppKit's hidden 16-point scene-host slot,
  align exactly with the next native menu-bar item, and accept the first click
  from a non-activating panel.

## [0.1.8] — 2026-07-03

### Fixed
- **Fullscreen apps no longer trigger bogus overlay banners.** Entering a fullscreen app (e.g. a YouTube video) flashed a default-named banner over it, and exiting left a stuck "Desktop N" banner on the desktop until the next space switch. Cause: macOS inserts a transient `type = 4` space (the fullscreen tile) mid-list when an app goes fullscreen, and the app treated it as a desktop — phantom menu row, shifted ordinals for later desktops, and an overlay window that got orphaned onto the current desktop when macOS destroyed the tile. Fullscreen tiles are now excluded everywhere except Ctrl+arrow hop counting, where the full traversal order (which *does* pass through tiles) is kept so relative switching stays exact — including switching out of a fullscreen app. *Design Revision 2026-07-03*.

## [0.1.7] — 2026-06-10

### Changed
- **Names and per-desktop hotkeys now survive logout/restart.** Storage is keyed by the space's persistent `uuid` (the identity macOS itself keys per-desktop wallpapers by; the primary desktop, whose uuid is empty, uses a `"primary"` sentinel) instead of the session-scoped `ManagedSpaceID`, which macOS renumbers across sessions. Existing entries are migrated automatically on first launch; entries already orphaned by pre-0.1.7 MSID drift are left as-is (unrecoverable). Closes the long-standing #32 drift limitation. *Design Revision 2026-06-09*.

## [0.1.6] — 2026-06-04

### Changed
- **Mission Control overlay is now on by default.** New installs see the per-Space banners immediately; users who had explicitly disabled it in 0.1.5 keep their choice. (Internally: `NameStore.showMissionControlOverlay` now returns `true` when the key is absent in `UserDefaults`; an explicit `false` still wins.)

## [0.1.5] — 2026-06-04

### Added
- **Mission Control overlay labels** (opt-in: *Preferences ▸ Show name in Mission Control*). One borderless transparent `NSWindow` per Space, pinned to its target Space via the private `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` family (same SkyLight `dlsym` mechanism the read-only `ActiveSpaceReader` already uses; no SIP, no Dock injection, no string-template edits). A continuous low-amplitude opacity `CABasicAnimation` keeps the WindowServer re-rendering so Mission Control's thumbnail snapshot stays current. The active Space's banner shows briefly on switch-in (0.1 s + 0.4 s fade) then hides; the non-active Spaces' banners stay visible so their Mission Control thumbnails include the custom name. *Design Revision 2026-06-04*.

### Known limitation
- The active-Space Mission Control thumbnail can appear without a banner — there's no public macOS signal for "Mission Control just opened" reliable enough to re-show the banner before the snapshot is taken. All non-active thumbnails consistently show their labels.

## [0.1.4] — 2026-05-26

### Changed
- **Swift 6 strict concurrency** adopted at both layers. `Package.swift` declares `swift-tools-version: 6.0` with `.swiftLanguageMode(.v6)` per-target; the app target uses `SWIFT_VERSION: "6.0"`. Build is clean under strict checking — the existing `@MainActor` isolation (D9) was already correct. Two small fixes were needed: `SpaceMonitor.observer` is now `nonisolated(unsafe)` (non-`Sendable` `NSObjectProtocol` read from nonisolated `deinit` at ARC tear-down), and `NameStoreTests` overrides the `async throws` variants of `setUp`/`tearDown` so they inherit the `@MainActor` class's isolation (#26).
- First-run alerts (Accessibility prompt + Mission Control shortcuts warning) are now deferred off the synchronous launch path via `DispatchQueue.main.async`, so the menu-bar status item appears before any modal (#31).

### Fixed
- `xcodegen generate` was silently resetting `CFBundleShortVersionString`/`CFBundleVersion` in `Info.plist` on every run, dropping committed version bumps. Both keys are now pinned in `project.yml`'s `info.properties` so the version survives regeneration.

## [0.1.3] — 2026-05-26

### Added
- Read-only hotkey hint in the status menu: each desktop's assigned global shortcut (set in Preferences) is shown to the right of its name (#50).
- User-selectable switch mode in Preferences: *Use shortcut mode (9 desktops max)* toggles between relative-arrow navigation (default, any desktop) and `Ctrl+1–9` (instant but capped at 9). Modes are runtime-switchable; no relaunch needed (#42).

### Fixed
- Launch-time warning now checks the **active mode's** prerequisite (`Move left/right a space` for arrow mode, `Switch to Desktop N` for shortcut mode) instead of always the latter, which became wrong after the 0.1.2 mechanism pivot.

### Removed
- Dead capacity code left over from the 0.1.2 cap-removal: `ParsedSpace.maxShortcutOrdinal` / `isShortcutAvailable` and the unused desktop-shortcut checker entry points. (The desktop checker was reintroduced cleanly alongside the user-selectable mode in 0.1.3.)

## [0.1.2] — 2026-05-18

### Added
- **Switching is no longer capped at 9 desktops.** The menu lists every desktop and switches to any of them via relative `Ctrl+arrow` ("Move left/right a space") navigation, driven by the live SkyLight reader's ordinal delta (#41).
- Display (monitor) SF Symbol before the active desktop name in the menu bar (#39).
- Preferences window opens centered on screen (#40).

### Notes
- A direct SkyLight write SPI (`CGSManagedDisplaySetCurrentSpace`) was tried first and rejected on real-machine evidence: it only updates the WindowServer's bookkeeping without performing the visible space transition. The relative-arrow mechanism shipped instead uses public Mission Control hotkeys and performs the real animated transition. The full reasoning, including the `Ctrl+Fn` modifier-mask root cause that initially made the arrow path appear broken, is recorded in *Design Revision 2026-05-17c*.

## [0.1.1] — 2026-05-17

### Fixed
- Rows for desktops whose `Ctrl+N` is disabled in System Settings are now greyed with a guidance tooltip instead of silently no-op'ing on click (#38).
- Status menu correctly applies disabled state on items (`NSMenu.autoenablesItems = false`) — AppKit was silently re-enabling manually-disabled items.

## [0.1.0] — 2026-05-17

### Added
- Initial release. Custom desktop names (persisted by `ManagedSpaceID`), click-to-switch from the menu bar, active-desktop name in the menu bar, ⌥-click rename, per-desktop and open-menu global hotkeys, Launch at Login, mode-aware launch warning.
- Active-Space detection via the read-only private SkyLight SPI `CGSCopyManagedDisplaySpaces` (#33).
- Stable self-signed code-signing required for the Accessibility grant to persist across builds (`scripts/create-signing-cert.sh`) (#35).
- Synthesized switch keystrokes posted to `.cghidEventTap` so they reach the WindowServer symbolic-hotkey handler (#36).
