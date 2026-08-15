#!/bin/sh
# Create a locally signed Workspace++ zip and checksum after a Release build.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/workspace-plus-plus-release"
APP="$DERIVED_DATA/Build/Products/Release/Workspace++.app"
APP_ENTITLEMENTS="$DERIVED_DATA/Build/Intermediates.noindex/SpaceRenamer.build/Release/SpaceRenamer.build/Workspace++.app.xcent"
CHROME_HOST="$APP/Contents/Helpers/WorkspacePlusChromeHost"
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
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

# The final embed phase copies the Chrome companion after Xcode's incremental
# signing decision. Sign the fully assembled helper and app so the archive's
# resource seal always covers the bundled extension files.
codesign --force --sign "SpaceRenamer Dev" --timestamp=none "$CHROME_HOST"
codesign --force --sign "SpaceRenamer Dev" --timestamp=none \
  --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/Workspace++")"
case " $APP_ARCHS " in
  *" arm64 "*) ;;
  *)
    printf '%s\n' "Expected a universal app, built architectures: $APP_ARCHS" >&2
    exit 1
    ;;
esac
case " $APP_ARCHS " in
  *" x86_64 "*) ;;
  *)
    printf '%s\n' "Expected a universal app, built architectures: $APP_ARCHS" >&2
    exit 1
    ;;
esac

mkdir -p "$DIST"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
(
  cd "$DIST"
  shasum -a 256 "$(basename "$ARCHIVE")" >"$(basename "$ARCHIVE").sha256"
)

printf '%s\n' "Created:"
printf '  %s\n' "$ARCHIVE" "$ARCHIVE.sha256"
printf '%s\n' "This build is self-signed, not Apple-notarized."
