#!/bin/bash
# Builds Release and installs Thumbnail Studio to /Applications, so the design
# app launches from Spotlight, Launchpad and the Dock on its own — no VOD
# editor, no video pipeline.
#
# Falls back to ~/Applications if /Applications isn't writable.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building Release…"
xcodebuild -project VODEditor.xcodeproj -scheme ThumbStudio -configuration Release build \
  | grep -E "error:|warning: unable|BUILD" || true

BUILT=$(xcodebuild -project VODEditor.xcodeproj -scheme ThumbStudio -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}' | head -1)
APP="$BUILT/ThumbStudio.app"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "/Applications isn't writable; installing to $DEST instead."
fi

# The running app can't be replaced underneath itself.
pkill -f "$DEST/ThumbStudio.app/Contents/MacOS/ThumbStudio" 2>/dev/null || true
rm -rf "$DEST/ThumbStudio.app"
cp -R "$APP" "$DEST/"

# Re-sign after the copy: modifying a bundle invalidates its signature, and an
# app with a broken signature is refused rather than merely warned about.
codesign --force --deep --sign - "$DEST/ThumbStudio.app" 2>/dev/null || true

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST/ThumbStudio.app" 2>/dev/null || true
touch "$DEST/ThumbStudio.app"

echo "Installed to $DEST/ThumbStudio.app"
echo "Open it from Spotlight (⌘-Space, \"Thumbnail Studio\") or run: open -a ThumbStudio"
