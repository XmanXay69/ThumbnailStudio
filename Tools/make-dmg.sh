#!/bin/bash
# Builds Release and packs Thumbnail Studio into a drag-to-install disk image.
#
#   Tools/make-dmg.sh [output.dmg]
#
# The image holds the app and a symlink to /Applications, which is the layout
# every Mac user already knows: open, drag across, eject.
#
# On signing, honestly: this is signed ad-hoc, the same as Tools/install.sh
# does. Ad-hoc is enough for the Mac that built it and is NOT enough for a Mac
# that downloads it — macOS quarantines anything from the internet and refuses
# an app that is not notarized. Notarizing needs a Developer ID certificate,
# which needs a paid Apple Developer membership; an "Apple Development"
# certificate is for running on your own registered devices and does not count.
# The README says what to do about it on the receiving end.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/ThumbnailStudio.dmg}"
VOLUME="Thumbnail Studio"

echo "Building Release…"
xcodebuild -project VODEditor.xcodeproj -scheme ThumbStudio -configuration Release build \
  | grep -E "error:|BUILD" || true

BUILT=$(xcodebuild -project VODEditor.xcodeproj -scheme ThumbStudio -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)
APP="$BUILT/ThumbStudio.app"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"

# Re-sign after the copy: copying a bundle invalidates its signature, and a
# broken signature is refused outright rather than merely warned about.
codesign --force --deep --sign - "$STAGE/ThumbStudio.app" 2>/dev/null || true
codesign --verify --deep "$STAGE/ThumbStudio.app" 2>/dev/null \
  && echo "signature: ok (ad-hoc)" || echo "signature: FAILED to verify" >&2

ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 "$OUT"

echo "$OUT  ($(du -h "$OUT" | cut -f1))"
