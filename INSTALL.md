# Install Workspace++ on another Mac

Works on **Apple silicon and Intel Macs with macOS 13 or later**. You do not need Xcode or developer tools.

## 1. Download the app

Open the [latest Workspace++ release](https://github.com/sami3d/workspace-plus-plus/releases/latest).

Under **Assets**, download the file named **Workspace++-<version>-macOS.zip**. Choose the app ZIP, rather than either “Source code” archive.

The fast-switching update is included in [version 1.3.4](https://github.com/sami3d/workspace-plus-plus/releases/tag/v1.3.4). It also includes the previous window-movement fixes.

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

Official updates now use one pinned signing identity and require an approval-preserving upgrade test before publication. An already-approved installation under that identity should retain its approval. If approval unexpectedly disappears, record the old/new signing requirements before changing Accessibility settings. An old build signed with a different certificate may still require one deliberate approval for the official identity.

## 5. Raycast commands are included

Workspace++ 1.3.4 bundles 14 commands and opens Raycast's native Import Extension command on first launch. If Raycast asks you to sign in or approve the import, complete that step once. No Node.js, npm, Xcode, or separate source checkout is needed on this Mac. If you cancel, retry from **Workspace++ Preferences → Install Raycast Commands…**.

If Raycast is not installed yet, the pack stays bundled. When you install and launch Raycast while Workspace++ is running, setup is attempted automatically. You can also use the Preferences button after installing Raycast.

Custom app controls are in **Workspace++ Preferences → Raycast Apps**. Add an installed app, choose its command name and New window or New app instance, then Save. The **New App Window** command in Raycast lists your choices even while Workspace++ is closed. For each custom name directly in root search and a per-command Raycast hotkey, add the folder shown by **Show Favourite Commands Folder** once in Raycast Settings → Script Commands.

Included commands:

- **New App Window** — choose a favourite app configured in Preferences.
- **Switch Space** — search live workspace names.
- **Switch Workspace Picker** — open the native Workspace++ switch picker.
- **Move Window** — open the picker with Move and Move & Follow.
- **Chrome New, Helium New, Claude New, Figma New, ChatGPT New, Granola New, Notion New, Finder New, TickTick New, Projects New**.

App-window commands require the corresponding app on the receiving Mac. Projects New requires a synced local Google Drive `_Projects/2026` folder. macOS may request Raycast Accessibility and Automation permission the first time you use those commands; existing permissions and Raycast hotkeys are specific to each Mac.

The pack was tested with Raycast 2.8. Older Raycast versions may not run it. Portable app-window scripts are exported to `~/Library/Application Support/Space Renamer/Raycast App Commands`; you can add that directory in Raycast Settings → Script Commands as a fallback.

For individual workspace names directly in Raycast's root search, add `~/Library/Application Support/Space Renamer/Raycast Script Commands` once under Raycast Settings → Script Commands. The bundled Switch Space command already searches all workspace names without adding that folder.

## 6. Move a window

1. Focus a regular application window.
2. Open the Workspace++ menu and choose **Move focused window**, or press **Command-Shift-M**.
3. Select a different workspace.
4. Click **Move** to send the window while staying in the original workspace, or **Move & Follow** to go with it.

Full-screen and tiled windows cannot be moved this way. **Command-Shift-S** opens the workspace-switch picker; shortcuts can be changed in Preferences.

## Optional: use your existing cloud workspaces

If you already use Workspace++ cloud sync, sign in with the same Workspace++ account on this Mac. Chrome integration must be enabled separately on each Mac from **Workspace Library → Enable Chrome Integration**.

Replacing the app preserves this Mac’s existing workspace names and preferences. Installing the app on a new Mac does not automatically copy local settings from your other laptop.

## Instructions to give Codex on the other laptop

> Install the latest Workspace++ release from https://github.com/sami3d/workspace-plus-plus/releases/latest. Use the universal macOS app ZIP and verify its SHA-256 against the release checksum. Ensure the release is at least 1.3.4. Quit the existing app before replacing /Applications/Workspace++.app; preserve its existing settings and workspace names. Use the prebuilt app as supplied: do not re-sign it, generate a certificate, or reset Accessibility during an upgrade. Launch it and confirm its version. Verify that its bundled Raycast pack imports, then check Switch Space and the New Window commands in Raycast. If setup was cancelled, use Workspace++ Preferences → Install Raycast Commands. If macOS blocks launch, guide me through Apple's Privacy & Security → Open Anyway flow. Confirm Accessibility is enabled, and test switching to a distant workspace plus Move and Move & Follow using a disposable window. In Preferences, leave “Use legacy Ctrl+digit shortcuts” unchecked to use fast switching. Report any failed checks.

Version 1.3.2 upgrades the old arrow-switching setting automatically. Fast switching supports more than nine desktops. It uses undocumented native gesture fields, so compatibility can vary with macOS updates. The title-bar fallback for windows that reject direct placement can still visit the destination and return.

Release signing and builder identity handling are explained in [SIGNING.md](SIGNING.md). A normal installation does not require the release private key or its .p12 backup.
