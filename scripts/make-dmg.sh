#!/bin/bash
# Packages build/MicPause.app into build/MicPause-<version>.dmg with a
# drag-to-Applications layout. Run scripts/make-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MicPause.app"
[ -d "$APP" ] || { echo "error: $APP not found — run scripts/make-app.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)"
DMG="build/MicPause-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "MicPause" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
echo "Built $DMG"
