#!/bin/sh
# Create a locally signed Workspace++ zip and checksum after a Release build.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/workspace-plus-plus-release"
APP="$DERIVED_DATA/Build/Products/Release/Workspace++.app"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/SpaceRenamerApp/App/Info.plist")"
ARCHIVE="$DIST/Workspace++-$VERSION-macOS.zip"

"$ROOT/scripts/create-signing-cert.sh"
(cd "$ROOT" && xcodegen generate)
xcodebuild \
  -project "$ROOT/SpaceRenamer.xcodeproj" \
  -scheme SpaceRenamer \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" >"$ARCHIVE.sha256"

printf '%s\n' "Created:"
printf '  %s\n' "$ARCHIVE" "$ARCHIVE.sha256"
printf '%s\n' "This build is self-signed, not Apple-notarized."
