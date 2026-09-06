#!/bin/bash
# Verifies a completed project's artifacts: transcript decoding, playhead
# lookup, word-timing invariants, and waveform re-bucketing at every zoom the
# scrubber offers. Run against a project directory:
#
#   Tools/verify.sh ~/Library/Application\ Support/VODEditor/Projects/<uuid>
#
# With no argument it picks the most recently modified project.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  # Newest project that actually finished ingesting — a mid-transcription
  # project has no transcript to assert against. Glob, not $(ls): the path
  # has a space in it.
  PROJECT=""
  for candidate in "$HOME/Library/Application Support/VODEditor/Projects/"*/; do
    [ -f "$candidate/transcript/transcript.json" ] || continue
    if [ -z "$PROJECT" ] || [ "$candidate/transcript/transcript.json" -nt "$PROJECT/transcript/transcript.json" ]; then
      PROJECT="$candidate"
    fi
  done
fi
if [ -z "$PROJECT" ] || [ ! -f "$PROJECT/transcript/transcript.json" ]; then
  echo "No ingested project found. Pass a project directory as the first argument." >&2
  exit 1
fi

BIN=$(mktemp -d)/verify
# The whole non-UI layer: models plus the services that have no AppKit or
# SwiftUI dependency. ProjectSession/ProjectStore are excluded because they are
# @MainActor observable objects tied to the app.
swiftc -O -o "$BIN" \
  ThumbKit/Core/Paths.swift \
  VODEditor/Core/Shell.swift \
  VODEditor/Core/ToolLocator.swift \
  VODEditor/Models/Transcript.swift \
  VODEditor/Models/VODProject.swift \
  VODEditor/Models/ShortCandidate.swift \
  VODEditor/Models/ChatReplay.swift \
  VODEditor/Models/LongFormSegment.swift \
  VODEditor/Models/Throughline.swift \
  VODEditor/Services/LongFormService.swift \
  VODEditor/Services/CoherenceService.swift \
  VODEditor/Services/CaptionExporter.swift \
  VODEditor/Services/CaptionPhraser.swift \
  VODEditor/Models/StyleProfile.swift \
  VODEditor/Models/AudioTuning.swift \
  VODEditor/Models/PublishKit.swift \
  VODEditor/Services/AudioTuner.swift \
  VODEditor/Services/ThumbnailService.swift \
  VODEditor/Services/OverlayDesigner.swift \
  VODEditor/Services/TranscriptPolisher.swift \
  VODEditor/Services/ManualPrompts.swift \
  VODEditor/Models/ClipEdit.swift \
  VODEditor/Models/ClientProfile.swift \
  VODEditor/Models/AutoClip.swift \
  VODEditor/Services/ClipSignals.swift \
  VODEditor/Services/OllamaClient.swift \
  VODEditor/Services/AutoClipService.swift \
  VODEditor/Models/PlatformPreset.swift \
  VODEditor/Services/SocialOverlayRenderer.swift \
  ThumbKit/Models/ThumbDocument.swift \
  ThumbKit/Models/NormalizedRect.swift \
  ThumbKit/Core/HexColor.swift \
  ThumbKit/Core/EditingPrimitives.swift \
  ThumbKit/Services/ThumbnailRenderer.swift \
  VODEditor/Services/PunchInService.swift \
  VODEditor/Services/ReframeService.swift \
  VODEditor/Services/ReframeSampler.swift \
  VODEditor/Services/SFXLibrary.swift \
  VODEditor/Services/TightenService.swift \
  VODEditor/Services/EndCardService.swift \
  VODEditor/Services/BeatGridService.swift \
  VODEditor/Services/SpeakerLabelService.swift \
  VODEditor/Services/HookDoctorService.swift \
  VODEditor/Services/GlobalSearchService.swift \
  VODEditor/Services/PostingForecastService.swift \
  VODEditor/Services/DiskReclaimService.swift \
  VODEditor/Services/MediaRelinkService.swift \
  VODEditor/Services/ProjectBundleService.swift \
  VODEditor/Services/PreflightService.swift \
  VODEditor/Services/LocalAIService.swift \
  VODEditor/Services/CompilationService.swift \
  VODEditor/Services/RecurringBitService.swift \
  VODEditor/Services/LaughterSignals.swift \
  VODEditor/Services/BangerService.swift \
  VODEditor/Services/EditVideoCompositor.swift \
  VODEditor/Services/LayerRasterizer.swift \
  VODEditor/Services/MediaDownloader.swift \
  VODEditor/Services/SegmentDownloader.swift \
  VODEditor/Services/DownloadService.swift \
  VODEditor/Services/HLSSource.swift \
  VODEditor/Services/IdeaService.swift \
  VODEditor/Services/StyleAnalyzer.swift \
  VODEditor/Services/FFmpegService.swift \
  VODEditor/Services/WaveformService.swift \
  VODEditor/Services/WhisperService.swift \
  VODEditor/Services/ScoringService.swift \
  VODEditor/Services/CandidateService.swift \
  VODEditor/Services/ASSBuilder.swift \
  VODEditor/Services/ExportService.swift \
  Tools/VerifyProject/main.swift
exec "$BIN" "$PROJECT"
