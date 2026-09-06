import Foundation

/// The editor's output shape. The long-form cut edits in landscape; shorts
/// edit in portrait — one editor, two frames.
enum EditAspect: String, Codable, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }
    var width: Int { self == .portrait ? 1080 : 1920 }
    var height: Int { self == .portrait ? 1920 : 1080 }
    var label: String { self == .portrait ? "9:16 vertical" : "16:9 landscape" }
    var ratio: Double { Double(width) / Double(height) }
}

/// A zoom keyframe: at `t` seconds into the clip's effective (timeline)
/// span, the frame is pushed in by `v` on top of the clip's base zoom.
/// 1 is no push. Interpolation between keys is linear.
struct MotionKey: Codable, Equatable {
    var t: Double
    var v: Double
}

/// A pan keyframe: at `t` seconds into the clip's effective span, the crop
/// window centre sits at (`x`, `y`) — absolute fractions, replacing the
/// clip's static centerX/centerY while any pan keys exist.
struct PanKey: Codable, Equatable {
    var t: Double
    var x: Double
    var y: Double
}

/// Shared piecewise-linear sampling for both keyframe channels.
enum MotionCurve {
    /// Linear interpolation over sorted (t, value) pairs: flat before the
    /// first key, flat after the last, linear in between.
    static func sample(_ keys: [(t: Double, v: Double)], at time: Double) -> Double? {
        guard let first = keys.first else { return nil }
        if time <= first.t { return first.v }
        for (a, b) in zip(keys, keys.dropFirst()) where time < b.t {
            let span = b.t - a.t
            guard span > 0.0001 else { return b.v }
            return a.v + (b.v - a.v) * (time - a.t) / span
        }
        return keys[keys.count - 1].v
    }
}

/// One block on the editor timeline: a range of some video file.
struct TimelineClip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sourcePath: String
    /// In and out points in the source's own time.
    var start: Double
    var end: Double
    /// The source's full length, so trim handles know their bounds without
    /// re-probing the file on every render.
    var sourceDuration: Double
    var name: String = ""
    /// Set when this piece was rendered from a shorts candidate — which is what
    /// makes it re-renderable with different options later.
    var candidateID: UUID?
    /// Whether the piece was rendered with burned captions. Captions in a
    /// rendered piece are pixels; toggling them means rendering again.
    var hasCaptions: Bool = false
    /// Extra zoom on top of the cover-fit to 1080×1920. 1 is exactly cover-fit.
    var zoom: Double = 1
    /// Which part of the (zoomed) frame the 1080×1920 window keeps, as
    /// fractions of the spare width and height. 0.5 / 0.5 is centred — for a
    /// landscape clip this is the crop control even at zoom 1.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Gain applied to this clip's own audio, in dB. 0 leaves it alone.
    var gainDB: Double = 0
    /// Playback speed: 1 is real time, clamped to 0.25–3 everywhere it's used.
    /// Audio keeps its pitch on export (atempo); the preview varispeeds.
    var speed: Double = 1
    /// A held still: `start` is the frozen source frame, `end - start` is how
    /// long it holds. Speed is ignored; the audio is silence.
    var isFreeze: Bool = false
    /// Punch-in pushes: zoom multipliers over the base zoom, keyed in
    /// effective time. Empty means no pushes.
    var zoomKeys: [MotionKey] = []
    /// Auto-reframe pan: absolute crop centres keyed in effective time.
    /// While any exist they replace centerX/centerY.
    var panKeys: [PanKey] = []

    init(id: UUID = UUID(), sourcePath: String, start: Double, end: Double,
         sourceDuration: Double, name: String = "",
         candidateID: UUID? = nil, hasCaptions: Bool = false,
         zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5,
         gainDB: Double = 0, speed: Double = 1, isFreeze: Bool = false) {
        self.id = id
        self.sourcePath = sourcePath
        self.start = start
        self.end = end
        self.sourceDuration = sourceDuration
        self.name = name
        self.candidateID = candidateID
        self.hasCaptions = hasCaptions
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
        self.gainDB = gainDB
        self.speed = speed
        self.isFreeze = isFreeze
    }

    /// Hand-written so clips saved before `candidateID`/`hasCaptions` existed
    /// still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        sourceDuration = value(.sourceDuration, end)
        name = value(.name, "")
        candidateID = try? container.decodeIfPresent(UUID.self, forKey: .candidateID)
        hasCaptions = value(.hasCaptions, false)
        zoom = value(.zoom, 1)
        centerX = value(.centerX, 0.5)
        centerY = value(.centerY, 0.5)
        gainDB = value(.gainDB, 0)
        speed = value(.speed, 1)
        isFreeze = value(.isFreeze, false)
        zoomKeys = value(.zoomKeys, [])
        panKeys = value(.panKeys, [])
    }

    var hasMotion: Bool { !zoomKeys.isEmpty || !panKeys.isEmpty }

    /// The framing at `t` seconds into the clip's effective span: total zoom
    /// (base × keyed push) and the crop centre. With no keys this is exactly
    /// the static framing.
    func motionAt(_ t: Double) -> (zoom: Double, cx: Double, cy: Double) {
        let push = MotionCurve.sample(zoomKeys.map { ($0.t, $0.v) }, at: t) ?? 1
        let cx = MotionCurve.sample(panKeys.map { ($0.t, $0.x) }, at: t) ?? centerX
        let cy = MotionCurve.sample(panKeys.map { ($0.t, $0.y) }, at: t) ?? centerY
        return (min(4, max(1, zoom)) * max(1, push),
                min(1, max(0, cx)), min(1, max(0, cy)))
    }

    /// Every keyframe time, for instruction splitting.
    var motionTimes: [Double] {
        (zoomKeys.map(\.t) + panKeys.map(\.t)).sorted()
    }

    var url: URL { URL(fileURLWithPath: sourcePath) }
    /// The source range consumed — what ffmpeg reads.
    var duration: Double { max(0, end - start) }

    /// The blade: two clips cut at an offset into this clip's effective
    /// (timeline) span. Speed maps the offset back into source time; a
    /// freeze splits its hold, both halves showing the same frame. Nil when
    /// the cut would leave a sliver.
    func split(atOffset offset: Double) -> (TimelineClip, TimelineClip)? {
        guard offset > 0.25, offset < effectiveDuration - 0.25 else { return nil }
        var first = self
        var second = self
        second.id = UUID()
        if isFreeze {
            first.end = start + offset
            second.end = start + (end - start - offset)
        } else {
            let sourceCut = start + offset * clampedSpeed
            first.end = sourceCut
            second.start = sourceCut
        }
        // Motion keys land on whichever half holds their time, with a pinned
        // boundary key on each side so the framing doesn't jump at the cut.
        if hasMotion {
            let at = motionAt(offset)
            let basePush = MotionCurve.sample(zoomKeys.map { ($0.t, $0.v) }, at: offset) ?? 1
            if !zoomKeys.isEmpty {
                first.zoomKeys = zoomKeys.filter { $0.t < offset } + [MotionKey(t: offset, v: basePush)]
                second.zoomKeys = [MotionKey(t: 0, v: basePush)]
                    + zoomKeys.filter { $0.t > offset }.map { MotionKey(t: $0.t - offset, v: $0.v) }
            }
            if !panKeys.isEmpty {
                first.panKeys = panKeys.filter { $0.t < offset } + [PanKey(t: offset, x: at.cx, y: at.cy)]
                second.panKeys = [PanKey(t: 0, x: at.cx, y: at.cy)]
                    + panKeys.filter { $0.t > offset }.map { PanKey(t: $0.t - offset, x: $0.x, y: $0.y) }
            }
        }
        return (first, second)
    }
    var clampedSpeed: Double { min(3, max(0.25, speed)) }
    /// Seconds this clip occupies on the timeline — the source range divided
    /// by speed, or the held length for a freeze. Every piece of timeline
    /// arithmetic uses this, never `duration`.
    var effectiveDuration: Double {
        isFreeze ? duration : duration / clampedSpeed
    }
    /// Whether framing, audio, or timing strays from the plain defaults.
    var hasAdjustments: Bool {
        abs(zoom - 1) > 0.001 || abs(centerX - 0.5) > 0.001
            || abs(centerY - 0.5) > 0.001 || abs(gainDB) > 0.05
            || abs(speed - 1) > 0.001
    }
    var displayName: String {
        name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }
}

/// A free text element burned onto the frame. Position and size are fractions
/// of the frame, so the same numbers mean the same spot in the preview and in
/// the 1080×1920 export.
struct TextItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String = ""
    /// Centre of the text block, as fractions of the frame from the top-left.
    var x: Double = 0.5
    var y: Double = 0.3
    /// Font size as a fraction of frame height.
    var size: Double = 0.034
    /// Fill colour as RRGGBB hex. The outline flips black/white on its own to
    /// keep contrast.
    var colorHex: String = "FFFFFF"
    /// When the text appears, seconds into the cut.
    var startTime: Double = 0
    /// How long it stays. Zero (the default) means the whole video.
    var duration: Double = 0

    /// The swatches the editor offers.
    static let palette = ["FFFFFF", "FFD60A", "FF453A", "30D158", "0A84FF", "000000"]

    init(id: UUID = UUID(), text: String = "", x: Double = 0.5, y: Double = 0.3,
         size: Double = 0.034, colorHex: String = "FFFFFF",
         startTime: Double = 0, duration: Double = 0) {
        self.id = id
        self.text = text
        self.x = x
        self.y = y
        self.size = size
        self.colorHex = colorHex
        self.startTime = startTime
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        text = value(.text, "")
        x = value(.x, 0.5)
        y = value(.y, 0.3)
        size = value(.size, 0.034)
        colorHex = value(.colorHex, "FFFFFF")
        startTime = value(.startTime, 0)
        duration = value(.duration, 0)
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Whether the text has its own window instead of covering the whole cut.
    var isTimed: Bool { duration > 0.05 }
    var endTime: Double { startTime + duration }

    /// Whether the text is on screen at a given playhead time.
    func visible(at time: Double) -> Bool {
        !isTimed || (time >= startTime && time < endTime)
    }
}

/// A flag on the timeline — a note to self, a snap target, a place to jump
/// back to.
struct TimelineMarker: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var time: Double
    var note: String = ""

    init(id: UUID = UUID(), time: Double, note: String = "") {
        self.id = id
        self.time = time
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        time = try container.decode(Double.self, forKey: .time)
        note = value(.note, "")
    }
}

/// Per-track mute/solo/lock. Keys: "video", "overlays", "text", "music",
/// "voiceover". Solo applies to the audio side — any soloed track silences
/// One sound effect placed on the timeline.
struct SFXEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var path: String
    /// Where on the timeline it fires, in seconds.
    var startTime: Double
    var gainDB: Double = 0

    init(id: UUID = UUID(), path: String, startTime: Double, gainDB: Double = 0) {
        self.id = id
        self.path = path
        self.startTime = startTime
        self.gainDB = gainDB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        path = try container.decode(String.self, forKey: .path)
        startTime = value(.startTime, 0)
        gainDB = value(.gainDB, 0)
    }

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
}
/// every non-soloed one.
struct TrackControls: Codable, Equatable {
    var muted: Bool = false
    var solo: Bool = false
    var locked: Bool = false

    init(muted: Bool = false, solo: Bool = false, locked: Bool = false) {
        self.muted = muted
        self.solo = solo
        self.locked = locked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        muted = value(.muted, false)
        solo = value(.solo, false)
        locked = value(.locked, false)
    }
}

/// A video laid on top of the cut — green-screen memes, reaction cams,
/// anything from the media browser. Positioned by a normalized rect, gated by
/// a timeline window, and chroma-keyed on export.
struct OverlayClip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sourcePath: String
    /// Where in the source the overlay starts reading.
    var sourceStart: Double = 0
    /// How long it plays.
    var duration: Double = 5
    /// When it appears, seconds into the cut.
    var startTime: Double = 0
    /// Where it sits, as fractions of the frame. Height follows the source's
    /// own aspect; only x/y/width matter.
    var rect: NormalizedRect = NormalizedRect(x: 0.55, y: 0.55, width: 0.4, height: 0.4)
    /// Drop this colour to transparency on export (the preview shows the raw
    /// footage — keying happens in ffmpeg).
    var chromaEnabled: Bool = true
    var chromaHex: String = "00FF00"
    var chromaSimilarity: Double = 0.22
    var chromaBlend: Double = 0.08
    var muted: Bool = false
    var gainDB: Double = 0
    /// Which overlay row this clip sits on — higher lanes draw on top.
    var lane: Int = 0

    init(id: UUID = UUID(), sourcePath: String, sourceStart: Double = 0,
         duration: Double = 5, startTime: Double = 0,
         rect: NormalizedRect = NormalizedRect(x: 0.55, y: 0.55, width: 0.4, height: 0.4),
         chromaEnabled: Bool = true, chromaHex: String = "00FF00",
         chromaSimilarity: Double = 0.22, chromaBlend: Double = 0.08,
         muted: Bool = false, gainDB: Double = 0, lane: Int = 0) {
        self.id = id
        self.sourcePath = sourcePath
        self.sourceStart = sourceStart
        self.duration = duration
        self.startTime = startTime
        self.rect = rect
        self.chromaEnabled = chromaEnabled
        self.chromaHex = chromaHex
        self.chromaSimilarity = chromaSimilarity
        self.chromaBlend = chromaBlend
        self.muted = muted
        self.gainDB = gainDB
        self.lane = lane
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        sourceStart = value(.sourceStart, 0)
        duration = value(.duration, 5)
        startTime = value(.startTime, 0)
        rect = value(.rect, NormalizedRect(x: 0.55, y: 0.55, width: 0.4, height: 0.4))
        chromaEnabled = value(.chromaEnabled, true)
        chromaHex = value(.chromaHex, "00FF00")
        chromaSimilarity = value(.chromaSimilarity, 0.22)
        chromaBlend = value(.chromaBlend, 0.08)
        muted = value(.muted, false)
        gainDB = value(.gainDB, 0)
        lane = value(.lane, 0)
    }

    var url: URL { URL(fileURLWithPath: sourcePath) }
    var endTime: Double { startTime + duration }
}

/// The editor tab's document: a sequence of clips, optional music, and the
/// social overlay — title at the top, Twitch and Instagram handles beside
/// their logos on the left, matching the reference layout.
struct ClipEdit: Codable, Equatable {
    var clips: [TimelineClip] = []

    /// The output frame: portrait for shorts, landscape for the long-form cut.
    var aspect: EditAspect = .portrait

    /// Videos composited on top of the cut, chroma-keyed on export.
    var overlayClips: [OverlayClip] = []

    /// The xfade transition used between clips when crossfade > 0.
    var transitionStyle: String = "fade"

    /// A recorded voice-over laid under the cut from `voiceoverStart`.
    var voiceoverPath: String?
    var voiceoverStart: Double = 0
    var voiceoverGainDB: Double = 0

    /// The title burned across the top of the frame.
    var title: String = ""
    /// Handles shown beside the platform logos. Either can be empty; its badge
    /// simply isn't drawn.
    var twitchHandle: String = ""
    var instagramHandle: String = ""
    /// Vertical centre of the badge stack, as a fraction of the frame from the
    /// top — in the reference layout it sits just under the cam band.
    var handleY: Double = 0.52
    /// The socials block can be hidden entirely, or mirrored to the right
    /// edge with the text right-aligned against the logos.
    var showHandles: Bool = true
    var handlesOnRight: Bool = false

    /// Free text elements — as many as the user adds, dragged anywhere.
    var textItems: [TextItem] = []

    /// Flags on the timeline ruler.
    var markers: [TimelineMarker] = []

    /// Sound effects dropped on the timeline — a whoosh on a cut, a boom on
    /// a reveal. Audio-only events; they ride their own lane.
    var sfxEvents: [SFXEvent] = []



/// Per-track mute/solo/lock, keyed by track name.
    var trackControls: [String: TrackControls] = [:]

    /// The editor's media bin: files dropped in from Finder, kept per project
    /// so they're one drag away from the timeline.
    var library: [String] = []

    var musicPath: String?
    var musicGainDB: Double = -18

    /// Seconds of overlap between neighbouring clips. Zero is a hard cut.
    var crossfadeDuration: Double = 0

    var musicURL: URL? { musicPath.map { URL(fileURLWithPath: $0) } }
    var voiceoverURL: URL? { voiceoverPath.map { URL(fileURLWithPath: $0) } }
    var totalDuration: Double { clips.reduce(0) { $0 + $1.effectiveDuration } }

    /// What the export actually runs, since every crossfade overlaps a join.
    var exportDuration: Double {
        guard crossfadeDuration > 0, clips.count > 1 else { return totalDuration }
        return max(0, totalDuration - Double(clips.count - 1) * crossfadeDuration)
    }

    func controls(_ track: String) -> TrackControls {
        trackControls[track] ?? TrackControls()
    }

    /// The document as the renderer should see it: muted tracks stripped,
    /// solo resolved, locked state ignored (lock is an editing concern).
    /// Preview and export both run through this one projection, so a muted
    /// track can't differ between them.
    func renderReady() -> ClipEdit {
        var out = self
        let audioTracks = ["video", "overlays", "music", "voiceover", "sfx"]
        let anySolo = audioTracks.contains { controls($0).solo }
        func audioSilenced(_ track: String) -> Bool {
            let c = controls(track)
            return c.muted || (anySolo && !c.solo)
        }
        if controls("overlays").muted {
            out.overlayClips = []
        } else if audioSilenced("overlays") {
            for index in out.overlayClips.indices { out.overlayClips[index].muted = true }
        }
        if controls("text").muted { out.textItems = [] }
        if audioSilenced("music") { out.musicPath = nil }
        if audioSilenced("voiceover") { out.voiceoverPath = nil }
        if audioSilenced("sfx") { out.sfxEvents = [] }
        if audioSilenced("video") {
            for index in out.clips.indices { out.clips[index].gainDB = -100 }
        }
        return out
    }

    /// Ripple delete as a pure mutation: blades both boundaries, drops what
    /// falls inside, downstream closes up. The session's single-range delete
    /// and the tighten pass both run through this.
    mutating func rippleDelete(from rangeStart: Double, to rangeEnd: Double) -> Bool {
        guard rangeEnd > rangeStart + 0.15, !clips.isEmpty else { return false }
        for boundary in [rangeEnd, rangeStart] {
            var cursor: Double = 0
            for (index, clip) in clips.enumerated() {
                let width = clip.effectiveDuration
                if boundary > cursor + 0.01, boundary < cursor + width - 0.01 {
                    if let (first, second) = clip.split(atOffset: boundary - cursor) {
                        clips[index] = first
                        clips.insert(second, at: index + 1)
                    }
                    break
                }
                cursor += width
            }
        }
        var cursor: Double = 0
        let before = clips.count
        clips = clips.filter { clip in
            let inside = cursor >= rangeStart - 0.01
                && cursor + clip.effectiveDuration <= rangeEnd + 0.01
            cursor += clip.effectiveDuration
            return !inside
        }
        return clips.count != before
    }

    /// Roll trim: moves the cut point between clip `index` and its neighbour
    /// by `delta` timeline seconds — the first side grows, the second shrinks,
    /// total duration unchanged. Bounded by both sources and a half-second
    /// minimum on each side. Returns false when the roll can't happen.
    mutating func rollCut(after index: Int, by delta: Double) -> Bool {
        guard clips.indices.contains(index), clips.indices.contains(index + 1),
              abs(delta) > 0.001 else { return false }
        var first = clips[index]
        var second = clips[index + 1]

        if first.isFreeze {
            let hold = first.duration + delta
            guard hold >= 0.5 else { return false }
            first.end = first.start + hold
        } else {
            let end = first.end + delta * first.clampedSpeed
            guard end <= first.sourceDuration + 0.001,
                  (end - first.start) / first.clampedSpeed >= 0.5 else { return false }
            first.end = end
        }
        if second.isFreeze {
            let hold = second.duration - delta
            guard hold >= 0.5 else { return false }
            second.end = second.start + hold
        } else {
            let start = second.start + delta * second.clampedSpeed
            guard start >= -0.001,
                  (second.end - start) / second.clampedSpeed >= 0.5 else { return false }
            second.start = max(0, start)
        }
        clips[index] = first
        clips[index + 1] = second
        return true
    }

    /// The curated xfade transitions the picker offers.
    static let transitions: [(name: String, label: String)] = [
        ("fade", "Fade"), ("dissolve", "Dissolve"),
        ("wipeleft", "Wipe left"), ("wiperight", "Wipe right"),
        ("slideleft", "Slide left"), ("slideright", "Slide right"),
        ("circleopen", "Circle open"), ("circleclose", "Circle close"),
        ("pixelize", "Pixelize"), ("radial", "Radial"),
        ("smoothleft", "Smooth left"), ("hblur", "Blur"),
    ]
    var isEmpty: Bool { clips.isEmpty }

    init() {}

    /// Hand-written so an edit saved before `crossfadeDuration` existed still
    /// loads instead of failing the decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        clips = value(.clips, [])
        aspect = value(.aspect, EditAspect.portrait)
        overlayClips = value(.overlayClips, [])
        transitionStyle = value(.transitionStyle, "fade")
        voiceoverPath = try? container.decodeIfPresent(String.self, forKey: .voiceoverPath)
        voiceoverStart = value(.voiceoverStart, 0)
        voiceoverGainDB = value(.voiceoverGainDB, 0)
        title = value(.title, "")
        twitchHandle = value(.twitchHandle, "")
        instagramHandle = value(.instagramHandle, "")
        handleY = value(.handleY, 0.52)
        showHandles = value(.showHandles, true)
        handlesOnRight = value(.handlesOnRight, false)
        textItems = value(.textItems, [])
        markers = value(.markers, [])
        sfxEvents = value(.sfxEvents, [])
        trackControls = value(.trackControls, [:])
        library = value(.library, [])
        musicPath = try? container.decodeIfPresent(String.self, forKey: .musicPath)
        musicGainDB = value(.musicGainDB, -18)
        crossfadeDuration = value(.crossfadeDuration, 0)
    }

    /// Whether either handle would actually draw.
    var drawsHandles: Bool {
        showHandles && (!twitchHandle.trimmingCharacters(in: .whitespaces).isEmpty
                        || !instagramHandle.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Whether the overlay has anything to draw at all.
    var hasOverlay: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            || drawsHandles
            || textItems.contains { !$0.isBlank }
    }

    /// Whether the always-on PNG (title, handles, untimed text) has anything —
    /// timed text ships as its own gated overlays.
    var hasStaticOverlay: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            || drawsHandles
            || textItems.contains { !$0.isBlank && !$0.isTimed }
    }
}
