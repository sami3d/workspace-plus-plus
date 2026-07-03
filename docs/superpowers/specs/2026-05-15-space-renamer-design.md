# Space Renamer — Design

A macOS menu-bar app that gives Mission Control Spaces human-readable names, shows the active Space's custom name in the menu bar, lets the user switch Spaces by clicking a menu entry or pressing a global hotkey, and persists names across reorders and reboots.

## Problem

macOS Spaces are always labeled "Desktop 1", "Desktop 2", … in Mission Control, and the label cannot be changed through any public Apple API. Users who organize work across multiple Spaces (e.g. "Research", "Email", "Code") have no way to see or jump to a Space by name.

## Goals

- Show the **active Space's custom name** in the menu bar at all times.
- Present a **menu** listing every Space with its custom name; clicking a row switches to that Space.
- Support **global keyboard shortcuts** — both per-Space (jump directly) and a single one to open the menu.
- **Persist names across Space reorders** (a renamed Space stays renamed even if dragged to a different position in Mission Control).
- **No private APIs.** App must remain functional across macOS point updates without code changes.

## Non-Goals (v1)

- Renaming the label that appears *inside* Mission Control itself. (Impossible without private SkyLight APIs.)
- Per-display Space stacks when "Displays have separate Spaces" is enabled — v1 tracks the primary display only.
- Cross-Mac sync of names (iCloud / settings sync).
- App Sandbox / App Store distribution. (Reading `com.apple.spaces.plist` and registering global hotkeys are not sandbox-friendly.)

## Key Decisions

| # | Decision | Alternative considered | Why |
|---|---|---|---|
| D1 | **Identify Spaces by `ManagedSpaceID`** (the integer space id) read from `~/Library/Preferences/com.apple.spaces.plist` | Identify by `uuid` (original choice); by ordinal index (1, 2, 3…) | Names must survive Space reorders, so the key must be position-independent. The `uuid` field was the original choice but the real plist shows macOS leaves it **empty (`""`) for the default desktop** (and only assigns UUIDs to additional spaces); `ManagedSpaceID`/`id64` is non-empty, unique, and present for every space including the default and in `Current Space`. Indices are not stable across reorders. See *Design Revision 2026-05-15*. |
| D2 | **Switch Spaces by synthesizing `Ctrl+N` `CGEvent`s** (public); **detect the active Space via read-only private SkyLight `CGSCopyManagedDisplaySpaces`** | Switching: private SkyLight `CGSManagedDisplaySetCurrentSpace`. Active detection: read `Current Space` from `com.apple.spaces.plist` (original choice). | *Switching* stays public CGEvent (trade-off: user must keep "Switch to Desktop N" shortcuts enabled). *Active-Space detection* originally read the plist, but macOS does **not** update `com.apple.spaces.plist`'s `Current Space` on switch (proven on a real machine: notification fires, file unchanged, value frozen across switches) — so a read-only private SkyLight call is required to track the active Space live (user-approved). See *Design Revision 2026-05-17*. **Switching** originally synthesized `Ctrl+N` (public, but macOS only defines "Switch to Desktop N" symbolic hotkeys for desktops 1–9, hard-capping switchability at 9); revised to **relative `Ctrl+←`/`Ctrl+→` ("Move left/right a space") navigation** driven by the read-only SkyLight reader's ordinal delta — uncapped, a real animated transition, no write SPI — see *Design Revision 2026-05-17c*. Both relative-arrow and `Ctrl+digit` are now **user-selectable** in Preferences (`SwitchMode`, default arrow) — see *Design Revision 2026-05-18*. |
| D3 | **Custom global hotkeys via Carbon `RegisterEventHotKey`** | NSEvent local monitor (only works in-app), CGEventTap (more invasive, needs more permissions) | Standard pattern; works system-wide; reliable. |
| D4 | **Inline rename via right-click → `NSAlert` text-field popover** | Dedicated rename window | Lowest-friction UX; user explicitly chose minimal inline. |
| D5 | **Mini Preferences window for hotkey assignment** | Inline hotkey recording in the menu | `NSMenu` dismisses on modifier keypress, making in-menu recording unreliable. |
| D6 | **Swift + AppKit** (`NSStatusItem`, `NSMenu`, `NSAlert`, AppKit window) | SwiftUI `MenuBarExtra` | AppKit gives finer control over status-item and menu quirks; SwiftUI's menu bar API is less mature. |
| D7 | **Bar title shows the active Space's custom name** | Just an icon | User requested name; gives at-a-glance feedback even when menu is closed. |
| D8 | **macOS 13+ minimum** | Older macOS | Allows `SMAppService` for Launch-at-Login and modern Swift concurrency. |
| D9 | **`@MainActor`-isolate the stateful Core** (`NameStore`, `SpaceMonitor`, `SwitcherEngine`, `OrdinalLookup`); pure/stateless types (`SpacesPlistParser`, `KeystrokeSynthesizing`, `SystemShortcutChecker`) stay non-isolated | `os_unfair_lock`/serial-queue locking; `actor` types | App is a main-thread-driven AppKit menu-bar app. `@MainActor` compiler-enforces "`reload()` & `@Published` mutation are main-only", serializes `NameStore`'s non-atomic UserDefaults read-modify-write, and keeps Combine→AppKit observation correct — least complexity. Locks over-engineer it; `actor`s fight `@Published` + synchronous menu builds. Swift 5 mode initially retained; Swift 6 strict concurrency now adopted at both layers (Core via `.swiftLanguageMode(.v6)`, app target via `SWIFT_VERSION: "6.0"`) and builds clean. See *Design Revisions 2026-05-16* and *2026-05-26*. |

### Design Revision — 2026-05-15 (identity model)

The original design (and brainstorm) chose **`uuid`** as the per-Space identity key (then "Option B"). During Phase A implementation, inspection of the real `~/Library/Preferences/com.apple.spaces.plist` revealed that macOS does **not** assign a UUID to the primary/default desktop — its `uuid` is the empty string `""`, and `Current Space.uuid` is `""` whenever the default desktop is active. Only *additional* spaces receive UUIDs. Keying custom names by `uuid` therefore breaks the feature for the default desktop (no stable name; active-state undetectable).

Empirical capture (4 spaces, default desktop active):

| slot | `uuid` | `ManagedSpaceID` / `id64` |
|---|---|---|
| 0 (default, active) | `''` | 1 |
| 1 | `9DD24797-…` | 3 |
| 2 | `8B3CC061-…` | 4 |
| 3 | `B39FF9FA-…` | 5 |

**Resolution (user-approved):** the per-Space identity key is now the **decimal-string form of `ManagedSpaceID`** (e.g. `"1"`, `"3"`). It is non-empty, unique, present for every space and in `Current Space`, and position-independent (still survives reorders — the original Option-B goal). It is stored as a `String` so `NameStore` and the rest of the pipeline stay string-keyed with minimal churn.

**Open verification (deferred to Phase B smoke test):** confirm `ManagedSpaceID` stability across logout/reboot and space delete-then-recreate.

The Architecture, Components, Data Flow, and Testing sections below have been updated in-place to the new terminology (`ParsedSpace.id`, `activeID`, `spaceID`, `ManagedSpaceID`); no read-through substitution is required. Any remaining literal "uuid" refers to the raw plist field (now unused for identity) or unrelated contexts (e.g. test-suite name randomizers).

### Design Revision — 2026-05-16 (threading model)

Phase A left the Core's threading contract undefined (the final Phase A review flagged `SpaceMonitor.reload()`/`@Published` mutable from any thread and `NameStore`'s non-atomic UserDefaults read-modify-write). Resolved in Phase B task #18 (see D9): `NameStore`, `SpaceMonitor`, `SwitcherEngine`, and the `OrdinalLookup` protocol are `@MainActor`; `SpacesPlistParser`, `KeystrokeSynthesizing`/`CGKeystrokeSynthesizer`, `SystemShortcutChecker` stay non-isolated (pure/stateless — callable from `@MainActor` safely). `SpaceMonitor`'s notification observer hops via `Task { @MainActor in … }` (macOS-13-safe; no `MainActor.assumeIsolated`). Consequences for Phase B: construct `NameStore`/`SpaceMonitor`/`SwitcherEngine` in a main-actor context, and inject a named `UserDefaults` suite into `NameStore` (concrete suite name fixed with the app bundle id; `.standard` default retained only for tests). `swift-tools-version: 5.10` / Swift 5 language mode retained; full Swift 6 strict-concurrency adoption (incl. the `deinit`-touches-isolated-`observer` and unstructured-`Task` gaps) is deferred to the Xcode app-target task and separately tracked.

### Design Revision — 2026-05-17 (active-Space detection)

Phase B real-machine debugging proved that macOS does **not** update `~/Library/Preferences/com.apple.spaces.plist`'s `Current Space` on a Space switch: `activeSpaceDidChangeNotification` fires, `SpaceMonitor.reload()` runs, the file mtime stays frozen, and the parsed active id never changes across multiple real switches. The plist's `Current Space` is written only lazily (space add/remove/logout). So the original plan to derive the active Space from the plist (D1/D2) cannot satisfy D7 (menu-bar shows the active desktop's name). There is no robust *public* API for the current Space id.

**Resolution (user-approved):** revise D2. *Switching* stays public (synthesized `Ctrl+digit`). *Active-Space detection* uses the **read-only private SkyLight SPI** `CGSCopyManagedDisplaySpaces(CGSMainConnectionID())` (resolved via `dlsym` on `/System/Library/PrivateFrameworks/SkyLight.framework`), which was empirically verified to reflect the active Space's `ManagedSpaceID` in real time (probe: it tracked `4 → 1 → 4` in lockstep with switches while the plist stayed `4`). It is isolated behind an `ActiveSpaceReading` protocol (one SPI call site; unit-tested via a fake). The plist `Spaces` array is still used for the Space *list/order* (it *is* updated on structural changes). Accepted trade-off: SkyLight SPI is private and could change across major macOS releases (the app is already non-sandboxed / non-App-Store per Non-Goals and already synthesizes input events, so this is consistent with its nature).

### Design Revision — 2026-05-17b (switching delivery + signing)

Phase B real-machine debugging found desktop switching had three stacked causes (all fixed): (1) the app never requested Accessibility — now `AppDelegate` calls `AXIsProcessTrustedWithOptions(prompt:)` at launch and guides the user (the spec's Accessibility Edge Case, now implemented); (2) **ad-hoc signing** (`CODE_SIGN_IDENTITY "-"`) gives no stable Designated Requirement, so macOS TCC never honors the Accessibility grant and synthesized events are silently dropped — the app is now signed with a **stable self-signed identity** (`"SpaceRenamer Dev"`; `project.yml` `CODE_SIGN_STYLE Manual`; recreate the keychain cert with `scripts/create-signing-cert.sh`), giving a cert-anchored DR so the grant survives rebuilds; (3) keystrokes were posted to `.cgAnnotatedSessionEventTap`, which is **downstream of the WindowServer "Switch to Desktop N" symbolic-hotkey handler** — `CGKeystrokeSynthesizer` now posts to **`.cghidEventTap`** so the synthesized Ctrl+digit is processed like a real keypress and triggers the shortcut (D2's CGEvent approach stays public; only the tap changed). Verified end-to-end on a real machine.

### Design Revision — 2026-05-17c (switching delivery: relative Ctrl+arrow navigation, uncapped)

User reported the app cannot switch to a desktop beyond #9. This is inherent to D2's original delivery mechanism, not a bug: switching synthesized `Ctrl+digit`, which triggers macOS's built-in "Switch to Desktop N" symbolic hotkeys, and macOS defines those **only for desktops 1–9** (`AppleSymbolicHotKeys` IDs 118–126). There is no "Switch to Desktop 10" hotkey to synthesize, so `SwitcherEngine` hard-capped at `ParsedSpace.maxShortcutOrdinal = 9`. (Renaming/display was never capped — Spaces are enumerated via SkyLight and keyed by `ManagedSpaceID`.)

**Attempt 1 — SkyLight *write* SPI (rejected on real-machine evidence).** Tried `CGSManagedDisplaySetCurrentSpace(cid, displayIdentifier, spaceID)`. Diagnostic logging proved it only rewrites the WindowServer's *"Current Space" bookkeeping* (so `CGSCopyManagedDisplaySpaces` — and thus the menu-bar name — immediately reflects the target) **without performing the visible space transition**: every `BEFORE→AFTER` flipped the current id but the screen frequently didn't move. This is the documented unreliability of that SPI (a fully reliable direct write needs the yabai-style scripting addition, which requires partially disabling SIP — out of scope). Rejected; `SkyLightSpaceSwitcher` removed.

**Resolution (shipped) — relative `Ctrl+arrow` navigation.** Switch by synthesizing the **"Move left/right a space"** symbolic hotkeys (`Ctrl+←`/`Ctrl+→`): read the live ordered Spaces + active Space from the existing read-only SkyLight reader (D2's `ActiveSpaceReading`, unchanged — *no write SPI*), compute the signed ordinal delta `target − active`, and post `|delta|` paced arrow chords. These go through the **same** WindowServer symbolic-hotkey path as a real keypress, so the switch is the real animated transition, for **any** number of desktops, no SIP. Isolated behind the `SpaceSwitching` protocol (`RelativeArrowSpaceSwitcher`). `SwitcherEngine` keeps the `lookup` check (rejects `unknownSpace`; preserves the weak-retention contract) then delegates; if the live ordinals can't be resolved or the event source is unavailable it throws `switchUnavailable` (replaces `ordinalOutOfRange`; **there is no `Ctrl+digit` fallback** — the mechanism is uniform). The menu no longer disables desktops >9. `ParsedSpace.maxShortcutOrdinal`/`isShortcutAvailable` and `SystemShortcutChecker` are now **unused by switching** (retained, still unit-tested; harmless).

**Root-cause subtlety (cost two fix cycles; recorded so it is never re-derived):** synthesized `Ctrl+arrow` did nothing even though "Move a space" was *enabled*. Arrow keys are *secondary-function* keys, so macOS registers that hotkey with **Control + Fn** (`com.apple.symbolichotkeys` modifier mask `8650752` = `0x040000 | 0x800000`), whereas "Switch to Desktop N" uses pure Control (`262144`). A `.maskControl`-only `CGEvent` matched the digit hotkey (why `Ctrl+digit` always worked) but **never** matched the arrow hotkey. Fix: arrow chords are posted with `[.maskControl, .maskSecondaryFn]` (digit path stays pure Control). Second confound during debugging: the abandoned write-SPI experiment had left the WindowServer's "Current Space" desynced from the visible screen, feeding `SwitcherEngine` a bogus delta baseline (apparent "still broken" after the correct fix); a single real move re-syncs it. **This cannot recur in production** — with the write SPI gone every switch is a real move, so screen and bookkeeping (hence the reader's baseline) always advance together. Verified end-to-end on a real machine (keyboard *and* app, including >9). The keystroke effect is not unit-testable; the delta/direction/count logic is (`RelativeArrowSpaceSwitcherTests`).

### Design Revision — 2026-05-18 (user-selectable switch mode)

The 17c arrow mechanism does `|delta|` paced keystrokes (≈1 s for a far hop); `Ctrl+digit` is a single instant keystroke for desktops 1–9. Rather than pick one, the delivery is now **user-selectable in Preferences** (`SwitchMode`, persisted in `NameStore`; default `.arrow` — existing behavior unchanged unless opted out of):

- `.arrow` — `RelativeArrowSpaceSwitcher` (17c): any desktop, multi-hop animated.
- `.ctrlDigit` — `CtrlDigitSpaceSwitcher`: one `Ctrl+1…9` keystroke; returns `false` for ordinal >9 (no such macOS hotkey).

`ModeRoutingSpaceSwitcher` (a `SpaceSwitching` wrapping both) reads the mode **per call** via an injected `() -> SwitchMode`, so the toggle takes effect on the next switch with no relaunch (only one mode is active at a time, but switching the setting is live). `SwitcherEngine` is unchanged — it just gets the routing switcher. Mode-dependent UX restored (partly reviving code removed in `334248b`, now legitimately used per-mode): the status menu greys desktops not in `SystemShortcutChecker.reachableSwitchToDesktopOrdinals()` **only** in `.ctrlDigit` mode (incl. all >9); the one-shot launch warning checks the *active mode's* prerequisite (`spaceMoveShortcutsEnabled` for arrow, `switchToDesktopShortcutsEnabled` for ctrlDigit) with mode-specific guidance. Known limitation: the launch warning is one-shot at startup, so changing mode mid-session won't re-warn until next launch. `ParsedSpace.maxShortcutOrdinal`/`isShortcutAvailable` stay removed (the menu uses `reachableSwitchToDesktopOrdinals`, not the ordinal cap). Core logic fully unit-tested (`CtrlDigitSpaceSwitcherTests`, `ModeRoutingSpaceSwitcherTests`, restored `SystemShortcutChecker` tests, `NameStore.switchMode`); both modes verified on a real machine.

### Design Revision — 2026-05-26 (Swift 6 strict concurrency, both layers)

D9 deferred Swift 6 strict concurrency until "the Xcode app target is created". With the app shipping (v0.1.3), that gate is past — both layers now build under Swift 6 mode: `Package.swift` declares `swift-tools-version: 6.0` with `.swiftLanguageMode(.v6)` per-target, and `project.yml` sets `SWIFT_VERSION: "6.0"` for the app target. Build is clean (no warnings) under Swift 6 strict checking — the `@MainActor`-isolation of `NameStore`/`SpaceMonitor`/`SwitcherEngine`/`OrdinalLookup` (D9) was already correct.

Two surface-level diagnostics needed fixing: (1) `SpaceMonitor.observer` (an `NSObjectProtocol?` referencing a non-`Sendable` Objective-C type) is now `nonisolated(unsafe)` because the property is mutated only on the main actor in `init` but read from the nonisolated `deinit` at ARC tear-down — the documented escape hatch for this exact pattern; (2) `NameStoreTests` (a `@MainActor` `XCTestCase`) overrides `setUp() async throws` / `tearDown() async throws` instead of the sync variants, so the overrides inherit the class's main-actor isolation. Trues up D9 (no longer "deferred"). Discovered and fixed in the same change: `info.properties` in `project.yml` now pins `CFBundleShortVersionString` / `CFBundleVersion`, because `xcodegen generate` was silently resetting them to `1.0`/`1` on every regenerate, dropping the committed version bump.

### Design Revision — 2026-06-04 (Mission Control overlay labels — per-Space window)

User asked: can the custom name appear in Mission Control's space-overview thumbnails. Direct answer: macOS owns the *"Desktop N"* text strip under each thumbnail and gives no public lever to override it. But the *inside* of each thumbnail mini-renders that Space's window contents — so a per-Space window with a giant centered banner becomes a visible label inside the thumbnail. Same technique as `gitmichaelqiu/DesktopRenamer` (which is what prompted this revision); no SIP, no Dock injection, no string-template edits.

**Mechanism (opt-out via Preferences "Show name in Mission Control"; default on post-0.1.5):**
- A new Core component `SpaceWindowAnchoring` / `CGSSpaceWindowAnchor` `dlsym`s two write SkyLight calls — `CGSAddWindowsToSpaces` and `CGSRemoveWindowsFromSpaces` — to pin a fresh `NSWindow` from its default landing Space onto a target `ManagedSpaceID`. These are the known-stable window-placement use of the CGS write family (yabai et al. depend on them); distinct from `CGSManagedDisplaySetCurrentSpace` which we rejected for *switching* in 2026-05-17c because it only updated bookkeeping. Window placement is a fundamentally different semantic (no "current state to mutate", just "add/remove from a set"), and works reliably without SIP.
- An app-target `SpaceLabelWindow` is a borderless, click-through (`ignoresMouseEvents = true`), floating-level `NSWindow` with dark-glass `NSVisualEffectView` content and a 150 pt bold centered `NSTextField`. `collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary, .ignoresCycle]` — pinned to one Space; visible over fullscreen apps so their thumbnails get the label too; explicitly *excludes* `.canJoinAllSpaces` (would defeat the anchoring) and `.transient` (would suppress the Mission Control snapshot).
- A continuous `CABasicAnimation` on `opacity` (`1.0 ↔ 0.999`, 1 s, autoreverses, infinite) is installed as a "rendering loop" — the documented workaround that forces WindowServer to keep re-rendering the window so Mission Control's snapshot of that Space picks up current content instead of a stale frame.
- An app-target `SpaceLabelOverlayManager` owns one `SpaceLabelWindow` per known Space, observes `SpaceMonitor.$spaces`/`$activeID` and a new `NotificationCenter` notification `Notification.Name.spaceRenamerNameDidChange` posted from `NameStore.setName`/`forget` (so renames flow into the overlay without coupling through any specific UI controller).
- Visibility model (user-iterated): the **active Space's** banner is shown briefly on switch-in (0.1 s visible + 0.4 s fade out — knobs at `SpaceLabelWindow.fadeAfterSeconds` / `fadeDuration`); the **non-active Spaces'** banners stay at `alphaValue = 1` so Mission Control's snapshot of their thumbnails picks them up. Attempted active-Space Mission Control visibility via `NSWindow.didChangeOcclusionStateNotification`: the notification either doesn't fire when MC opens or fires after the snapshot is taken — confirmed visually (active-Space thumbnail is consistently empty regardless of snap-to-alpha-1 timing). Accepted trade-off: the active-Space thumbnail can appear without a banner. The only fully-reliable alternative is `alphaValue = 1` always, which makes the banner permanent on the user's desktop (DesktopRenamer's compromise: keep it always-visible but smaller and corner-docked). Recorded as a known limitation rather than chasing further detection heuristics.

Tests: `NameStore.showMissionControlOverlay` round-trips through UserDefaults (default false). The CGS write SPIs themselves can't be unit-tested (effect is window-server state); verified on the real machine end-to-end (banners appear in every non-active thumbnail; active-Space flash on switch-in fades on schedule).

### Design Revision — 2026-06-09 (restart-stable persistence keys: uuid / "primary")

Closes the `ManagedSpaceID`-drift limitation (#32, previously accepted as known): names and per-desktop hotkeys were keyed by MSID, which macOS renumbers across logout/restart (real-machine evidence: a 6-desktop machine carrying MSIDs 5, 1, 8, 657, 114, 110 plus orphaned name entries for long-dead MSIDs 3, 4, 79).

**Key insight:** every space dict — in both `CGSCopyManagedDisplaySpaces` and `com.apple.spaces.plist` — carries a `uuid` field that *is* macOS's own persistent space identity (it's what per-desktop wallpapers are keyed by, and wallpapers survive reboots). The sole exception: the primary desktop's `uuid` is the empty string (it carries `wsid = 1` instead).

**Mechanism:**
- `ParsedSpace` now carries `uuid` and exposes `storageID` — the uuid, or the `"primary"` sentinel when empty. Identity roles are split: **MSID (`id`) stays the session-scoped runtime handle** (switching SPIs, `CGSAddWindowsToSpaces` anchoring, `activeID` comparison); **`storageID` is the persistence key** (NameStore names, `KeyboardShortcuts.Name.space(_:)` hotkeys, the `.spaceRenamerNameDidChange` userinfo id).
- One-shot launch migration in `AppDelegate`, gated by `NameStore.didMigrateToUUIDKeys`: builds the current MSID→storageID remap from the live snapshot and rewrites both stores (`NameStore.migrateKeys`, `HotkeyManager.migrateSpaceShortcuts`). An entry already present under the new key wins; old keys are removed; unmapped (stale) entries are left untouched. On a degraded launch (no spaces) the flag stays unset and migration retries next launch.

**Accepted residuals:** (1) a desktop deleted and re-created gets a fresh uuid — its name is forgotten, which is semantically correct (it *is* a new desktop); (2) entries orphaned by drift *before* this revision can't be recovered (the old MSIDs are unmappable) and remain inert in the store; (3) the `"primary"` sentinel assumes one empty-uuid space per managed display — true for the primary display we manage (multi-display remains out of scope).

Verified on the real machine: all six live desktops' names and both recorded hotkeys moved to uuid keys (`primary` for Desktop 1) on first launch; stale entries untouched; flag set. Tests: parser uuid extraction + `storageID` sentinel rule, `migrateKeys` semantics (move, new-key-wins, unmapped-untouched, persistence), `didMigrateToUUIDKeys` round-trip.

### Design Revision — 2026-07-03 (fullscreen-app spaces are not desktops: type filter + traversal order)

Fixes the fullscreen-badge bug: entering a fullscreen app (e.g. a YouTube video) flashed a default-named banner over the video for ~1 s, and exiting left a stuck wrong-name banner on the desktop until the next space switch.

**Root cause (real-machine evidence):** neither the SkyLight reader nor the plist parser filtered by space `type`. Fullscreening an app makes macOS create a transient `type = 4` tile space — captured live: `MSID=353 type=4 keys={…,TileLayoutManager,pid,fs_wid,…}` — **inserted mid-array right after the space it was entered from**, and it becomes the Current Space. The app treated it as a desktop: (a) the overlay manager created a banner window for it and flashed it on switch-in (symptom 1); (b) when macOS destroyed the tile on fullscreen-exit, that banner window — by then in always-visible non-active mode — was dumped onto the current desktop with no `activeSpaceDidChange` to trigger a re-sync, so it sat at full alpha showing "Desktop N" until the next manual space switch (symptom 2); (c) every desktop after the insertion point had its ordinal shifted by one while the tile existed.

**Mechanism:**
- `ParsedSpaces.spaces` now contains **user desktops only** (`type == 0`; absent key ⇒ desktop, keeping old fixtures/plists valid), with ordinals contiguous over desktops. Applied identically in `SkyLightActiveSpaceReader.snapshot()` and `SpacesPlistParser.parse`.
- `ParsedSpaces` gains **`navigationIDs`** — the *full* MSID order including tiles (defaults to `spaces.map(\.id)` when not supplied). Rationale: Ctrl+←/→ ("Move left/right a space") hops *through* fullscreen tiles, so `RelativeArrowSpaceSwitcher` computes hop deltas from positions in `navigationIDs`, not desktop ordinals — otherwise hops across a tile would undershoot. This also keeps switching *out of* a fullscreen app working (the active id is the tile's MSID, absent from `spaces` but present in `navigationIDs`).
- `activeID` is deliberately **not** remapped when the user is in a fullscreen tile: the menu-bar title falls back to the generic "Desktop", and all desktop banners are non-active (correct for Mission Control thumbnails). `CtrlDigitSpaceSwitcher` keeps desktop ordinals — the system "Switch to Desktop N" hotkeys count desktops only.

Verified live: during fullscreen the snapshot shows 6 desktops + 1 tile with `Current Space` type 4; the desktops-only list never contains the tile, so no banner window is ever created for it — both symptoms are eliminated structurally (the overlay manager creates windows only for `spaces` entries). Tests: parser excludes type-4 from `spaces` with contiguous ordinals, includes it in `navigationIDs` in traversal order, preserves the tile `activeID`; arrow switcher counts the extra hop across a tile and switches out of a tile via traversal order.

## Architecture

Six components, each owning one concern. All communicate via a small set of well-defined inputs/outputs; no shared mutable state.

```
                ┌──────────────────────┐
                │  com.apple.spaces    │
                │       .plist         │
                └──────────┬───────────┘
                           │ read on change
                           ▼
┌────────────────┐   ┌──────────────┐   ┌──────────────────┐
│ NSWorkspace    │──▶│ SpaceMonitor │──▶│ MenuBarController│──┐
│ activeSpaceDid │   │  (IDs +      │   │  (NSStatusItem,  │  │
│ ChangeNotif.   │   │   ordinals)  │   │   NSMenu)        │  │
└────────────────┘   └──────┬───────┘   └────────┬─────────┘  │
                            │                    │            │ click
                            │                    ▼            │
                            │             ┌──────────────┐    │
                            │             │  NameStore   │◀───┘
                            │             │ (UserDefaults│
                            │             │  ID→name,    │
                            │             │  ID→hotkey)  │
                            │             └──────┬───────┘
                            │                    │
                            ▼                    ▼
                     ┌──────────────┐    ┌──────────────┐
                     │ Switcher     │◀───│ Hotkey       │
                     │ Engine       │    │ Manager      │
                     │ (CGEvent     │    │ (Carbon hot- │
                     │  Ctrl+N)     │    │  key regs)   │
                     └──────────────┘    └──────────────┘
                            │                    ▲
                            │                    │
                            │            ┌──────────────────┐
                            │            │ Preferences      │
                            │            │ Window (hotkey   │
                            │            │  recorder, L@L)  │
                            │            └──────────────────┘
```

### Components

**SpaceMonitor**
- Reads `~/Library/Preferences/com.apple.spaces.plist` and parses the `SpacesDisplayConfiguration → Management Data → Monitors[0]` dict:
  - `Spaces` array → ordered list of Space dicts; identity = the integer `ManagedSpaceID` (rendered as a decimal string; see D1 / Design Revision). Ordinal = array index + 1.
  - `Current Space` in the plist is **ignored** — macOS does not update it on switch (see D2 / Design Revision 2026-05-17).
- The Spaces *list/order* is parsed by the pure `SpacesPlistParser` into `ParsedSpace { id: String, ordinal: Int }` (the plist's `Spaces` array *is* updated on add/remove/reorder). (`ParsedSpace.maxShortcutOrdinal`/`isShortcutAvailable` were **removed** in `334248b` — switching is uncapped; the `.ctrlDigit` mode's menu greying uses `SystemShortcutChecker.reachableSwitchToDesktopOrdinals()` instead. `SystemShortcutChecker` is **in use again** post-*Design Revision 2026-05-18*: the move-a-space check gates the arrow-mode launch warning, the desktop checks gate ctrlDigit-mode greying + its launch warning.) The **active Space** comes from an injected `ActiveSpaceReading` (read-only private SkyLight `CGSCopyManagedDisplaySpaces`), not the plist. `SpaceMonitor` exposes `@Published spaces: [ParsedSpace]`, `@Published activeID: String?` (from the SkyLight reader), `@Published lastLoadError: String?` (`nil` = healthy; non-`nil` = the last plist read/parse failed and `spaces` is retained stale), and `ordinal(for id: String) -> Int?`.
- Subscribes to `NSWorkspace.shared.notificationCenter` `activeSpaceDidChangeNotification`; on each fire it refreshes `activeID` from the SkyLight reader (and re-reads the plist list). The notification doesn't carry the new Space's identity directly.
- Note: macOS caches this plist in memory and may not flush to disk immediately. `SpaceMonitor` calls `CFPreferencesAppSynchronize("com.apple.spaces")` before each read to force a fresh copy.
- Publishes changes via a delegate / Combine subject so other components react.

**NameStore**
- Persists, keyed by Space ID (decimal `ManagedSpaceID`), in `UserDefaults`:
  - `SpaceID → customName: String`
  - `SpaceID → hotkey: KeyCombo` (Phase B; `KeyCombo` = keyCode + modifier flags)
  - `openMenuHotkey: KeyCombo?` (Phase B)
- Provides `name(for spaceID: String, defaultOrdinal: Int) -> String` returning the custom name or `"Desktop \(defaultOrdinal)"` fallback.
- Offers `forget(_ spaceID:)` to remove a Space's stored name (and, in Phase B, hotkey) — used when a Space no longer exists and the user wants to clean up.

**MenuBarController**
- Owns the `NSStatusItem`. Sets `button.title` to the active Space's name; updates on every `SpaceMonitor` change.
- Builds the `NSMenu` from `SpaceMonitor.currentSpaces` zipped with `NameStore`:
  - One `NSMenuItem` per Space, showing the custom name. Active Space gets a checkmark.
  - Right-click on a row opens a context menu with **Rename…** and **Forget Name** actions.
  - Separator, then **Preferences…**, **Launch at Login** (toggle), **Quit**.
- Click on a row → `SwitcherEngine.switch(to: id)`.

**SwitcherEngine**
- Single method: `switch(to id: String) throws`.
- Looks up the Space ID's current ordinal via `SpaceMonitor` (an injected `OrdinalLookup`). If not found → throws `unknownSpace`.
- If ordinal > 9 → throws `ordinalOutOfRange` (only `Ctrl+1`..`Ctrl+9` exist).
- Otherwise synthesizes `Ctrl+<digit>` via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` for both keyDown and keyUp, posts on `cgAnnotatedSessionEventTap`.
- Behind a `KeystrokeSynthesizing` protocol so tests can verify intent without posting real events.

**HotkeyManager**
- Wraps Carbon `RegisterEventHotKey` / `UnregisterEventHotKey`.
- On launch: reads `NameStore` and registers one hotkey per assigned Space, plus the "open menu" hotkey if set.
- Exposes `register(keyCombo:, action: () -> Void) -> HotkeyHandle` and `unregister(_ handle: HotkeyHandle)`.
- Listens for `NameStore` changes (via notification or Combine) to add/remove registrations as the user edits hotkeys.

**PreferencesWindowController**
- Plain AppKit window opened from the menu.
- A `NSTableView` with one row per detected Space: name (read-only label — renaming happens inline in the menu), key-recorder cell that captures a new shortcut on focus + keypress.
- Separate field at the top: "Open menu" hotkey.
- "Launch at Login" checkbox bound to `SMAppService.mainApp`.

## Data Flow

### Boot
1. `LSUIElement = true` in Info.plist → no Dock icon.
2. App delegate instantiates `NameStore`, `SpaceMonitor`, `SwitcherEngine`, `HotkeyManager`, `MenuBarController`.
3. `SpaceMonitor` does initial plist read; `HotkeyManager` registers hotkeys from `NameStore`.
4. `MenuBarController` paints the menu and sets bar title to active Space's name.

### Switching by menu click
1. User clicks "Research" → `MenuBarController` → `SwitcherEngine.switch(to: researchID)`.
2. `SwitcherEngine` resolves Space ID → ordinal (say, 2) → posts `Ctrl+2`.
3. macOS switches Space → `activeSpaceDidChangeNotification` fires → `SpaceMonitor` re-reads → `MenuBarController` updates title to "Research" + checkmark.

### Switching by hotkey
Same as above, but entry point is `HotkeyManager`'s callback for that Space's `KeyCombo`.

### User adds / removes / reorders Spaces in Mission Control
1. macOS posts `activeSpaceDidChangeNotification` (it also fires for layout changes, not just active-space changes).
2. `SpaceMonitor` re-reads plist. New Space IDs appear; missing IDs vanish from `spaces`.
3. `MenuBarController` rebuilds the menu. New Spaces show default names (`Desktop N`). Removed Spaces disappear from the menu but their stored name/hotkey **stay** in `NameStore` (the user can "Forget" them manually).

### Inline rename
1. Right-click row → "Rename…" → `NSAlert` with text field, pre-filled with current name.
2. On OK → `NameStore.setName(spaceID, newName)` → menu rebuilds, bar title updates if affected.

### Hotkey assignment
1. User opens Preferences, focuses the recorder cell for a Space, presses `⌃⌥D`.
2. Recorder captures keyCode + modifiers → `NameStore.setHotkey(spaceID, combo)`.
3. `HotkeyManager` unregisters any previous combo for that Space and registers the new one.

## Edge Cases & Error Handling

| Case | Behavior |
|---|---|
| `Ctrl+N` shortcuts disabled in System Settings | On launch, read `com.apple.symbolichotkeys.plist`; if disabled, show a one-shot alert with a "Open Keyboard Settings" deep link (`x-apple.systempreferences:com.apple.Keyboard-Settings.extension`). Persist a "warned" flag in `UserDefaults` so we don't nag. |
| More than 9 Spaces | In the default `.arrow` mode (Design Revision 2026-05-17c): fully supported — the menu lists **all** Spaces, none disabled, relative `Ctrl+arrow` switches to any. In `.ctrlDigit` mode (Design Revision 2026-05-18): desktops >9 (and any whose `Ctrl+N` isn't enabled/bound) are greyed with a guidance tooltip pointing to the mode toggle. `SwitcherEngine.switch(to:)` throws `.switchUnavailable` only if the active switcher reports it couldn't attempt the switch. |
| Plist unreadable or schema unrecognized | Core: `SpaceMonitor.reload()` sets `@Published lastLoadError` (non-`nil`), **keeps the previously published `spaces`/`activeID` (stale-but-shown)**, and logs via the unified `os.Logger`. App shell (Phase B): when `lastLoadError != nil` it renders the degraded fallback — plain `Desktop 1..N` rows from `NSScreen` heuristics — and disables Space-ID persistence. (Rendering the fallback is app UI; the Core only signals.) |
| Hotkey conflict (`eventHotKeyExistsErr`) | Preferences row shows red ⚠ inline; the new combo is NOT persisted until registration succeeds. |
| Accessibility permission denied | `AXIsProcessTrustedWithOptions(prompt: true)` on first launch. If denied, menu still renders and renames work; switch attempts show a tooltip "Grant Accessibility access in System Settings → Privacy & Security." |
| Multi-display, "Displays have separate Spaces" ON | v1: read only the primary display's Spaces from the plist. Document in README. v2 candidate: full multi-display support with per-display sections in the menu. |
| Wake from sleep / display reconnect | `activeSpaceDidChangeNotification` typically fires on these; if not, the menu is still correct because click-handlers always re-resolve the ordinal at the moment of the click. |

## Testing

### Unit (XCTest, runs in CI)
- **`NameStoreTests`** — round-trip name persistence (hotkeys: Phase B); default-name generation; `forget(_ spaceID:)` removes the stored name; warned-flag persistence.
- **`SpacesPlistParserTests`** — fixture-driven: feed synthetic plists (1 Space, 3 Spaces, 9 Spaces, reordered, and a real-capture fixture with an empty-`uuid` default desktop) and assert the parser produces the expected `[(id, ordinal)]` list + `activeID`, plus negative cases (missing/non-positive `ManagedSpaceID`, missing config/monitors).
- **`SwitcherEngineTests`** — inject a fake `KeystrokeSynthesizing` + fake `OrdinalLookup`; assert that a Space ID at ordinal 3 makes the engine request `Ctrl+3`, that an unknown ID throws `unknownSpace`, and an ordinal > 9 throws `ordinalOutOfRange` — with no keystroke posted on either error path.
- **`HotkeyManagerTests`** — fake the Carbon-wrapping protocol; verify register/unregister calls track `NameStore` mutations.

### Manual smoke checklist (cannot run in CI — needs real Spaces)
1. Launch → active Space's name visible in menu bar.
2. Menu lists all current Spaces with default names.
3. Rename "Desktop 2" → "Research" → name appears in menu and bar.
4. Click a non-active row → screen switches; bar title updates.
5. Add a Space in Mission Control → menu auto-adds it.
6. Reorder Spaces in Mission Control → renamed Space keeps its name (`ManagedSpaceID` tracking).
7. Quit and relaunch → names and hotkeys persist.
8. Assign `⌃⌥D` to "Research" → press from any app → switches.
9. Disable "Switch to Desktop N" in System Settings → relaunch → one-shot warning alert appears.
10. Revoke Accessibility permission → switch attempt → tooltip explains.

## Future Work (Out of Scope for v1)

- Multi-display Spaces (separate Spaces per monitor).
- iCloud sync of names and hotkeys.
- "Move active window to Space X" hotkey.
- Visual HUD overlay on Space switch (similar to volume HUD).
- App Sandbox / Mac App Store distribution (would require dropping `com.apple.spaces.plist` reads and finding a sandbox-safe alternative — likely not possible).

## Project Layout

```
SpaceRenamer/
├── SpaceRenamer.xcodeproj
├── SpaceRenamer/
│   ├── App/
│   │   ├── AppDelegate.swift
│   │   └── Info.plist                  (LSUIElement = YES)
│   ├── Core/
│   │   ├── SpaceMonitor.swift
│   │   ├── SpacesPlistParser.swift
│   │   ├── NameStore.swift
│   │   ├── SwitcherEngine.swift
│   │   ├── KeystrokeSynthesizer.swift
│   │   └── HotkeyManager.swift
│   ├── UI/
│   │   ├── MenuBarController.swift
│   │   ├── RenameAlert.swift
│   │   ├── PreferencesWindowController.swift
│   │   └── KeyComboRecorderView.swift
│   └── Resources/
│       └── Assets.xcassets
└── SpaceRenamerTests/
    ├── NameStoreTests.swift
    ├── SpacesPlistParserTests.swift
    ├── SwitcherEngineTests.swift
    ├── HotkeyManagerTests.swift
    └── Fixtures/
        ├── spaces-1.plist
        ├── spaces-3.plist
        ├── spaces-9.plist
        └── spaces-reordered.plist
```
