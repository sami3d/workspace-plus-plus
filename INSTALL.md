# Install Workspace++ on another Mac

Works on **Apple silicon and Intel Macs with macOS 13 or later**. You do not need Xcode or developer tools.

## 1. Download the app

Open the [latest Workspace++ release](https://github.com/sami3d/workspace-plus-plus/releases/latest).

Under **Assets**, download the file named **Workspace++-<version>-macOS.zip**. Choose the app ZIP, rather than either “Source code” archive.

The fast-switching update is included in [version 1.3.2](https://github.com/sami3d/workspace-plus-plus/releases/tag/v1.3.2). It also includes the previous window-movement fixes.

## 2. Install

1. Double-click the downloaded ZIP to extract **Workspace++.app**.
2. If an older Workspace++ is running, quit it from its menu first.
3. Drag **Workspace++.app** into your **Applications** folder. Choose **Replace** if prompted.
4. Open **Applications → Workspace++**.

The app lives in the menu bar, so it may not open a normal window.

## 3. If macOS blocks the first launch

This release is self-signed and has not been notarized by Apple.

After attempting to open it, go to **System Settings → Privacy & Security**, scroll to the message about Workspace++, and click **Open Anyway**. Authenticate and confirm **Open** if prompted.

See [Apple’s instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445).

## 4. Allow window control

Open **System Settings → Privacy & Security → Accessibility** and enable **Workspace++**.

If it is missing, click **+**, select **Applications → Workspace++.app**, and enable it. Quit and reopen Workspace++ afterward.

If window control stops working after replacing an older version, toggle its Accessibility permission off and back on, then reopen the app.

## 5. Move a window

1. Focus a regular application window.
2. Open the Workspace++ menu and choose **Move focused window**, or press **Command-Shift-M**.
3. Select a different workspace.
4. Click **Move** to send the window while staying in the original workspace, or **Move & Follow** to go with it.

Full-screen and tiled windows cannot be moved this way. **Command-Shift-S** opens the workspace-switch picker; shortcuts can be changed in Preferences.

## Optional: use your existing cloud workspaces

If you already use Workspace++ cloud sync, sign in with the same Workspace++ account on this Mac. Chrome integration must be enabled separately on each Mac from **Workspace Library → Enable Chrome Integration**.

Replacing the app preserves this Mac’s existing workspace names and preferences. Installing the app on a new Mac does not automatically copy local settings from your other laptop.

## Instructions to give Codex on the other laptop

> Install the latest Workspace++ release from https://github.com/sami3d/workspace-plus-plus/releases/latest. Use the universal macOS app ZIP and verify its SHA-256 against the release checksum. Ensure the release is at least 1.3.2. Quit the existing app before replacing /Applications/Workspace++.app; preserve its existing settings and workspace names. Launch it and confirm its version. If macOS blocks launch, guide me through Apple's Privacy & Security → Open Anyway flow. Confirm Accessibility is enabled, and test switching to a distant workspace plus Move and Move & Follow using a disposable window. In Preferences, leave “Use legacy Ctrl+digit shortcuts” unchecked to use fast switching. Report any failed checks.

Version 1.3.2 upgrades the old arrow-switching setting automatically. Fast switching supports more than nine desktops. It uses undocumented native gesture fields, so compatibility can vary with macOS updates. The title-bar fallback for windows that reject direct placement can still visit the destination and return.
