#!/bin/bash
# Builds Release and installs to /Applications, so the app launches from
# Spotlight, Launchpad and the Dock like anything else.
#
# Falls back to ~/Applications if /Applications isn't writable — that folder is
# in Spotlight too, so the app is still reachable either way.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building Release…"
xcodebuild -project VODEditor.xcodeproj -scheme VODEditor -configuration Release build \
  | grep -E "error:|warning: unable|BUILD" || true

BUILT=$(xcodebuild -project VODEditor.xcodeproj -scheme VODEditor -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)
APP="$BUILT/VODEditor.app"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "/Applications isn't writable; installing to $DEST instead."
fi

# The running app can't be replaced underneath itself.
pkill -f "$DEST/VODEditor.app/Contents/MacOS/VODEditor" 2>/dev/null || true
rm -rf "$DEST/VODEditor.app"
cp -R "$APP" "$DEST/"

# Re-sign after the copy: modifying a bundle invalidates its signature, and an
# app with a broken signature is refused rather than merely warned about.
codesign --force --deep --sign - "$DEST/VODEditor.app" 2>/dev/null || true

# Nudge Spotlight and Launch Services so it shows up straight away rather than
# whenever macOS next gets round to indexing.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST/VODEditor.app" 2>/dev/null || true
touch "$DEST/VODEditor.app"

echo "Installed to $DEST/VODEditor.app"
echo "Open it from Spotlight (⌘-Space, \"VOD Editor\") or run: open -a \"VODEditor\""
