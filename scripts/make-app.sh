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

# Prefer the local "MicPause Dev Signing" self-signed certificate: it keeps the
# signature stable across rebuilds, so TCC permission grants (Accessibility,
# Automation) survive. Falls back to ad-hoc (e.g. in CI, where no cert exists);
# ad-hoc signatures change every build and grants must be re-approved.
IDENTITY="-"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "MicPause Dev Signing"; then
    IDENTITY="MicPause Dev Signing"
fi
# Strip extended attributes (Finder info, provenance) — they break strict
# signature verification.
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --identifier com.ruan.MicPause "$APP"
# iCloud Desktop sync may stamp Finder/file-provider attributes back onto the
# bundle root; they are harmless to the signature but fail --strict verification.
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
echo "Signed with: $IDENTITY"

echo
echo "Built $APP"
echo "Tip: move it to /Applications so Launch at Login works reliably:"
echo "  cp -R $APP /Applications/"
