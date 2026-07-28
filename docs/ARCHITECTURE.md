# Workspace++ Architecture

This document is the short, current map of the product. The chronological
design evidence—including experiments that did not work—remains under
`docs/superpowers/`.

## Product boundaries

Workspace++ has two cooperating local components:

1. `Workspace++.app`, a menu-bar-only AppKit application.
2. `RaycastExtension`, a Raycast list command named **Switch Space**.

There is no server. The components communicate through two small files in the
historical Application Support directory:

```text
~/Library/Application Support/Space Renamer/
├── raycast-spaces.json
└── raycast-switch-request.json
```

The directory name is intentionally stable for upgrade compatibility.

## Source layout

```text
Sources/SpaceRenamerCore/
    AppKit-free models, plist parsing, active-Space reading, persistent names,
    switch routing, shortcut checks, and testable switch math.

SpaceRenamerApp/
    AppKit application shell, menu bar, Preferences, hotkeys, overlays,
    Launch at Login, and the local Raycast bridge.

RaycastExtension/
    TypeScript command that searches the app's live local index.

Tests/SpaceRenamerCoreTests/
    Fast deterministic coverage for the core.

project.yml
    Source of truth for the generated Xcode project.
```

## Stable and session identities

- `ManagedSpaceID` is a live WindowServer handle. It can change after logout
  and is used only for operations in the current session.
- `storageID` is the persistent Space UUID, with `primary` as the sentinel for
  the first desktop when macOS supplies an empty UUID.
- Names, per-Space hotkeys, and Raycast requests use `storageID`.

This separation is what lets names survive restarts without sending stale
runtime identifiers through Raycast.

## Active-Space detection

`ActiveSpaceReader` resolves the read-only
`CGSCopyManagedDisplaySpaces` symbol at runtime. macOS's persisted Spaces plist
does not keep its current-Space field live enough for a menu-bar indicator.

The private symbol is read-only. Workspace++ does not use a private write API
to switch Spaces.

## Switching

`SwitcherEngine` resolves the selected stable ID to the current managed ID and
delegates to one of two strategies:

- relative `Control-Left` / `Control-Right` hops for unlimited desktops;
- direct `Control-1` through `Control-9` for shortcut mode.

Both strategies synthesize the public Mission Control shortcuts with `CGEvent`.
Accessibility permission is required for macOS to accept those events.

When displays have separate Spaces, macOS routes Mission Control shortcuts to
the display containing the pointer. The multi-display switcher temporarily
targets the selected display and restores the pointer after the event is
accepted.

## Menu-bar presentation

AppKit mirrors one native `NSStatusItem` across all menu bars, so it cannot show
different text on different displays.

- **Combined mode** uses that native status item.
- **Per-display mode** retains a zero-width native scene anchor and places one
  independently measured, non-activating `NSPanel` control on each display.

The custom panel covers AppKit's otherwise invisible 16-point scene-host slot.
That keeps spacing and hit testing consistent with neighbouring native items.

## Raycast bridge

The app atomically writes `raycast-spaces.json` whenever spaces, names, active
states, or displays change. The extension reads it on every launch.

Selecting a result atomically writes `raycast-switch-request.json` with a unique
request ID and stable Space ID. The app's lightweight local monitor resolves
and performs the switch.

The bridge avoids menu automation, fake keystrokes from Raycast, URL-scheme
races, duplicated configuration, and network access.

## Compatibility policy

The public name is Workspace++, but these historical identifiers remain stable:

- Xcode target and Swift module: `SpaceRenamer` / `SpaceRenamerCore`
- bundle identifier: `com.saint.SpaceRenamer`
- defaults keys: `SpaceRenamer.*`
- signing identity: `SpaceRenamer Dev`
- Application Support directory: `Space Renamer`

Do not rename them casually. A migration must preserve user defaults, Raycast
compatibility, Launch at Login state, and macOS TCC/Accessibility approval.

## Extension points

- Add switch strategies behind `SpaceSwitcher`.
- Add local integrations by consuming the versioned Raycast index document or
  by introducing a new versioned request type.
- Add menu-bar presentation modes behind `MenuBarDisplayMode`.
- Keep parsing and routing logic in `SpaceRenamerCore` so it remains testable
  without AppKit or a live WindowServer.

Any change involving Space identity, private symbols, event delivery, or
multi-display routing should include real-machine validation and a dated design
revision under `docs/superpowers/specs/`.
