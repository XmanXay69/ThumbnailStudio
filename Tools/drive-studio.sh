#!/bin/bash
# Drives the studio's real objects — the same key router, editor model and
# cutout pipeline the app runs — against a COPY of a real design, and reports
# what actually happened. Written because this Mac withholds accessibility
# permission, so the GUI itself cannot be driven; everything below is the
# shipping code path, just reached directly.
#
#   Tools/drive-studio.sh ["design name substring"]
set -euo pipefail
cd "$(dirname "$0")/.."

LAB="$HOME/Library/Application Support/VODEditor/ThumbLab"
QUERY="${1:-}"
DESIGN=""
for candidate in "$LAB"/*.json; do
  [ -f "$candidate" ] || continue
  if [ -z "$QUERY" ] || [[ "$(basename "$candidate")" == *"$QUERY"* ]]; then
    DESIGN="$candidate"; break
  fi
done
[ -n "$DESIGN" ] || { echo "No design found in $LAB" >&2; exit 1; }

BIN=$(mktemp -d)/drivestudio
swiftc -O -o "$BIN" \
  ThumbKit/Core/Paths.swift \
  ThumbKit/Core/HexColor.swift \
  ThumbKit/Core/EditingPrimitives.swift \
  ThumbKit/Models/NormalizedRect.swift \
  ThumbKit/Models/ThumbFonts.swift \
  ThumbKit/Models/ThumbLegibility.swift \
  ThumbKit/Models/ThumbDocument.swift \
  ThumbKit/Models/ThumbEditing.swift \
  ThumbKit/Models/CanvasGeometry.swift \
  ThumbKit/Services/ThumbAssets.swift \
  ThumbKit/Services/CutoutService.swift \
  ThumbKit/Services/CutoutRun.swift \
  ThumbKit/Services/ThumbnailRenderer.swift \
  ThumbKit/Models/ThumbComposition.swift \
  ThumbKit/Services/ThumbCanvasReader.swift \
  ThumbKit/Services/ThumbFrameSource.swift \
  ThumbKit/Services/ThumbStore.swift \
  ThumbKit/Services/ThumbLayerClipboard.swift \
  ThumbKit/Services/ThumbKeyboard.swift \
  ThumbKit/Services/ThumbEditorModel.swift \
  Tools/DriveStudio/main.swift
exec "$BIN" "$DESIGN"
