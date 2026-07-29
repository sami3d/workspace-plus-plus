# Workspace++

<p align="center">
  <img src="RaycastExtension/assets/command-icon.png" width="128" alt="Workspace++ icon">
</p>

<p align="center">
  Name, find, and jump between macOS Spaces—across every display.
</p>

<p align="center">
  <a href="https://github.com/sami3d/workspace-plus-plus/actions/workflows/ci.yml"><img src="https://github.com/sami3d/workspace-plus-plus/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-111111" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/license-MIT-3b82f6" alt="MIT License">
</p>

Workspace++ is a local-first macOS menu-bar app for people who use Mission
Control Spaces as real workspaces. Give every Space a memorable name, see the
right name on each monitor, and switch by menu, global shortcut, or dynamic
Raycast search.

The project is a maintained product fork of
[Space Renamer](https://github.com/noobomancer/space-renamer) by Alex Shirov.
Workspace++ retains the original MIT notice and its internal compatibility
identifiers so existing users keep their names, hotkeys, and Accessibility
approval when upgrading.

## Features

### Names that follow the Space

- Rename any desktop with **Option-click** in the menu.
- Names are keyed by macOS's persistent Space UUID, so they survive reordering,
  logout, restart, and monitor changes.
- Add or remove Spaces whenever you like; the menu and Raycast index update
  dynamically.

### Correct multi-display menu bars

- **Each display separately** shows only that monitor's active Space name.
- **Combined on every display** shows all active Space names in one native
  menu-bar item.
- Per-display labels are independently measured, clickable across their full
  width, and aligned to macOS's native status-item spacing.
- A sky-blue label makes the active workspace easy to find without overpowering
  the rest of the menu bar.

### Three ways to switch

1. Open the Workspace++ menu and choose a Space.
2. Assign global shortcuts to individual Spaces or to the menu itself.
3. Open Raycast, run **Switch Space**, type any live Space name, and press
   Return.

The Raycast command reads a small local JSON index written by Workspace++ and
sends the selected stable ID back through a local request file. It does not
scrape the menu bar, automate clicks, use a network service, or maintain a
second list of names.

### Move a focused window directly

- Open **Move Focused Window…** from the Workspace++ menu or assign its global
  shortcut in Preferences.
- Search the live workspace names with the keyboard—no Raycast dependency.
- Press **Return** to move the captured window directly to the selected Space
  while staying in the current workspace, or **Option-Return** to move it and
  follow it to the destination.
- Regular application windows are supported; macOS full-screen and tiled
  windows cannot be reassigned to another desktop.

### Mission Control labels

- Optional large name banners on non-active Mission Control thumbnails.
- A brief switch-in label confirms where you landed.
- Per-Space overlay windows are anchored to the correct physical display.

### Flexible switching engine

- **Move a space** mode uses the system `Control-Left` / `Control-Right`
  shortcuts and supports any number of desktops.
- **Shortcut mode** uses `Control-1` through `Control-9` for direct switching.
- Cross-display switching targets the owning monitor and restores the pointer
  after macOS accepts the shortcut.

### Everyday quality of life

- Launch at Login.
- Live display names and active-state checkmarks.
- Helpful warnings when required Mission Control shortcuts or Accessibility
  permission are missing.
- 82 fast core tests plus CI builds for the AppKit app and Raycast extension.

## Requirements

- macOS 13 or later.
- Xcode 16 or later.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen).
- [Raycast](https://www.raycast.com/) plus Node.js/npm for the optional Raycast
  command.

## Install

The easiest current installation builds Workspace++ locally so macOS can keep a
stable signing identity for Accessibility:

```sh
git clone https://github.com/sami3d/workspace-plus-plus.git
cd workspace-plus-plus
./scripts/install.sh
```

The installer:

1. creates the local signing identity if it is missing;
2. generates and builds `Workspace++.app`;
3. installs it in `/Applications`;
4. imports the bundled Raycast extension when Raycast and npm are available;
5. launches Workspace++.

If Raycast or npm is missing, the app still installs and the script prints the
single command needed to add Raycast later.

There is not yet a notarized binary release. Notarization requires an Apple
Developer Program identity; until that is available, a local source build is
the most reliable way to preserve macOS Accessibility permission between
updates.

## First run

1. Grant **Workspace++** access under **System Settings → Privacy & Security →
   Accessibility**. Workspace++ uses it only to send the same Mission Control
   shortcuts as a physical keyboard.
2. Under **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**,
   enable:
   - **Move left a space** and **Move right a space** for the default unlimited
     mode; or
   - the **Switch to Desktop N** shortcuts used by shortcut mode.
3. Open **Workspace++ → Preferences** to choose:
   - separate or combined menu-bar names;
   - switching mode;
   - Mission Control labels;
   - global shortcuts;
   - the Move Focused Window picker shortcut;
   - Launch at Login.
4. In Raycast, search **Switch Space** and optionally assign it a global
   shortcut.

## Updating

From the cloned repository:

```sh
git pull --ff-only
./scripts/install.sh
```

The historical bundle identifier (`com.saint.SpaceRenamer`), preferences keys,
Application Support folder, and internal Swift module names are intentionally
retained. This compatibility layer prevents an upgrade from discarding existing
names or forcing avoidable permission resets.

## Build and test

```sh
./scripts/create-signing-cert.sh
xcodegen generate

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project SpaceRenamer.xcodeproj -scheme SpaceRenamer \
  -configuration Release -destination 'platform=macOS' build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

cd RaycastExtension
npm ci
npm run lint
npm run build
```

`project.yml` is the source of truth for the generated Xcode project.

## Architecture

```text
Workspace++.app
├── SpaceRenamerCore       Space parsing, identity, names, switching logic
├── AppKit menu-bar UI     Native combined mode + per-display controls
├── Mission Control UI     Per-Space overlay windows
└── Local Raycast bridge   JSON index + atomic switch requests

Raycast extension
└── Switch Space           Live fuzzy search over the local index
```

See [Architecture](docs/ARCHITECTURE.md) for boundaries, compatibility
decisions, and extension points. Historical implementation decisions and
real-machine findings remain in `docs/superpowers/`.

## Privacy and security

- Workspace names and settings stay on the Mac.
- The app has no analytics, account, cloud sync, or runtime network service.
- The Raycast bridge uses files under
  `~/Library/Application Support/Space Renamer/`.
- Private SkyLight symbols are resolved at runtime to detect active Spaces and
  place optional Mission Control overlays. Space switching and direct,
  user-requested window transfers use local `CGEvent` input events.

## Known limitations

- A deleted and recreated desktop receives a new UUID and therefore a new
  default name.
- Shortcut mode is limited to nine desktops because macOS only exposes
  **Switch to Desktop 1–9** shortcuts.
- A distant switch in arrow mode posts one paced shortcut per hop.
- The active Mission Control thumbnail can omit its banner because macOS
  snapshots the currently rendered Space after the transient label has faded.
- Cross-display switching briefly repositions the pointer because macOS routes
  Mission Control shortcuts to the display containing it.
- Direct window movement briefly carries the window through macOS's normal
  animated Space transitions. The pointer is restored afterward.

## Raycast Store

The bundled extension is ready for validation and Store submission:

```sh
cd RaycastExtension
npm run publish
```

Until Raycast review is complete, `scripts/install.sh` imports the extension
locally. See [RaycastExtension/README.md](RaycastExtension/README.md).

## Contributing

Issues and pull requests are welcome. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) and use the included issue/PR templates.

## License and attribution

MIT—see [LICENSE](LICENSE).

Workspace++ includes work derived from Space Renamer, copyright © 2026 Alex
Shirov, used under the MIT License. Workspace++ additions are copyright © 2026
Syed Sami.
