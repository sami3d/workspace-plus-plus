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

Download the newest macOS package from the
[latest Workspace++ release](https://github.com/sami3d/workspace-plus-plus/releases/latest).
Each packaged release includes a SHA-256 checksum.

Workspace++ requires macOS 13 or later. The current builds are self-signed and
not Apple-notarized, so right-click **Workspace++.app** and choose **Open** on
first launch. If macOS still blocks it, run:

```sh
xattr -dr com.apple.quarantine "/Applications/Workspace++.app"
open "/Applications/Workspace++.app"
```

Replacing the app does not delete workspace names, categories, preferences, or
cloud data. macOS may ask you to toggle Workspace++ off and back on under
**System Settings → Privacy & Security → Accessibility** after an update.

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
