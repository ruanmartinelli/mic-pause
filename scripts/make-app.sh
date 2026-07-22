#!/bin/bash
# Builds MicPause in release mode and assembles a signed (ad-hoc) app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/MicPause.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MicPause "$APP/Contents/MacOS/MicPause"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature with a stable identifier so TCC permission grants
# (Accessibility, Automation) survive rebuilds.
codesign --force --sign - --identifier com.ruan.MicPause "$APP"

echo
echo "Built $APP"
echo "Tip: move it to /Applications so Launch at Login works reliably:"
echo "  cp -R $APP /Applications/"
