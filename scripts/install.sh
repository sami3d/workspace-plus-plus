#!/bin/sh
# Build and install Workspace++ plus its local Raycast extension.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DERIVED_DATA="${ROOT}/.build/workspace-plus-plus"
BUILT_APP="${DERIVED_DATA}/Build/Products/Release/Workspace++.app"
INSTALLED_APP="/Applications/Workspace++.app"
LEGACY_APP="/Applications/Space Renamer.app"
RAYCAST_DIR="${ROOT}/RaycastExtension"

say() {
  printf '%s\n' "Workspace++: $*"
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "Missing required command: $1"
    exit 1
  fi
}

require xcodebuild
require security

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    say "Installing xcodegen with Homebrew…"
    brew install xcodegen
  else
    say "xcodegen is required. Install it from https://github.com/yonaskolb/XcodeGen"
    exit 1
  fi
fi

say "Preparing the stable local signing identity…"
"${ROOT}/scripts/create-signing-cert.sh"

say "Generating the Xcode project…"
(cd "${ROOT}" && xcodegen generate)

say "Building Workspace++ Release…"
xcodebuild \
  -project "${ROOT}/SpaceRenamer.xcodeproj" \
  -scheme SpaceRenamer \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DATA}" \
  build

if [ ! -d "${BUILT_APP}" ]; then
  say "Build completed but ${BUILT_APP} was not produced."
  exit 1
fi

pkill -x "Workspace++" 2>/dev/null || true
pkill -x SpaceRenamer 2>/dev/null || true

say "Installing ${INSTALLED_APP}…"
/usr/bin/ditto "${BUILT_APP}" "${INSTALLED_APP}"

if [ -d "${LEGACY_APP}" ] && [ "${LEGACY_APP}" != "${INSTALLED_APP}" ]; then
  TRASHED_APP="${HOME}/.Trash/Space Renamer-before-Workspace++-$(date +%Y%m%d-%H%M%S).app"
  say "Moving the old app to Trash as $(basename "${TRASHED_APP}")…"
  mv "${LEGACY_APP}" "${TRASHED_APP}"
fi

if [ -d "/Applications/Raycast.app" ] && command -v npm >/dev/null 2>&1; then
  say "Validating and importing the Raycast extension…"
  (
    cd "${RAYCAST_DIR}"
    npm ci
    npm run lint
    npm run build
    npm run dev >"${DERIVED_DATA}/raycast-import.log" 2>&1 &
    RAYCAST_PID=$!
    sleep 8
    kill "${RAYCAST_PID}" 2>/dev/null || true
    wait "${RAYCAST_PID}" 2>/dev/null || true
  )
  say "Raycast command imported. Search for “Switch Space”."
elif [ ! -d "/Applications/Raycast.app" ]; then
  say "Raycast is not installed; skipped the optional Raycast command."
else
  say "npm is unavailable; skipped Raycast. Install Node.js, then run:"
  say "  cd \"${RAYCAST_DIR}\" && npm ci && npm run dev"
fi

say "Launching Workspace++…"
open "${INSTALLED_APP}"
say "Installation complete."
