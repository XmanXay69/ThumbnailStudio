#!/bin/bash
# Copies every image your saved designs point at into the app's own storage and
# repoints the designs at the copies, so a design no longer depends on where you
# happened to drag a file from. Originals are never deleted.
#
#   Tools/adopt-images.sh [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=$(mktemp -d)/adopt
swiftc -O -o "$BIN" \
  ThumbKit/Core/Paths.swift \
  ThumbKit/Core/HexColor.swift \
  ThumbKit/Core/EditingPrimitives.swift \
  ThumbKit/Models/NormalizedRect.swift \
  ThumbKit/Models/ThumbFonts.swift \
  ThumbKit/Models/ThumbDocument.swift \
  ThumbKit/Models/ThumbEditing.swift \
  ThumbKit/Models/CanvasGeometry.swift \
  ThumbKit/Models/ThumbLegibility.swift \
  ThumbKit/Services/ThumbAssets.swift \
  ThumbKit/Services/ThumbnailRenderer.swift \
  ThumbKit/Services/CutoutService.swift \
  ThumbKit/Services/CutoutRun.swift \
  ThumbKit/Services/ThumbStore.swift \
  ThumbKit/Services/ThumbLibrary.swift \
  Tools/AdoptImages/main.swift

# The designs are about to be rewritten in place, so keep a copy first.
LAB="$HOME/Library/Application Support/VODEditor/ThumbLab"
STAMP=$(date +%Y%m%d-%H%M%S)
if [ -d "$LAB" ] && [[ " $* " != *" --dry-run "* ]]; then
  cp -R "$LAB" "$LAB.before-adopt-$STAMP"
  echo "designs backed up to ThumbLab.before-adopt-$STAMP"
fi

exec "$BIN" "$@"
