# Workspace++ for Raycast

Search the live spaces published by the running Workspace++ menu-bar app and
switch to one with Return.

Workspace++ maintains a small JSON index in Application Support whenever its
spaces, active spaces, or names change. The command reads that index on every
launch, then writes a tiny local request containing the selected space's stable
ID. Workspace++ observes that file and performs the switch. No menu UI,
networking, URL routing, or Accessibility automation from Raycast is involved.

## Local development

```sh
npm install
npm run dev
```

In Raycast, search for **Switch Space**. Assign a global hotkey in
**Raycast Settings → Shortcuts** for the fastest workflow.

Workspace++ still needs its existing Accessibility permission to perform the
actual Mission Control shortcut.

## Store publication

The extension is ready for Raycast Store review:

```sh
npm ci
npm run lint
npm run build
npm run publish
```

Until its Store submission is accepted, `../scripts/install.sh` imports it into
Raycast locally as part of the Workspace++ source installation.
