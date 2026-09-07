# VOD Editor

Local-only macOS tool for turning multi-hour Twitch VODs into a YouTube best-of
edit and a batch of vertical shorts. Personal tool — no accounts, no cloud, no
sandbox.

**All four phases built.** Phase 1 (ingest → transcribe → browse), Phase 2
(score → shorts → review → vertical export with burned captions), Phase 3
(long-form assembly → timeline → horizontal export), Phase 4 (crossfades, music
bed with ducking, batch ingest).

## Requirements

```bash
brew install ffmpeg-full whisper-cpp
```

`ffmpeg-full`, not `ffmpeg` — Homebrew's plain `ffmpeg` bottle is built without
libass, libfreetype and libfontconfig, so it has no `ass`, `subtitles` or
`drawtext` filter and **cannot burn in captions at all**. `ffmpeg-full` is
keg-only, so it installs alongside without replacing anything; `ToolLocator`
looks in `/opt/homebrew/opt/ffmpeg-full/bin` first. Analysis works with either
build — only caption burn-in needs the full one.

Plus a whisper model in `~/Library/Application Support/VODEditor/models/`:

```bash
curl -L -o "$HOME/Library/Application Support/VODEditor/models/ggml-large-v3-turbo.bin" \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

The Setup sheet in-app checks all of this and gives you the exact command for
whatever's missing.

## Build & run

```bash
xcodebuild -project VODEditor.xcodeproj -scheme VODEditor -configuration Debug -derivedDataPath build build
```

Or just open `VODEditor.xcodeproj` in Xcode and hit Run.

### Install it as a real app

```bash
Tools/install.sh
```

Builds Release, copies `VOD Editor.app` to `/Applications` (or `~/Applications`
if that isn't writable), re-signs it ad-hoc, and registers it with Launch
Services so it shows up in Spotlight and Launchpad straight away. After that it's
⌘-Space → "VOD Editor" like anything else — the CLI below is only for testing.
The icon is a waveform trimmed down to its peaks, over a playhead.

### Thumbnail Studio, as its own app

The thumbnail half of this app is also a standalone Mac app, so you can design a
thumbnail without opening a VOD — and, more to the point, while a four-hour VOD
is transcribing next door.

```bash
Tools/install-thumbstudio.sh
```

Builds and installs `ThumbStudio.app` (Finder and Spotlight show it as
"Thumbnail Studio"). Both apps share `ThumbKit/`, so a fix to the studio lands
in both, and both read the same designs out of
`~/Library/Application Support/VODEditor/ThumbLab/`. Whichever app you bring to
the front adopts what is on disk first, so having both open on one design can't
silently clobber it.

### Review

⌘R, or the checklist button. Measures the thumbnail and says what it found:
text height at up-next size, what the duration badge covers, word count,
whether anything important falls off the edge, contrast, background detail,
and face size. Each finding carries its share of the score, so a 70 tells you
which 30 you lost.

It is deliberately not a prediction. This app has no click-through data, no
channel history and no model of your audience, and the sheet says so rather
than implying otherwise with a confident-looking gauge. The rules it applies
are the ones that hold regardless of audience: text too small to read at feed
size is wasted, and text the duration badge covers is wasted.

A blank canvas is not scored at all — it used to come back 71, full marks for
having no text too small and no words too many, which is the app flattering
itself. A background that bleeds off the edge is left alone; that is a
technique, not a mistake.

### The library

⌘L, or the tool-rail button. Two sources, neither needing a catalogue you have
to maintain:

- **`~/Desktop/Thumbnail Studio/Assets`** — a folder in Finder, where a
  subfolder is a tag. Same shape as the SFX library that already worked here:
  no database to corrupt, no import step, and filing a logo is dragging it
  into a folder.
- **Used before** — every image your saved designs actually reference, newest
  design first. That list maintains itself.

Importing now *copies* the file into app-owned, content-addressed storage
rather than pointing at wherever you dragged it from — so tidying your
Downloads folder can no longer quietly empty a layer six weeks later. The same
file imported twice costs one copy. A layer whose file has gone missing gets
an amber badge in the layers list instead of silently drawing nothing.

### Text

Font, weight, size, letter spacing, line height, alignment, all-caps, fill,
gradient, stroke, shadow and a highlight box. Alignment and line height were
already honoured by the renderer and had no control at all — dead model
surface that read as missing features.

The font list only offers what is installed. It used to offer Anton, Bangers
and Montserrat, none of which are on this Mac, and default to Anton — so the
inspector said Anton while the canvas quietly drew the system heavy face. A
font that is not installed is now flagged in the inspector rather than
silently substituted, and the default is resolved at run time from what is
actually there.

All-caps is a toggle rather than a retype, so the words stay editable. It is
applied where the text is rendered, so the drawn glyphs, the measured bounds
and the selection box can never disagree about it.

### Grading a frame

Thirteen adjustments, in the order a photo editor applies them: exposure and
white balance first, then highlights and shadows to recover the ends of the
range, then the grade, then sharpen and denoise, then vignette, then a look.
Highlights and shadows are the two that matter most on a gameplay grab — a
blown sky or a crushed night scene is usually recoverable.

All of it is non-destructive: the adjustments live on the layer, the source
file is never touched, and every slider has a reset. Each one renders through
the same `AdjustedImageCache` the canvas and the export share, so what you
grade is what ships.

### Typing numbers

The canvas takes any size from 64 to 8192 a side, not just the four presets —
a banner, a Discord header, whatever the platform of the month wants. A
selected layer gets typed X/Y and W in canvas pixels alongside the sliders,
because dragging gets you close and a number gets you exactly where you meant.
Height is typed for shapes and shown-but-derived for text and images, which
take their height from their content.

Fields commit on Return or when they lose focus, revert on Escape, and clamp
rather than accepting a value the renderer cannot allocate.

### Preview at real sizes

⌘P, or the tool-rail button under Crop. A thumbnail is designed at 1280×720 and
consumed at about 360 points wide in a desktop feed and 168 in the up-next rail
— which is why text that looked obvious in the editor disappears in the wild.
The sheet shows the design in a home feed, search results, the up-next rail and
a phone, surrounded by featureless grey neighbours so the only question is
whether yours stands out. The size test drops it to 100/50/25/10%.

Along the bottom is the one measurement worth making: the cap height of the
smallest text layer *in real pixels* at up-next size, and whether any text is
sitting under YouTube's duration stamp. Below roughly 11 px text stops
resolving at a glance. That threshold is a rule of thumb and is stated as one —
the app has no click-through data and does not pretend to.

### Backing it up

```bash
Tools/backup.sh
```

Pushes to a bare repo in iCloud Drive, which is the whole trick: iCloud syncs
a working copy badly because it races with git's own writes, but a bare repo
is only touched during an explicit push. The script packs first as well —
iCloud copes with a handful of large files far better than with tens of
thousands of loose objects. Restore anywhere with
`git clone "~/Library/Mobile Documents/com~apple~CloudDocs/Code Backups/VODEditor.git"`.

### Headless ingest

The whole pipeline runs unattended, which is how it gets tested against a real
multi-hour VOD rather than a short sample:

```bash
./build/Build/Products/Debug/VODEditor.app/Contents/MacOS/VODEditor --ingest /path/to/vod.mp4
```

Progress goes to stdout; the process exits 0 on success, 1 on failure. Re-running
against the same file resumes rather than restarting.

Add `--export-shorts <dir> [--export-count N]` to render the top-scoring
candidates in the same run — useful for checking the render path without
clicking through the UI:

```bash
./build/Build/Products/Debug/VODEditor.app/Contents/MacOS/VODEditor \
  --ingest /path/to/vod.mp4 --export-shorts ~/Desktop/shorts --export-count 3
```

`--export-longform <file.mp4>` does the same for the assembled long-form cut.

`--tune-audio` measures the mix, applies the suggested tuning, and reports the
before/after from a rendered sample. `--thumbnail <file.jpg> [--thumbnail-text
"..."]` pulls stills and renders a thumbnail plus its vertical cover.

### From a link

`--link <url>` downloads a VOD and ingests it in one go:

```bash
./build/Build/Products/Debug/VODEditor.app/Contents/MacOS/VODEditor \
  --link "https://www.twitch.tv/videos/2827607094"
```

Same thing in the app: **Paste a link…** in the sidebar. One URL or a column of
them; each is probed, downloaded, turned into a project and transcribed, in
order. Downloads resume where they stopped, and a link that's already been
fetched is not fetched again.

**YouTube links work too.** Stream-in-place is Twitch-only (it depends on
Twitch's seekable HLS playlists), so a YouTube link automatically falls back to
a normal yt-dlp download and then ingests like any local file — verified end to
end against a real YouTube video, transcript and all.

### Verifying a project

```bash
Tools/verify.sh    # defaults to the most recent project
```

Compiles the model layer standalone and asserts against the real artifacts:
transcript decoding, playhead lookup vs. a linear scan, word-timing invariants
(monotonic, non-zero, no unhighlighted gaps), and waveform re-bucketing at every
zoom level including degenerate ranges. Plus caption phrasing, the ducking
envelope and filter graph, long-form input-index bookkeeping, and thumbnail and
packaging output, link parsing, the playlist rewrite, thumbnail layers, and the two-box portrait layout. **633 checks** against
a full-length VOD; two that only mean something at length are skipped on short
sources. Two checks about candidate overlap and cue phrasing assert the
generation-time rules loosely enough to stay true on a project the user has
since re-trimmed by hand.

## How it works

```
Ingest ──► Analyze ─────────────► Browse ──► Score ────────► Shorts review ──► Export
 probe    audio 16k mono          AVKit      audio energy    candidate bin      1080×1920
          silence map             waveform   speech density  trim handles       burned ASS
          waveform peaks          transcript excitement      9:16 crop frame    VideoToolbox
          chunk + transcribe      sync       chat velocity   caption editing    NSSavePanel
```

### Scoring

A per-second interest curve, built as a plain weighted sum — no model, per the
brief. Components are normalised against their own 95th percentile so one
screaming moment doesn't flatten the rest of the VOD:

| Signal | Source | Default weight |
|---|---|---|
| Audio energy | waveform peaks from ingest | 0.22 |
| Speech density | words per second | 0.10 |
| Excitement | hype/laughter lexicon, `!` | 0.18 |
| Chat velocity | chat replay, weighted + acceleration | 0.25 |
| Emphasis | how sharply loudness *rises* | 0.13 |
| Bursts | loud, deeply-modulated stretches | 0.10 |
| Scene changes | ffmpeg scene detection (opt-in) | 0.12 |

**Emphasis** is the derivative of the loudness envelope, not its level: a shout
after a quiet stretch is emphasis in a way absolute loudness can't express.

**Bursts** catch laughter — but the name is deliberately not "laughter". The
first version gated on 3–8 Hz amplitude modulation alone and fired on **89.5% of
windows**, because ordinary connected speech modulates at its syllable rate of
4–7 Hz, right inside that band. It now also requires modulation *depth* (laughter
drops to near-silence between hahs; connected speech doesn't) and loudness, which
brings it to 26.8%. It still catches rapid shouting, so treat it as a burst
detector rather than a laugh classifier.

**Chat** weights messages by what they signal — an explicit clip request scores
5×, a hype emote 2×, ordinary chatter 1× — and blends the raw level (70%) with
its *acceleration* (30%), since chat suddenly speeding up marks the instant
something happened while a sustained high level only says the stream is busy.

Chat and scene detection are both optional; when either is absent the remaining
weights renormalise. Chat is imported from the toolbar (speech-bubble icon) and
is usually the strongest signal for IRL and Just Chatting content — worth
exporting with TwitchDownloaderCLI.

**Scene detection** is the only analysis that reads the video stream. It decodes
**keyframes only** (`-skip_frame nokey`): 64 seconds for a 4-hour VOD versus
~23 minutes for a full decode, finding 4 cuts where a full decode finds 5 over
the same sample. Trigger it from the long-form inspector.

Candidates are local maxima above `mean + 1σ`, expanded while the curve stays
above a per-peak floor, snapped onto silence so clips don't open mid-word,
clamped to 15–60s, and greedily deduplicated at 15% overlap.

The inspector shows the per-signal breakdown for the selected clip, so it's
visible *why* a moment was picked rather than just that it was.

### Portrait layout for shorts

Two framings per clip. **Single** is one 9:16 window you drag to move and drag by the corners to crop or zoom — it stays locked to 9:16, so the box you see is exactly the exported frame.
**Cam + gameplay** is the layout Twitch's portrait clips use: the webcam gets
its own box, stacked with the gameplay, so the face isn't buried in a corner of
a shrunk-down crop.

You draw the webcam box over your cam on the preview (drag to move, drag the
corner to resize) and it's cut out and scaled into its own band; the gameplay
fills the rest. Both are scaled to exactly 1080 wide so `vstack` will join them,
and the cam-height slider splits the 1920 between them. Captions burn onto the
finished stack. The webcam sits in the same place all stream, so "Use this
framing for all clips" copies one setup onto every candidate, and new clips
inherit it.

Both the webcam box and the gameplay box are free rectangles you edit on the
preview: **click a box to select it** (it highlights and gains corner handles),
then drag to move or drag a corner to crop. Two bugs made earlier versions of
this feel broken, and both are structural rather than cosmetic. Selecting a box
used to *reorder* the two views to raise the selected one — which recreated
both views on the first drag tick and cancelled the gesture mid-flight, so a box
would highlight and then refuse to move; the selected box is now raised with
`zIndex`, which changes stacking without touching identity. And every drag tick
used to route through the session, re-rendering the whole pane and rewriting the
project file to disk per mouse move; drags now edit a local draft and commit
once on release, with persistence debounced.

The border between the cam band and the gameplay band is draggable on the
**output preview** — the one place that border actually exists — as a green
line with a grab handle. Sliders in the framing panel remain the keyboard-free
fallback for width, height and position of each box.

An optional **output sidebar** shows the composed 1080×1920 frame at the
playhead, rendered through the very same filter graph the export uses — so what
you see is what ships. It re-renders when you reframe or scrub (debounced, and
never during playback, since that would queue an ffmpeg call every frame).
Captions aren't in the sidebar frame; they preview live on the main player.

The rectangles are stored as fractions of the source, so the same box works
whether the VOD is 1080p or 720p — and a clip saved by an older build (no
`layout` key) still loads, defaulting to the single crop.

### The Editor tab

A small CapCut-style timeline for one vertical clip. Send any shorts candidate
there ("Timeline" in the Shorts transport), then add more clips — from this
VOD's candidates or any video file on disk — trim each one, reorder, and drop a
music track underneath with its own gain, looped to cover the cut.

The social overlay matches the reference layout: the clip title in heavy
outlined type across the top, and your Instagram and Twitch handles beside
their logos on the left, at an adjustable height. The logos are drawn with
NSBezierPath — nothing bundled, sharp at any size — and the whole overlay is
one transparent 1080×1920 PNG produced by a single renderer that both the
preview shows and the export burns, so they cannot disagree. Handles are
remembered across projects; you type them once.

**Shorts arrive portrait.** Sending a candidate to the timeline renders it
through the real shorts export first — its framing (single crop or the
cam+gameplay split), its captions, its audio tuning — so the timeline receives
a finished 1080×1920 piece, not the raw landscape source. Pieces are cached by
trim points and re-rendered only when the candidate changes.

**Captions are a per-clip choice.** A piece rendered from a candidate carries
its candidate's identity, so the selected-clip inspector has a Captions switch —
flipping it re-renders the piece with or without the burn (pixels can't be
un-burned) and swaps it in, with both variants cached separately.

**Titles and post copy, without the API bill.** The clipboard button next to
the title field, and the Post panel's Copy prompt, each put a ready-made
prompt on the clipboard with the transcript *under the clips actually on the
timeline* baked in — one asks for five truthful ≤60-character titles, the
other for a description plus ten hashtags. Paste into a claude.ai chat: it
comes out of the subscription, not a metered API key. (These two used to be
live API calls; the manual route replaced them by choice.)

**Free text** (the Text panel) puts as many extra lines on the frame as you
want — drag each one right on the preview (the grab area is measured from the
renderer's own text metrics, so what you grab is exactly what's drawn), or use
the Across/Down/size sliders; six colour swatches, with the outline flipping
black/white on its own to keep contrast. Untimed text lives in the same overlay
PNG as the title and handles, so the export burns them identically.

**Timed text.** "Time it" gives a line a window (starting at the playhead), and
a **text track** appears under the clip strip — one linear 0…duration lane
where blocks drag to move and trim at either edge, with At/For sliders as the
guaranteed path. The preview gates each timed line by the playhead; the export
ships each one as its own overlay input gated by the identical
`enable='between(t,start,end)'` window, so they cannot disagree.

**Drag everything.** Clip blocks drag to reorder (nearest-slot on release; the
arrows remain). A **Library** column holds video files dropped straight from
Finder plus this VOD's candidates — drag either onto the timeline, or
double-click. Files land full-length and trimmable; candidates render through
the real shorts export first, as always. The library persists per project.

**Per-clip framing and audio.** Every timeline clip — imported files
especially — gets Zoom (1–3× on top of the vertical fill), Across/Down pans
choosing which part of a wider-or-taller-than-9:16 frame survives the crop,
and its own audio gain (−36…+12 dB) separate from the music. The preview runs
the identical maths through an AVVideoComposition (so an imported landscape
clip previews with its real crop, not letterboxed — this also fixed an older
preview/export divergence), and the export runs it as the piece filter, whose
default case is byte-identical to the old plain cover-fit.

**Crossfades** overlap neighbouring clips (xfade + acrossfade at export, with
the transport showing the shortened export runtime); the preview cuts hard and
says so. Verified: an 8s + 6s timeline at 0.7s fade came out at exactly 13.3s,
with the blend visible in a mid-transition frame.

### The clip finder

After a VOD ingests, the app offers to find clips: pick how many (1/5/10/
custom), a length band (target, not hard rule — natural boundaries get ±15s),
and which categories. Runs in the background; editing stays live throughout.

**Categories are editable per streamer** — the description is injected into
the analysis prompt verbatim, so editing it *is* editing the detection, and
the UI says so. Each category also carries optional chat-emote hints.

**The pipeline**, cheapest signal first:
1. *Pre-filter*: the existing score curve keeps roughly the top quarter of
   the VOD — with a separate rescue path for long, quiet single-speaker
   stretches, because story times are exactly what an energy filter kills.
2. *Free signals*: emote-spike clustering thresholded against the VOD's own
   baseline (a chat that types KEKW constantly says nothing by typing it
   once more), chat-reading detection (the streamer echoing chat 2–15s
   later, fuzzy-matched), and monologue detection. These feed the prompt as
   hints — and they are the whole feature when no local model is installed.
3. *Local inference*: Ollama at 127.0.0.1, schema-constrained output, ~10
   minute chunks with 2.5 minutes of overlap (small local models degrade
   with long context). Model choice is RAM-gated: 14B wants 24 GB+, 8B runs
   in 16. Nothing leaves the machine; the cost is time — measured 13–18s per
   chunk for llama3.1:8b on this Mac, ~3–4 minutes for a 90-minute VOD.
4. *Selection*: overlap dedupe, sentence-boundary snapping off whisper's
   word timestamps (±0.3s/0.5s breath padding), and a category-balanced
   pick — plus a full request's worth of surplus held in reserve so a
   rejection pulls a replacement instead of a re-run.

Results cache in the project (`autoclips.json`), written after every chunk —
a crash at 30 of 36 keeps 30, re-opening never re-runs inference, and a bad
chunk is skipped after one retry rather than failing the run. The bin shows
suggestions grouped by category with confidence and the "why" line;
recategorizing is one click, because the label will be wrong sometimes.

**Honest expectations**: an 8B model lands at "usually right, occasionally
confidently wrong" — these are timestamped starting points, not uploads. And
without a chat replay imported, the funny/reaction categories are running
half-blind: the emote signals are the strongest thing this feature has.

### Export quality

The timeline renders each clip to an intermediate file, then encodes *again*
to lay on overlays and music. Both passes used to run at the same 10 Mbps, so
the second one quietly ate quality that was already paid for: measured against
a near-lossless reference, the intermediate scored SSIM 0.988 and the finished
file 0.983.

Two changes, both measured on real gameplay footage:

| Pipeline | SSIM |
|---|---|
| Old — 10 Mbps staged, 10 Mbps delivered | 0.981 |
| Now — 58 Mbps staged, 24 Mbps delivered | **0.993** |
| Ceiling — a single encode at 24 Mbps | 0.994 |

Intermediates now carry ~2.4× the delivery bitrate (clamped to 35–60 Mbps) and
320 kbps audio, so the join is the only pass that costs anything; delivery
defaults to 24 Mbps, which is where 1080p60 gameplay stops smearing on motion.
That lands within 0.001 SSIM of eliminating the second encode entirely — a
single-pass rewrite would buy almost nothing for considerable risk, so the
piece-then-join architecture stays.

A **Quality** picker (Shorts tab, export panel) offers Standard 12 / High 24 /
Maximum 40 Mbps, with the bitrate slider still there for a custom number.
Projects saved with the old 10 Mbps default are lifted to 24 on load — that
number was the defect, not a preference — while any bitrate actually chosen is
left alone.

### Finding media without leaving the app

**Find media…** (sidebar, or the globe in the Editor's library) opens a real
YouTube browser in a sheet — search like normal, open a video, and the
Download menu offers **MP4** (≤1080p, lands on the timeline), **MP3**, or
**WAV** (audio — becomes the music bed). Downloads go through the same yt-dlp
the link importer uses, into one shared Downloads folder that every project's
library lists; drag from there onto any timeline. Audio files route to music
automatically — they have no video stream to cut into the reel.

**Launch lands on the Dashboard** — with nothing selected, the detail pane *is*
the dashboard, so the first thing on screen is everyone's status. And **every
new project asks for its name and client up front**; picking a client applies
their caption look, framing, handles and vocabulary before ingest even starts,
so the vocabulary feeds transcription from the first chunk.

### Tracks, filmstrips, and the rest of the editing verbs

The strip is now real lanes with a fixed header column: **V1** (the cut,
filmstrip thumbnails + the source's own waveform under each block), **V2+**
(overlay rows — overlays carry a lane, higher lanes draw on top, blocks drag
along the lane with snapping), **TEXT**, **MUS**, **VO**. Every header has
mute and lock; audio lanes get **solo**. The controls flow through one pure
projection — `renderReady()` — that preview and export both consume, so a
muted track cannot differ between them: muted overlays take video and audio
with them, muted text hides its items, solo silences every non-soloed audio
lane (the main track's audio drops to −100 dB through the same per-clip gain
the piece encoder already honours), and lock simply disables that lane's
gestures.

Filmstrips come from a keyframe-tolerant `AVAssetImageGenerator` behind a
shared cache with two bucket tiers (2s tiles zoomed in, 8s zoomed out) so
zooming reuses frames instead of regenerating them. Also in: **roll trim**
(drag the junction between two clips — left grows, right shrinks, runtime
pinned by test), **I/O points** (`I`/`O`, tinted range, `⇧⌫` ripple-deletes
the range by blading both ends), **copy/paste/cut** (`⌘C/V/X` with the
timeline focused), **pinch zoom** (anchored like the keyboard zoom), and
**positional Finder drops** — a file dropped on the timeline lands at the
nearest cut to where it was dropped, audio files becoming the music bed.

### The editor's command layer

Every timeline mutation — 28 call sites — flows through one choke point,
`applyClipEdit(_:action:)`, with a named action. Undo is whole-document
snapshot: the EDL (`ClipEdit`) is a small value struct, so the inverse of any
command is simply the previous document — a few KB per step, 80 steps deep,
with the action name in the Edit menu ("Undo Split Clip"). Continuous
gestures coalesce: the same action landing within 0.8s extends the previous
step, so a slider drag is one undo, not two hundred. Gesture drags already
committed once on release (the draft-echo pattern), so the two mechanisms
compose. Undo registrations are removed when the editor detaches, so a stale
command can never target a dead session.

The timeline itself is now linear **pixels-per-second**: a ruler with
adaptive ticks, a playhead line you can scrub by dragging the ruler, markers
(M to add/remove at the playhead, snap targets, notes on hover), anchored
zoom (⌘+/⌘−/⌘0-to-fit, centred on the playhead), auto-follow during
playback, and a keyboard layer when the strip is focused: space, J/K/L
shuttle with acceleration, arrow frame-stepping (⇧ for seconds), S to blade,
M for markers, Home/End, Delete. Snapping (toggleable, ⌥ bypasses) pulls
dragged text blocks to the playhead, cut points and markers.

**Preview/export divergence, the documented choice:** both read the same EDL;
overlays and captions are literally the same PNGs, chroma keying runs the
same maths in Core Image (preview) and ffmpeg (export), and the piece filter
defaults are pinned byte-identical by tests. Export stays on ffmpeg —
`AVAssetExportSession` can't burn ASS captions or run the export's filter
graphs, so parity is enforced by shared inputs and tests rather than a shared
renderer.

### The editor grew up

**Two frames, one editor.** The timeline switches between 9:16 (shorts) and
16:9 (long-form) — overlay, text, preview and export all follow. **Open in
Editor** on the Long-form tab loads the whole assembled cut as trimmable
timeline clips in landscape.

**Focus modes.** The analysis takes a target — Funny moments, Chat
interaction, Story times, Missions & gameplay — implemented as weight scaling
over the local signals (laughter bursts, chat spikes, sustained speech, scene
cuts). Long-form length is a preset: 5, 10, 15, 20, 30, 45, 50 or 60 minutes.

**Chroma key.** Overlay videos sit on top of the cut at a draggable rect with
a timeline window; green (or blue) keys to transparency, with Strength and
Edge sliders for stubborn fringes and its own volume.

Keying in the *preview* needs a custom compositor. AVFoundation's built-in one
honours transforms and layer opacity but ignores per-pixel alpha outright — a
pre-keyed ProRes 4444 overlay composites with its transparent area rendered
opaque white, which is exactly the "chroma key isn't working" symptom. So the
preview runs `EditVideoCompositor`, a Core Image compositor that keys each
overlay live with a CIColorCube built from the same chroma-distance maths
ffmpeg's `chromakey` uses (U/V distance, `similarity` then `blend`). Edits
without overlays keep the cheaper stock path.

Because distance is measured on the chroma axes, a *shadowed* corner of a
green screen sits further from the key than a lit one — in this app exactly as
in ffmpeg. That is what Strength is for, and the behaviour is pinned by tests
rather than wished away.

**Voice-over.** Record rolls the mic while the preview plays from the
playhead; Stop drops the take exactly where it began, with its own position
and gain sliders, mixed through the same amix as music and overlay audio.

**Speed and freeze.** Per-clip 0.25–3× (snapping at the common stops):
`setpts` on video, chained `atempo` on audio so pitch survives; the preview
varispeeds and says so. Freeze holds the frame under the playhead — one
extracted still looped over silence, trimmable like any clip. The whole
timeline runs on effective (post-speed) durations. The `-ss/-t` pair moved to
input options when speed shipped — as output options a 2× clip would have kept
reading source past its out point (caught by a live render, fixed, re-proved:
4s at 2× = 2.00s exactly).

**Transitions.** The crossfade picker now carries twelve xfade styles — fade,
dissolve, wipes, slides, circles, pixelize, radial, blur — audio still
acrossfades underneath.

**Max-accuracy transcription.** A second re-transcribe path: the full
large-v3 model (not turbo) when installed — Setup has the download command —
with an earlier entropy fallback that rescues mumbled stretches. (Beam stays
at 8 — beam 12 plus the fallback trips a Metal assert in Homebrew's ggml on
the full model, found by running the real binary before shipping the flags.) Roughly 3–4× slower, measurably fewer mishearings;
the manual polish loop then catches what acoustics alone can't.

### Thumbnail Studio

A **Thumb** tab: layer panel, canvas, inspector, export — from VOD to
finished YouTube thumbnail without leaving the app. The canvas displays the
actual export render scaled to fit (the same `ThumbnailRenderer` output that
gets written to disk), so preview and file cannot disagree — the same
one-renderer trick the video overlay uses.

**Layers**: image, text, shape (rectangle/ellipse/line/arrow/polygon) — with
reorder, visibility, lock, opacity, blend modes (normal/multiply/screen/
overlay), duplicate, rotation, alignment guides that snap to centres, and a
dashed safe-zone box where YouTube stamps the duration.

**The point of building it in-house**: *Frame at playhead* grabs the exact
frame the editor preview is showing — through the same composition and video
composition — and *Frame picker* scrubs the source VOD for any other frame.

**Remove Background** is Vision's `VNGenerateForegroundInstanceMaskRequest` —
one click, on-device, a second or two; the cutout gets the standard treatment
(drop shadow, silhouette outline) and the original stays toggleable. Image
layers carry Core Image adjustments (brightness/contrast/saturation/exposure/
vibrance) plus filter presets, all cached so sliders stay live.

**Text** uses any installed family (curated thumbnail picks first), gradient
fills via mask clipping, stroke, shadow, and background box. **Templates**:
four starters aimed at IRL/Just Chatting, plus save-your-own shared across
projects. **Export**: PNG or JPG with a live size readout against YouTube's
2 MB cap and a compress-to-fit that walks quality down until it fits;
clipboard copy included. Undo runs through the same command layer as the
timeline — named steps, coalesced sliders.

Deliberately not built, per the brief: brushes, pen tools, multi-page — and
the cutout refinement brush is the one honest gap inside scope (Vision's
auto mask ships alone for now).

### Working for more than one channel

**Client profiles.** One profile per person you edit for: Twitch and Instagram
handles, the whole caption look (font, colours, karaoke), their webcam framing,
their vocabulary, their logo. The Editor's Client menu applies a profile to the
open project in one click — or captures the project's current look *as* one.
Applying is a pure, tested mapping; the roster lives in one `clients.json`
under Application Support, managed from the Dashboard.

**Platform export set.** "All platforms" renders the portrait master once, then
derives every destination from it: YouTube Shorts (trimmed only if over 3 min),
Reels (90s cap), TikTok (10 min cap), and a 16:9 YouTube version — the portrait
frame centred over a blurred blow-up of itself. Portrait derivatives are
stream-copy remuxes (seconds, no quality loss); only the landscape file
re-encodes. A file is trimmed only when a platform's cap demands it, and the
log says so.

**Export queue.** "Queue export" and "All platforms" drop a snapshot of the
timeline — clips, overlays, music, settings, all frozen at enqueue time — into
an app-wide queue that renders strictly one job at a time, unattended, across
any number of projects. Each job renders in its own working directory so a
queued job can't clobber a direct export. Watch progress in the Dashboard or
the sidebar button.

**Dashboard** (sidebar). Every project on one screen: client chip, status
(ingesting / ingested / shorts pending / exported / posted), shorts counts,
timeline size — statuses read straight off each project's JSON, no sessions
loaded. "Posted" is a manual checkbox, because the app can't know; it remembers
when you ticked it. The queue and the client roster live here too.

The preview is an AVComposition spanning *multiple files* (unlike the long-form
preview, which reads one source), with the music on its own track behind an
AVAudioMix carrying the export gain. Export renders each clip cover-fit to
1080×1920, joins with the concat demuxer, then lays the overlay and music on in
one pass — verified end to end: an 8s VOD clip + 6s file clip + music bed came
out at exactly 14.0s, hardware-encoded, with the music measurable in the mix
and the overlay pixel-identical to the preview PNG.

### Long-form assembly

The same score curve, selected differently: longer stretches (30–180s), taken
greedily by score, non-overlapping, until the total hits the 25–30 minute
target — then restored to **chronological order**, because a best-of that jumps
around in time reads as chaotic. Drag blocks to override it anyway.

Dead air inside a kept segment is cut out (default: gaps over 1.2s, keeping
0.25s of padding), and those cuts show as dashed seams on the timeline.

The preview is an **AVComposition** of the assembled pieces, not the raw source
— the player scrubs the actual cut with dead air already removed, so what you
review is what gets exported. The timeline's x axis is composition time.

Export renders each piece to identical encoder settings, then joins them.
Cutting first and joining second keeps a 27-minute assembly out of one
monolithic filter graph over a four-hour source.

### Polish

**Crossfades.** A dissolve reads better than a hard cut when the two moments are
hours apart. Joins become chained `xfade`/`acrossfade` with cumulative offsets —
each one overlaps by the fade length, so the cut ends up `(pieces − 1) × fade`
shorter, and the runtime badge accounts for that. The AVComposition preview
still plays hard cuts; crossfades are applied at export.

**Music bed with ducking.** An optional track, looped to cover the cut, mixed
under the programme at a configurable level. With ducking on, the programme
audio keys a `sidechaincompress` so the bed drops whenever anyone talks and
comes back in the gaps — measured at **10.3 dB** of attenuation with the default
8:1 ratio, and bit-identical to the un-ducked signal when nothing is speaking.

**Batch ingest.** Queue several VODs and leave them. Strictly sequential —
whisper already saturates the GPU, so parallel runs would be slower — with live
stage progress for the current item and already-ingested files skipped, so
re-running over a folder doesn't redo finished work.

Any of crossfades, music or captions forces a re-encode of the join. With none
of them, the join stays a concat-demuxer stream copy and costs almost nothing.

Everything is streamed or chunked — the source video is never read into memory.
Measured on a 4h12m / 9.6 GB 1080p60 VOD, the app's own resident size stays
around 75 MB for the entire run.

### Captions

Captions come from the transcript, so any line is editable in Browse (pencil
icon) — the correction rewrites the transcript itself and flows into scoring,
every clip, and every export, rather than fixing one clip.

A **live preview** draws them over the player using the real style, so the
styling values aren't abstract numbers until export. In the Shorts tab the
preview sits *inside* the 9:16 crop frame, because that rectangle is what
actually gets rendered.

Three delivery modes, per export:

| Mode | What you get | Use for |
|---|---|---|
| Burned in | Pixels, always visible | TikTok / Reels / Shorts — their players have no subtitle toggle |
| Closed | A `mov_text` track the viewer can switch off | YouTube, which reads and indexes it |
| Both | Both of the above | Cross-posting one render |

Plus optional **SRT and VTT sidecar files** written next to the video with the
same stem.

#### Cue length

Whisper's segments are sentences. On the test VOD they average 7.2 words, but
**1,236 of 6,257 run past 8 words and the longest is 117** — unreadable burned
into a vertical clip. Phrase grouping recuts them to a target word count
(default 7, adjustable 2–14).

The count is a target, not a rule, because cutting strictly every N words lands
mid-clause about half the time. A cue also breaks:

- **at any pause longer than 0.65 s**, however few words it holds;
- **at a full stop**, always — a cue never spans two sentences;
- **at a comma**, once it's within two words of the target.

Cue in and out points come from the words themselves, so the timing is whisper's
DTW output rather than an interpolation. Short cues are held to 0.55 s and small
holes between them are closed, so captions don't strobe.

The Browse preview looks up a pre-grouped index of the whole transcript rather
than regrouping around the playhead. A phrase can run across a segment boundary,
so a windowed preview disagrees with the export near the window edge — a first
attempt at anchoring the window on a forced break still disagreed on 28% of
probe times. Grouping once and binary-searching it is both exact and cheaper.

### Audio tuning

Measures how far your voice sits above the game, then rebalances at export.

What makes this more than three sliders is that the speech map comes from the
transcript. Whisper's word timings say to the syllable when you were talking and
when the only thing playing was the game — a level detector reading the mix
can't tell a shout from an explosion.

Two numbers, and the difference between them matters:

| | What it is | Can tuning move it? |
|---|---|---|
| **Voice above game** | Your level while talking vs the game's, both inside 200–3600 Hz | **No.** Two sources sharing a band are one signal. |
| **Clarity** | Your speech band vs everything outside it, while you're talking | **Yes** — this is what the knobs act on. |

The first is the diagnostic. On the test VOD it reads **3.4 dB**, and the
verdict says so plainly: most of that background sits inside the speech band,
which needs fixing in the stream mixer, not here.

Ducking uses a **written gain envelope** multiplied into the out-of-band
content, not a sidechain compressor — a compressor's reduction depends on how
hard the key hits it, so you ask for 6 dB and get whatever the detector decides.
The bands are split with `acrossover` (Linkwitz-Riley), whose reconstruction
measured **under 0.006 dB of error** at both split points and everywhere
between, so summing them back is transparent.

Measured on the shipped export, duck 5 dB + presence 3 dB:

| | Before | After |
|---|---|---|
| Speech band | −21.77 dB | −19.71 dB |
| Out of band | −32.64 dB | −35.56 dB |
| **Separation** | **10.87 dB** | **15.85 dB** |

Two things found by measuring rather than assuming:

- **`loudnorm` undoes the tuning.** Its single-pass mode moves gain over time,
  lifting the quiet stretches hardest — which are exactly the stretches where
  only the game is playing. It gave back 0.6 dB of the gap the tuning had just
  opened. Handing it measured values doesn't help either: this VOD is −33 LUFS
  with a −12 dBTP peak, so −14 LUFS needs +19 dB where only +10.6 fits, and it
  drops to dynamic mode on its own. Normalization is now a measured constant
  gain plus a true-peak limiter, which costs 0.43 dB of speech level against
  loudnorm's 0.96 — and only on transients.
- **`amix` deadlocks on asymmetric EOF.** The ducked bands end with the envelope
  while the middle band runs to the end of a four-hour source; amix's default
  `duration=longest` hung at 100% CPU for ten minutes on a 57-second clip.
  `duration=shortest`, plus an envelope written 5 s longer than the clip.

### Transcript accuracy

Whisper is the ceiling on everything downstream, so it gets every lever
available:

- **Wider beam search** (`-bs 8 -bo 8`) — greedy decoding takes wrong turns on
  fast, overlapping stream speech, and Metal absorbs the cost.
- **Chat names in the vocabulary hint.** The 20 most active chatters'
  usernames are appended to whisper's `--prompt` automatically — they're
  exactly the names the streamer keeps saying out loud, and exactly what
  whisper mangles without help.
- **Re-transcribe** (Browse inspector) throws the transcript away and redoes
  it with the current settings — resume otherwise treats old chunk transcripts
  as done, so improvements would never reach a finished project.
- **Fix mishearings with Claude** (manual, no API key): copy a batch prompt
  into a claude.ai chat — covered by the subscription — and paste the reply
  back; the loop walks the transcript 200 lines at a time. Only line-level
  corrections are applied — no rephrasing, no re-timing. A correction with the
  same word count keeps its per-word DTW timing, so karaoke stays
  sample-accurate through a fix. The pasted reply is parsed tolerantly (fences,
  prose) and verified against fixtures.

Captions follow **one master switch**: off means none in the preview and none
in the export. The delivery menu (burned / closed / both) refines how they
ship. In the shorts editor, captions preview live on the split layout's bands,
and the output sidebar burns the cue under the playhead through the real
export path — pixel truth.

### Style matching

Point at an edit you like — one of your own, or a creator's short — and the app
measures it: cut rhythm and shot-length distribution, how much silence the
editor left in, aspect ratio, runtime, and whether continuous audio sits under
the speech. Those map onto segment length bounds, dead-air trimming, target
runtime, and the music bed.

It is explicit about what it can't read. Caption fonts and colours, zooms,
punch-ins, overlays and colour grading aren't recoverable from a finished render.
Two measured caveats, both surfaced in the UI:

- **Cut detection misses similar-looking cuts.** Run against a render with 29
  known joins, it found 18 — keyframe comparison can't see a cut between two
  shots that look alike, or a dissolve.
- **A "bed" means continuous audio, not music.** A music track and non-stop game
  or room ambience are indistinguishable in an envelope, so gameplay footage
  reads as having one.

### Per-project layout

`~/Library/Application Support/VODEditor/Projects/<uuid>/`

| Path | What |
|---|---|
| `project.json` | All project state. Plain JSON, no DB server. |
| `audio/full16k.wav` | 16 kHz mono PCM (~115 MB/hour) — what whisper consumes. |
| `audio/chunks/` | ~10 min chunks, cut on silence boundaries. |
| `transcript/chunk_NNNN.json` | Raw whisper output, one file per chunk. |
| `transcript/transcript.json` | Merged, offset-corrected transcript. |
| `analysis/silence.json` | Silence intervals (also feeds Phase 3 dead-air trimming). |
| `analysis/waveform.bin` | One peak byte per 50 ms. |
| `analysis/score.json` | Interest curve and its per-signal components. |
| `shorts.json` | Candidates: in/out points, score breakdown, crop, caption edits, status. |
| `longform.json` | Long-form segments: in/out points, sequence order, included/binned. |
| `render/*.ass` | Generated subtitle files, kept so a failed render can be inspected. |

Source VODs are read in place and never copied or modified.

### Resumability

Each stage writes to disk before the next begins, and each chunk's JSON lands as
soon as that chunk finishes. Interrupting a run — cancel, crash, quit — costs at
most one chunk. Hitting Resume picks up where it stopped.

"Purge audio" in the inspector deletes the WAV and chunks once transcription is
done; they're re-derivable from the source and dominate disk usage.


### Motion, audio craft, and the manager's desk (July 2026 batch)

Twelve features in one pass, all local, all under verification:

- **Punch-in zooms** — loudness peaks + emphasized words become subtle keyframed
  pushes (`PunchInService`); detect per clip, add one at the playhead, intensity
  slider. Preview via AVFoundation transform ramps; export via ffmpeg `zoompan`
  piecewise expressions at 2× supersample. Proven live: a 2× push measured
  exactly 4× the white-square area, released clean.
- **Auto-reframe** — Vision faces (motion-centroid fallback) → smoothed,
  deadbanded pan keyframes (`ReframeService`/`ReframeSampler`). Pan-only clips
  keep a single lanczos scale with per-frame `crop` x/y expressions (proven:
  red|blue sweep landed pure-red → 50/50 → pure-blue).
- **SFX library** — `~/Desktop/VOD_Editor/SFX`, subfolders are tags, hotkeys 1–9
  drop at the playhead, SFX lane with drag/gain/remove, synthesized starter pack
  (ffmpeg generators, nothing shipped). Rides the amix chain and renderReady.
- **Tighten** — dead air + standalone "um"s from word timings; preview the cut
  list, apply as ONE undo step (`TightenService` + pure `rippleDelete`).
- **Version snapshots** — named cuts on disk (`versions/`), restore is undoable.
- **End cards / intro stings** — built from the client profile as a
  ThumbDocument (one renderer, no drift), baked to a normal timeline clip.
- **Beat sync** — onset flux + normalized autocorrelation with octave
  correction (`BeatGridService`; 120 BPM clicks measure 120.6, white noise
  honestly refuses); beat ticks on the music lane, drag snapping opts in.
- **Speaker guesses** — mic-level 2-means over transcript segments
  (`SpeakerLabelService`), reliability-gated; transcript mic icons and a
  "mostly my voice" candidate filter. A heuristic, labelled as one.
- **Hook doctor** — first-word timing, 3-second word density, payoff placement
  (`HookDoctorService`), with a loop-first-3s button.
- **Global search** — ⇧⌘F across every project's transcript; hits open the
  project seeked to the moment.
- **Posting runway** — per-candidate postedAt + per-client cadence → "runs
  through Aug 9" forecasts, dry-spell and same-day-dump warnings
  (`PostingForecastService`).
- **Disk reclaim** — per-project sizes on the dashboard; reclaim deletes only
  regenerable files and never touches anything the timeline references
  (`DiskReclaimService`, fixture-tested); archive-to-JSON keeps documents,
  transcript, analysis and snapshots.

### UI overhaul (same pass)

Global accent tint (no more blue system toggles), `StatText` hero-number type
scale, `InfoTip` popovers replacing standing explainer paragraphs, candidate
cards with poster frames + score bars (`PosterFrame`/`PosterCache`),
collapsible editor rails (⌥1/⌥2), sidebar material + nav/actions split with a
"+ New" menu, richer project rows (client chip, posted flag), crop-label/handle
collision fix, mode-switch and bin animations.


### Reliability, speed, and the back catalogue (July 2026, second batch)

- **Right-click menu on timeline clips** — split at playhead, duplicate, cut,
  copy, paste after, punch-ins, auto-reframe, reveal in Finder, delete. The
  first place anyone looks; it was the only surface in the app without one.
- **Media relinking** (`MediaRelinkService`) — every path is absolute, so one
  folder move used to break a project silently. Now: offline clips render with
  a red OFFLINE badge, a banner counts the missing files, and one folder pick
  matches everything by filename (falling back to the stem when a re-encode
  changed the extension) and rewires clips, overlays, SFX, music, voice-over
  and library in a single undoable step. Ambiguous matches prefer the
  shallowest path.
- **Portable backup** (`ProjectBundleService`) — the decisions, not the media:
  documents, transcript, analysis and snapshots as one `.vodbundle` (a plain
  ditto zip) for an external drive. Restore mints a fresh id so it can sit
  beside the original, and reopens with media offline for one relink.
- **Keyboard triage in the candidates bin** — J/K walk, space previews, A
  accepts, X discards, R resets, E sends to the editor. ~180 candidates a week
  were all mouse.
- **Export preflight** (`PreflightService`) — captions against TikTok/Reels/
  Shorts chrome with the exact margin to fix them, offline media as a blocker,
  clip slivers, stray text and SFX past the end, and how the voice sits against
  the game (from what the tuner actually measures — dBFS in and out of the
  speech band, not an invented LUFS number).
- **Local AI** (`LocalAIService`) — titles, description, hashtags and
  transcript polish now run through Ollama with schema-constrained decoding
  instead of a copy-paste round trip. The manual panel stays as the explicit
  fallback when the 8B isn't good enough.
- **Library** — cross-project compilation builder (filter accepted clips by
  category, score, date; cap the running time; build straight onto a timeline)
  and **running-bit detection** (`RecurringBitService`): phrase shingles across
  every transcript, filler-heavy windows dropped, and overlapping windows of
  one bit deduped **by shared occurrences** rather than by text — the windows
  of a single line aren't substrings of each other.
- **Gaps closed** — punch-ins now decode a peak envelope on demand for
  imported clips instead of refusing; auto-reframe samples at 3 fps and drops
  to 6 fps while the subject is moving fast.


### UI v2 + the banger pass (July 2026, third batch)

- **Cinema-dark re-skin** — near-black chrome, borderless panels (elevation by
  tone), a vertical icon mode-rail with a gradient pill (⌘1–⌘6) replacing the
  toolbar tabs, a per-project header bar, gradient hero CTAs, and a tabbed
  editor inspector (Clip / Design / Audio / Polish / Ship) replacing ten
  stacked panels.
- **Overflow actually fixed, with instrumentation** — the rails were being
  pushed off the window by the timeline controls row: labeled buttons gave the
  center column an 814pt minimum (measured via a temporary width reporter —
  the layout loads at 1088pt and grows as the edit arrives). The row is now an
  icon cluster with tooltips (~420pt), previews are layout-neutral
  (`Color.clear.overlay`), every fixed rail is `.frame().clipped()`, and the
  editor HStack measures 1108pt in a 1230pt container. Also fixed on the way:
  stale second app instances were poisoning screenshot verification, and
  `--window WxH` now pins the frame for reproducible layout runs.
- **Banger pass** — `LaughterSignals` (envelope modulation: loud AND pulsed at
  3–9 Hz with deep valleys; a held yell doesn't qualify — fixture-tested) +
  `BangerService`: instant heuristic (laughter density, emote spikes, early
  peak, punch, dense open) then a local-model judge over the top 16 in batches
  of 8, schema-constrained, blended 60/40. Flame badges at ≥70, "Hottest
  first" sort, hook lines ("Open on: …") in the inspector, flame count in the
  header bar.


### Thumbnail Studio as its own app (September 2026, fifth batch)

- **A second app, one codebase (`ThumbKit/`)** — the studio's files moved to a
  shared folder that both the VOD editor and a new `ThumbStudio` target
  compile, as one `PBXFileSystemSynchronizedRootGroup` listed in two targets.
  The only thing the studio needed from the VOD app was frame grabbing, so
  that became `ThumbFrameSource`: the VOD editor passes a bridge over its
  session and player, the standalone app passes nothing and the frame-grab
  affordances simply aren't there. Everything else — `NormalizedRect`,
  `UndoCoalescing`, `TimelineSnap`, `TimeInterval.timecode`, hex parsing —
  moved into ThumbKit as small shared files rather than being duplicated.
- **A keyboard, at last** — the old layer was thirteen invisible zero-size
  `Button`s carrying `.keyboardShortcut`, which is why Delete could never be
  added: a key equivalent is matched *before* the responder chain, so a bare
  key bound that way fires while you are typing. Now the menu bar owns every
  ⌘ shortcut (macOS renders, validates and enables them for free) and one
  `NSEvent` local monitor owns the unmodified keys — Delete, arrows, Tab,
  Escape, Return — behind three gates: our window must be key with no sheet
  attached, the first responder must not be an editable `NSTextView` (which
  is what a SwiftUI `TextField` borrows as its field editor), and anything
  carrying ⌘ passes straight through. An arrow press moves exactly one
  exported pixel; a held arrow is one undo step, but two Deletes are two.
- **Remove Background, properly** — it existed, buried in the image
  inspector, and wrote a `.cutout.png` next to your source photo. Now it has
  its own inspector section with the three controls that decide whether a
  cutout looks lifted or pasted (edge in, soften, harden), a subject picker
  when Vision finds more than one, and app-owned content-addressed storage,
  so re-picking settings you already tried costs nothing. Vision's raw mask
  keeps a fringe of old background; the refinement is a Core Image morphology
  contract, a contrast push, then a blur — in that order, because blurring
  first and eroding second eats the softness you just paid for. Measured at
  0.14 s on a 1920×1080 frame. Honest limits: fine hair, glass and motion
  blur are where it struggles, and the UI says so.
- **The visuals, rebuilt** — the studio wore the VOD editor's cinema-dark
  theme, whose whole premise ("so the footage is the only bright thing on
  screen") does not exist in a design tool, and whose surfaces are blue-tinted
  enough to shift how your artwork reads. The chrome is now achromatic
  graphite with one accent, on an 8pt scale, four control heights and six type
  styles. The editor gained the anatomy every tool of this kind has: a tool
  rail, a layers list with live thumbnails of each layer, the artboard on a
  workbench with real zoom, and an inspector that shows only what applies to
  what is selected. Export left the object inspector and became its own sheet.
  Deleted: the gradient hero, the uppercase micro-labels, the walls of
  `LabeledContent` sliders, and every hidden shortcut button.
- **A review pass, and the twenty-odd things it found** — splitting an app in
  two moves a lot of assumptions. Worth recording: a menu key equivalent is
  matched *before* the responder chain, so the Edit menu's ⌘C/⌘X/⌘V/⌘A were
  firing on layers while you typed (they hand the key back to the field editor
  now); Vision applies EXIF orientation and `CIImage` does not, so any photo
  off a phone had a rotated matte stretched across it; a new design reused the
  editor's model, so every keyboard verb kept writing to the design you just
  left; a SwiftUI `List` is an `NSTableView` that owns arrows and Delete, and
  the key monitor was stealing them from the VOD editor's project sidebar;
  SwiftUI runs the incoming view's `onAppear` before the outgoing one's
  `onDisappear`, so identity-checked teardown killed the layer that had just
  attached; a drop shadow cast from a 1%-alpha fill is not a shadow; and
  callbacks assigned to a view-owned model capture the view that owns it,
  which pinned every design you opened in memory for the session.

- **Previews stopped lying** — gallery cards and layer thumbnails used to
  render a *shrunken document*, which shrinks the canvas but not the stroke
  widths, shadow radii and corner radii, because those are absolute pixels.
  They now render at document size and downsample the bitmap.

### Thumb Lab + Canva-grade studio (July 2026, fourth batch)

- **Crop & Cut, one tool** — the crop sheet edits the diagonal alongside the
  region: the bright window IS the final shape (slant previewed with the
  renderer's exact geometry), so crop, aspect and cut land together in one
  undoable apply. Composition pixel-verified (crop to the blue half, slant
  its edge).
- **Sessions outlive views (`SessionRegistry`)** — navigating away from a
  project used to deallocate its session, whose deinit cancelled the ingest
  pipeline: transcription died silently when you opened the Thumb Lab. Views
  now borrow sessions from a registry; running sessions are never evicted.
- **Diagonal cuts + real cropping** — `cutEdge`/`cutAmount`/`cutFlip` on
  images AND shapes: one edge becomes a slant (the split-thumbnail look;
  pair a cut image with a cut gradient panel). Crop moved out of the
  provider cache into the renderer's draw source-rect, so every provider
  crops identically and the layer's aspect follows the crop; the new crop
  sheet has aspect presets (16:9, 9:16, 1:1, 4:5), corner handles, and a
  rule-of-thirds grid. All pixel-verified, both cut directions.
- **Thumb Lab v2 (a real tab)** — the Lab is a main-window destination now,
  not a floating sheet: a Canva-shaped home (gradient hero, aspect-true size
  cards, live-rendered template cards, adaptive grid of your designs with
  relative timestamps) and a full-bleed editor with back-navigation. Studio
  columns are fixed-and-clipped so no control row can paint past the window.
- **Thumb Lab v1** — thumbnails with no video attached. `ThumbStore` protocol
  splits the studio from the project session; `StandaloneThumbStore` keeps a
  gallery of designs (own undo, own autosave, background removal included) in
  `Application Support/ThumbLab`. Sidebar entry, ⇧⌘T, canvas presets, live
  gallery previews through the same renderer that exports.
- **Canva-grade studio** — canvas background colours; linear gradient fills
  on shapes with an angle dial; star and speech-bubble shapes; image frames
  (rounded/circle masks) with borders; align-to-canvas row (L/C/R + T/M/B
  using the drawn height); ⌥-arrow nudge (⌥⇧ for coarse); emoji sticker
  drawer; copy/paste text style (the paint roller). All pixel-verified:
  background fill, circle-mask corner clipping, and gradient direction are
  asserted from rendered bitmaps.
- **Ops lesson baked in** — a project stranded mid-ingest by a crash or quit
  now auto-resumes on open; the verify harness picks the newest project
  *with a finished transcript* (glob loop — the path has a space in it).

## Notes from building this

Things that were non-obvious and are easy to regress:

- **Flash attention silently kills word timestamps.** Homebrew's `whisper-cli`
  defaults `-fa` to on, and with it enabled every token comes back `t_dtw: -1`
  despite `-dtw` being passed. `WhisperService` passes `-nfa` alongside `-dtw`.
  It measured *faster* on Metal, so there's no tradeoff.
- **Per-token `offsets` in whisper's JSON are not usable.** Every token repeats
  the segment's start, and `to` is frequently smaller than `from`. Word timing
  is built from `t_dtw` alone (10 ms units), with gaps interpolated between
  known anchors — about 13% of tokens have no DTW anchor.
- **GUI apps don't inherit your shell PATH.** Launched from Finder, `PATH` is
  just `/usr/bin:/bin:/usr/sbin:/sbin`, so Homebrew tools are invisible.
  `ToolLocator` resolves absolute paths and supports per-tool overrides.
- **Core ML is not needed.** whisper.cpp uses Metal on Apple silicon out of the
  box. Measured on the same 9.4-minute chunk: **Metal 44s (12.8× realtime) vs
  CPU-only 197s (2.9×)** — 4.5× faster, which is already fast enough that the
  Core ML encoder conversion (~5 GB of torch/coremltools) buys nothing. The app
  reports which backend actually ran, so a silent CPU fallback is visible rather
  than assumed.
- **Scene detection only needs keyframes.** A full decode of a 4-hour 1080p60
  source takes ~23 minutes; `-skip_frame nokey` takes 64 seconds and finds
  essentially the same cuts, because Twitch VODs carry a keyframe every couple
  of seconds. This is why the signal is practical at all.
- **Whisper's word timing needs three corrections**, all of which were only
  visible on real content:
  1. Tokens are *subwords* (`don` + `'t`) with punctuation split off. Treated
     as words directly, ~47% end up zero-length because adjacent subwords share
     a 10 ms DTW frame. They're merged on the leading-space boundary.
  2. DTW routinely places a segment's last words *past* that segment's own
     `offsets.to` — true for 3,257 of 6,257 segments here. The terminal bound
     comes from the next segment's start instead.
  3. DTW anchors the first word up to a second late, leaving the start of each
     line with nothing highlighted. It's clamped back to the segment start.
- **Whisper's segments overlap.** A segment's end frequently runs past the next
  one's start (465 times here), so a binary search over `start..<end` ranges can
  land on a stale line. `indexOfSegment` searches `start` only and returns the
  last segment that has begun.
- **Don't pipe `whisper-cli` into `head`.** SIGPIPE kills it before it writes
  its JSON. Cost me one confusing debugging round.
- **Homebrew's `ffmpeg` has no libass.** No `ass`, `subtitles` or `drawtext`
  filter, and nothing in the version banner says so until you grep the
  configuration. `ffmpeg-full` is the fix. `ExportService` fails with an
  explicit message rather than an opaque filter error, and Setup checks for it.
- **Candidate windows need a floor above the curve's mean.** Expanding while the
  score stayed above `threshold × 0.5` put the floor *below* average, so every
  clip grew until it hit the 60s cap (mean duration 55s of a 15–60s range). Tying
  the floor to each peak (`max(mean + 0.25σ, peak × 0.65)`) brought the mean to
  27s with a real spread.
- **Saved settings shadow improved defaults.** The lenient decoder restores what
  was written, so changing a shipped default doesn't reach existing projects —
  which silently kept an old dedup threshold. Hence "Reset scoring settings" in
  the candidates menu.
- **Uppercase has to be applied to the words, not just the line.** The ASS
  builder renders from the per-word list for karaoke, so uppercasing only
  `line.text` did nothing to the output.
- **Overlapping whisper segments become stacked captions.** libass renders
  overlapping events on separate rows, putting two captions on screen at once.
  `CaptionBuilder` clamps each line's end to the next line's start.
- **Dead-air trimming is nearly a no-op on well-scored segments** — and that's
  correct, not broken. Scoring selects high-energy regions and silencedetect
  marks low-energy ones, so selection inherently avoids silence: on a real
  4-hour VOD, *zero* gaps over 1.2s fell inside the 30 selected segments, and
  even at a 0.6s threshold only 3.9s of 28.6 minutes was removable. It matters
  for content with long pauses inside otherwise-good stretches, and after manual
  trimming. `Tools/verify.sh` covers the path synthetically because production
  data doesn't reach it.

## Not built yet

Everything in the brief is built. The two optional extras are in as well —
scene detection (above) and the coherence pass (below) — both opt-in.

### Coherence pass (local model, or manual)

A single Claude call over the whole transcript, asking which moments across the
stream form a **throughline**: a running bit that escalates, a story told in
parts, or an arc set up early and paid off later. Long-form selection then
weights those beats and, if a throughline gets in *partially*, pulls in the
missing beats — keeping one beat of a three-part joke and dropping the setup is
worse than keeping none.

Two routes, both free. **Local**: the brief's original intent — the Ollama
model can't hold a four-hour transcript, so it runs two stages: each ~10-minute
window reports its notable bits (label, kind, timestamps), then one merge pass
over the bits — which is small enough to fit, and exactly the information a
throughline is made of — assembles them. Measured: ~76s for four windows on
the 8B, fully on-device. **Manual**: one copied prompt carrying the whole
transcript into a claude.ai chat, one pasted reply — a frontier model reading
everything at once is usually sharper than an 8B working in windows, and the
UI says so rather than pretending otherwise.

Swift has no official Anthropic SDK, so it's the Messages API over `URLSession`:
`claude-opus-4-8`, adaptive thinking, and structured outputs so the response is
guaranteed to parse. The transcript carries a `cache_control` breakpoint, so a
re-run after a tweak bills the transcript at cache-read rates. This VOD's
transcript is ~65K tokens, so a first call is roughly $0.32 of input.

### Editing without downloading

The default for a pasted link. Only the audio comes down; the video stays on
Twitch and the export pulls back just the parts you kept.

The whole thing turns on one line of the playlist. Twitch serves a finished VOD
as `#EXT-X-PLAYLIST-TYPE:EVENT`, which tells a player "more segments may still
be appended" — so ffmpeg and yt-dlp both refuse to seek it and start pulling
from the top. A 60-second cut two hours in **did not finish in six minutes**
that way. But the playlist is complete: it ends with `#EXT-X-ENDLIST`. Rewriting
that one line to `VOD` and making the 1,513 segment URLs absolute produces a
playlist ffmpeg will seek. The same cut then took **8 seconds**, and the frame
it produced was byte-identical to the same timestamp of the fully downloaded
file.

Two details that cost time to find:

- ffmpeg refuses a local playlist pointing at remote segments unless the nested
  protocols are whitelisted, and reports it as `Invalid data found when
  processing input` — which reads like a corrupt file, not a policy refusal.
- The audio is fetched with yt-dlp rather than decoded straight from the audio
  playlist by ffmpeg. yt-dlp pulls four fragments at once and measured roughly
  **twice** ffmpeg's single-connection rate, and it resumes — an interrupted
  ffmpeg decode would start the four hours over.

What it costs on the test VOD:

| | Download it | Stream it |
|---|---|---|
| Pulled before you can edit | 9.99 GB | **407 MB** (audio only) |
| Fetch audio | — | **~70 s** |
| Transcribe | ~19 min | ~19 min |
| **Time to an editable project** | ~30 min | **~21 min** |
| Pulled to export a 27-min cut | 0 | ~1.1 GB |

The streamed project produced **6,257 transcript segments, 30 candidates and a
27.0 minute cut** — the same numbers as the fully downloaded copy.

A 20-second vertical short, cut from 2:05:43 of the remote VOD and
hardware-encoded to 1080×1920, took **11 seconds** end to end.

Two honest limits. **Playback stutters**: this VOD has no 720p or 480p
rendition, only Source at 5,287 kbps, which is more than double the throughput
measured here — scrubbing to a point and looking at a frame is fine, continuous
playback is not. And the segment URLs are CDN paths that may stop resolving
eventually; there's a refresh for that, but I have no way to test how long they
last.

### Downloading from a link

yt-dlp does the fetching (`brew install yt-dlp`; it's the only optional tool,
and nothing else needs it). Two steps rather than one: the probe is cheap and
tells you the title, runtime and rough size *before* ten gigabytes start
landing, and it's what catches a link to a channel that's currently live —
which yt-dlp would otherwise record forever.

Progress does not use yt-dlp's own totals. For an HLS VOD they're extrapolated
from the current fragment: on the test VOD the estimate swung between 8.5 GB and
16.7 GB within seconds and the ETA read thirteen hours. The denominator comes
from the probe instead — bitrate × runtime, which predicted 9.99 GB against an
actual 9.62 GB, inside 4%. Only the byte count and speed come from yt-dlp.

**Speed.** Twitch throttles a *single* connection to about 340 KB/s, and no
downloader flag escapes that — yt-dlp measured 284 KB/s at both
`--concurrent-fragments 4` and `16`. Parallel *connections* are the whole
answer: four reach 16.3 MB/s, and eight and sixteen land in the same band. The
app fetches HLS segments itself over six connections rather than delegating to
yt-dlp's fragment loop, which took the audio for a four-hour VOD from **17.5
minutes to about 70 seconds**.

One subtlety cost an hour: a single `URLSession` multiplexes concurrent requests
onto one HTTP/2 connection, so six parallel downloads through one session
sustained 133 KB/s — *worse* than doing them one at a time. Each worker gets its
own session, and therefore its own TCP connection.

Two bugs this shook out:

- **The chunk planner made 38 chunks out of a 75-second clip.** With no cut
  points the segment muxer falls back to its own 2-second default, so a short
  source became 38 whisper invocations: 0.8× realtime instead of 13×, and a
  worse transcript for lack of context. Sources shorter than one chunk now
  bypass the muxer entirely. Nothing shorter than ten minutes had ever been
  ingested before links made it easy.
- **`--link` inherited `--ingest`'s process exit**, which would have killed the
  app after the first item of a queue.

### Publish: thumbnails and titles

A fourth tab. Stills are pulled from the moments the scorer rated highest —
`-ss` before `-i`, so each is a keyframe hop rather than a decode from the start
of a four-hour file — and text is burned over the chosen one through **libass**,
the same renderer the captions use, so the two can't drift apart. Exporting
writes 1280×720 and a 1080×1920 cover beside it.

Type scales by **width**, not height. Scaling by height made the vertical
cover's font 2.7× larger inside a frame 200 pixels narrower, and the text ran
straight off the right edge; margins still scale on their own axis so the bottom
one clears the platform's overlay.

The packaging pass works the same manual way: titles with the moment each one
came from, short-form hooks, thumbnail text, a description and tags. Titles over
60 characters are flagged, since YouTube truncates there. The system prompt is
blunt that a title promising something that doesn't happen is the one failure
mode that costs the channel more than a boring title does.

**Layers.** Anything you drop on the thumbnail — your logo, a facecam grab, a
sticker — becomes a positionable layer, dragged straight on the preview. PNG
keeps its transparency and SVG stays sharp at any size, because layers are
rasterised through AppKit (which reads SVG natively) rather than ffmpeg (which
can't), then composited as an overlay chain with the text always drawn last so
it stays legible.

**Claude draws overlay art.** Claude can't make images, but it draws — so overlay
*art* (badges, arrows, bursts, banners) comes back as SVG pasted from the chat
and renders on your machine. Nothing is fetched. The SVG is sanitised before
it's touched: `<script>`, `<image>`, `<use>`,
`<foreignObject>` and any remote `href` are refused outright, since the art is
rendered locally and a thumbnail overlay has no business reaching off the
machine.

Generated backgrounds are a copy-the-prompt affair too: the packaging reply
includes an image prompt, and a button copies it for whatever image generator
you already use — save the picture and add it with "Add image…". A real frame
from the stream is free and truthful, and for gameplay it generally beats an
illustration of something that didn't happen.
