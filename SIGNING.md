# Release signing and Accessibility

Official releases in the current self-signed lineage use the same existing certificate AND private key. The app identifier is `com.saint.SpaceRenamer`. The pinned certificate SHA-1 is `E16B2C680E1C4563C3CA31F62F2D1EF9C662431D`; the public certificate SHA-256 is `9c9d5072ec3857fd6782212de659e649e7f99f91898447f0c0edd5d9da5c16b1`.

Release scripts never generate a replacement certificate. They select the exact fingerprint, check the app and helper signatures, compare designated requirements with the prior official release, and require a successful before/after AXIsProcessTrusted() upgrade report before publication. Each release now includes its public signing report alongside its ZIP and checksum.

## Installing the app

Use the official prebuilt ZIP without re-signing it. A normal installation requires no signing certificate export, private key or `.p12`. Give initial Accessibility approval on each Mac when needed. Updates signed with the approved identity should retain that approval. A historical app signed under a different certificate is a different identity; one deliberate approval for the official identity may be required.

## Building a release on another Mac

The owner has securely exported the existing identity and private key into a password-protected `.p12` outside Git. Its random password is stored in the source Mac's login Keychain under **Workspace++ Release Identity Backup**. The archive must be transferred privately only to authorized release-building Macs; transfer its password separately through a secure channel. Never upload either to Git, releases, chat or CI artifacts.

Import that SAME identity before building, then run the fingerprint verification. The private source repository's [signing guide](https://github.com/sami3d/workspace-plus-plus-source/blob/main/signing/README.md) contains the export/import, packaging, continuity-test and publishing commands. Importing it on additional builders still needs to be done on those Macs; a GitHub download cannot install a private signing identity for them.

## Current status and Developer ID migration

Version 1.3.9 remains self-signed and is not Apple-notarized. The owner does not yet have a Developer ID Application identity or notarization credentials, so that migration has not been completed. The build path is prepared to require the exact Developer ID certificate, one Apple Developer team, hardened runtime, a secure timestamp, accepted notarization, a stapled ticket and Gatekeeper validation.

Moving from the existing self-signed requirement to Developer ID necessarily changes the requirement. That one-time migration must be rehearsed and may require Accessibility reapproval. After migration, a team-based Developer ID requirement can remain stable across certificate renewal; each renewal must still pass the old/new requirement comparison and an actual AX trust upgrade test before publication. Renewal continuity is not yet tested because those certificates are not available.

## 1.3.4 validation

A diagnostic-capable baseline, signed with the identity already approved on the test Mac and labelled 1.3.3, returned AXIsProcessTrusted() = true. Upgrading it in Applications to 1.3.4 also returned true, without any permission prompt or reset. The two builds had different executable/CodeDirectory hashes but identical designated requirements. The published 1.3.3 requirement also matched. The stock 1.3.3 binary lacks the API reporting flag, so the measured baseline was an instrumented build rather than the unchanged published executable.

This is a local continuity result for that approved identity. It does not assert that a Mac previously approved under a different certificate has been tested.

## 1.3.5 validation

The unchanged published 1.3.4 app and the 1.3.5 candidate both returned AXIsProcessTrusted() = true when installed consecutively at /Applications/Workspace++.app. No permission prompt or Accessibility reset was used. The executable and CodeDirectory hashes changed while the pinned certificate, bundle identifier and designated requirement remained identical. Both Apple Silicon and Intel slices passed signature verification.

## 1.3.6 validation

The published 1.3.5 baseline and 1.3.6 candidate both returned AXIsProcessTrusted() = true across an in-place upgrade. No permission prompt or reset was used. Both architecture signatures use the same permanent certificate and designated requirement. Local window-geometry checks found both per-display labels clear of all 14 visible status-item windows.

## 1.3.7 validation

The published 1.3.6 baseline and 1.3.7 candidate both returned AXIsProcessTrusted() = true across an in-place upgrade, without any permission prompt or reset. Both architecture signatures retain the permanent certificate and designated requirement. The production overlay-window regression test verifies the 100 ms hide deadline, repeated updates, occlusion notifications, Mission Control preview state and consecutive switches.

## 1.3.8 validation

Upgrading the published 1.3.7 app to 1.3.8 (build 12) preserved AXIsProcessTrusted() = true without any permission prompt or reset. Both architecture signatures retain the permanent certificate and designated requirement. This is a version-metadata release of the same executable; the signed Info.plist and CodeDirectory hashes differ between versions.

## 1.3.9 validation

The 1.3.8 baseline and 1.3.9 candidate preserve the permanent certificate and designated requirement. Release publication requires AXIsProcessTrusted() = true before and after the installed upgrade without a prompt or reset. Local native tests created disposable windows and verified both Move (target membership with source desktop retained) and Move & Follow (target membership and active destination), including a distant desktop. No user documents were moved by those tests.
