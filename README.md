# Workspace++

Workspace++ is a macOS menu-bar app for naming, finding, switching, moving,
parking, and restoring Mission Control workspaces across displays and Macs.

## Demo

<p align="center">
  <a href="https://www.youtube.com/watch?v=wP7ub-2JzZg">
    <img src="https://img.youtube.com/vi/wP7ub-2JzZg/hqdefault.jpg" width="640" alt="Watch the Workspace++ demo on YouTube">
  </a>
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=wP7ub-2JzZg"><strong>Watch the Workspace++ demo on YouTube</strong></a>
</p>

## Download

[Installation instructions for another Mac](INSTALL.md).

Download the newest macOS package from the
[latest Workspace++ release](https://github.com/sami3d/workspace-plus-plus/releases/latest).
Each packaged release includes a SHA-256 checksum. Version **1.3.8** limits workspace overlays to a 100 ms glimpse after switching and prevents occlusion notifications from bringing them back. It includes the menu bar placement fix, the permanent signing identity, Accessibility continuity checks, and all 14 bundled Raycast commands. Raycast may ask for sign-in or import approval once.

Workspace++ requires macOS 13 or later. The current release remains self-signed and not Apple-notarized; see the [installation guide](INSTALL.md) for Apple's first-launch approval flow.

Official updates use one permanent signing identity and preserve the designated requirement. Release publication requires a positive before/after Accessibility trust test. [Signing status and builder instructions](SIGNING.md) distinguish the current self-signed setup from the pending Developer ID migration.

Replacing the app preserves workspace names, preferences, categories and cloud data.

The Chrome companion and native bridge are bundled inside Workspace++. Choose
**Workspace Library → Enable Chrome Integration…** and follow the one-time
Chrome approval instructions on each Mac.

## Source availability

This repository intentionally contains only official product downloads,
release notes, checksums, and documentation. Workspace++ product source code is
privately maintained and is not licensed for copying, modification, or
redistribution.

Workspace++ includes software derived from Space Renamer by Alex Shirov. That
upstream component remains subject to its original MIT licence; see
[Third-party notices](THIRD_PARTY_NOTICES.md).

Copyright © 2026 Syed Sami. All rights reserved.
