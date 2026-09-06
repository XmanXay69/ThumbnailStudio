import AVFoundation
import Foundation

struct ExportSettings: Codable, Equatable {
    var videoBitrateMbps: Double = 24
    var audioBitrateKbps: Int = 192
    /// Hardware encode. Software x264 on multi-hour sources is painfully slow,
    /// so this stays on unless something is broken.
    var useHardwareEncoder: Bool = true

    /// Burned in by default: shorts platforms don't surface subtitle tracks, so
    /// captions have to be pixels there to be seen at all.
    var captionMode: CaptionMode = .burned
    var writeSRTSidecar: Bool = false
    var writeVTTSidecar: Bool = false

    var wantsSidecars: Bool { writeSRTSidecar || writeVTTSidecar }

    /// The timeline renders each clip to an intermediate file and then encodes
    /// again to lay on overlays and music — two lossy passes. Measured against
    /// a near-lossless reference, a 10 Mbps intermediate dragged the finished
    /// file from SSIM 0.988 down to 0.983; giving the intermediate far more
    /// headroom than the final file costs only transient disk and puts the
    /// result back at 0.993, near the 0.994 ceiling of a single encode.
    var intermediateBitrateMbps: Double {
        min(60, max(35, videoBitrateMbps * 2.4))
    }

    /// Intermediates get generous audio too — AAC re-encoded from AAC at the
    /// same rate loses more than the bitrate suggests.
    var intermediateAudioKbps: Int { max(320, audioBitrateKbps) }

    static let standard = ExportSettings()

    /// Hand-written so a project saved before any of these fields existed
    /// still decodes — a failed decode would silently reset caption delivery.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        // Projects written before the quality work stored the old 10 Mbps
        // default. That number was the bug, not a preference, so it is lifted
        // to the current default; anything the user actually chose is kept.
        let stored = value(.videoBitrateMbps, 24.0)
        videoBitrateMbps = abs(stored - 10) < 0.01 ? 24 : stored
        audioBitrateKbps = value(.audioBitrateKbps, 192)
        useHardwareEncoder = value(.useHardwareEncoder, true)
        captionMode = value(.captionMode, CaptionMode.burned)
        writeSRTSidecar = value(.writeSRTSidecar, false)
        writeVTTSidecar = value(.writeVTTSidecar, false)
    }

    init() {}
}

/// The quality picker's stops. Bitrates are for 1080×1920 (or 1920×1080) at
/// 60 fps, where high-motion gameplay is the demanding case.
enum ExportQuality: String, CaseIterable, Identifiable {
    case standard, high, maximum

    var id: String { rawValue }
    var mbps: Double {
        switch self {
        case .standard: return 12
        case .high: return 24
        case .maximum: return 40
        }
    }
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .maximum: return "Maximum"
        }
    }
    var explainer: String {
        switch self {
        case .standard: return "12 Mbps — smallest files, fine for talking-head clips."
        case .high: return "24 Mbps — the default; matches the preview closely on gameplay."
        case .maximum: return "40 Mbps — for re-editing or archiving; platforms re-encode anyway."
        }
    }

    /// The nearest stop to a stored bitrate, so the picker reflects custom
    /// values instead of snapping them silently.
    static func nearest(to mbps: Double) -> ExportQuality {
        allCases.min { abs($0.mbps - mbps) < abs($1.mbps - mbps) } ?? .high
    }
}

struct ExportResult {
    var url: URL
    var elapsed: Double
    var usedHardwareEncoder: Bool
    var encoderName: String
    var averageFPS: Double?
    var sizeBytes: Int64
}

enum ExportError: LocalizedError {
    case captionsUnsupported
    case noMediaInfo
    case nothingToExport
    case filterUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .nothingToExport:
            return "The timeline is empty — include at least one segment before exporting."
        case .filterUnsupported(let name):
            return "This ffmpeg has no `\(name)` filter. Install the full build with: brew install ffmpeg-full"
        case .captionsUnsupported:
            return """
            This ffmpeg has no `ass` filter, so captions can't be burned in. \
            Homebrew's slim `ffmpeg` bottle omits libass — install the full \
            build with: brew install ffmpeg-full
            """
        case .noMediaInfo:
            return "Media info is missing; re-run ingest before exporting."
        }
    }
}

/// Renders a single vertical short. Always H.264/AAC in an MP4, always
/// 1080×1920, always hardware-encoded when the encoder is available.
struct ExportService {
    let ffmpeg: URL

    init() throws {
        guard let ffmpeg = ToolLocator.locate("ffmpeg") else { throw FFmpegError.toolMissing("ffmpeg") }
        self.ffmpeg = ffmpeg
    }

    /// Crop rectangle that carves a window of the given aspect out of the
    /// source, positioned horizontally by `centerX`. Defaults to 9:16.
    static func cropRect(sourceWidth: Int, sourceHeight: Int, centerX: Double,
                         targetAspect: Double = Double(ASSBuilder.renderWidth) / Double(ASSBuilder.renderHeight))
        -> (width: Int, height: Int, x: Int, y: Int) {
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)

        var cropWidth = sourceWidth
        var cropHeight = sourceHeight
        if sourceAspect > targetAspect {
            cropWidth = Int((Double(sourceHeight) * targetAspect).rounded())
        } else {
            cropHeight = Int((Double(sourceWidth) / targetAspect).rounded())
        }
        // libavfilter wants even dimensions for yuv420p.
        cropWidth = max(2, cropWidth - (cropWidth % 2))
        cropHeight = max(2, cropHeight - (cropHeight % 2))

        let maxX = max(0, sourceWidth - cropWidth)
        var x = Int((Double(sourceWidth) * centerX - Double(cropWidth) / 2).rounded())
        x = max(0, min(x, maxX))
        x -= x % 2

        var y = max(0, (sourceHeight - cropHeight) / 2)
        y -= y % 2

        return (cropWidth, cropHeight, x, y)
    }

    /// A normalized rectangle in source-pixel terms, with even dimensions.
    static func pixelRect(_ rect: NormalizedRect, sourceWidth: Int, sourceHeight: Int)
        -> (width: Int, height: Int, x: Int, y: Int) {
        let clamped = rect.clamped()
        var w = Int((Double(sourceWidth) * clamped.width).rounded())
        var h = Int((Double(sourceHeight) * clamped.height).rounded())
        w = max(2, min(sourceWidth, w - w % 2))
        h = max(2, min(sourceHeight, h - h % 2))
        var x = Int((Double(sourceWidth) * clamped.x).rounded())
        var y = Int((Double(sourceHeight) * clamped.y).rounded())
        x = max(0, min(sourceWidth - w, x)); x -= x % 2
        y = max(0, min(sourceHeight - h, y)); y -= y % 2
        return (w, h, x, y)
    }

    /// The filter that fits a source rectangle into a box, covering it (scale up
    /// to fill, then crop the overflow) so the box is always filled edge to edge.
    static func boxChain(_ rect: NormalizedRect, boxWidth: Int, boxHeight: Int,
                         media: MediaInfo) -> String {
        let px = pixelRect(rect, sourceWidth: media.width, sourceHeight: media.height)
        return "crop=\(px.width):\(px.height):\(px.x):\(px.y),"
            + "scale=\(boxWidth):\(boxHeight):force_original_aspect_ratio=increase:flags=lanczos,"
            + "crop=\(boxWidth):\(boxHeight),setsar=1"
    }

    /// The two-box portrait layout: the webcam scaled into its own band, the
    /// gameplay filling the rest, stacked to 1080×1920.
    ///
    /// The source is split so both boxes read from the same decoded frame, then
    /// `vstack` requires equal widths — which is why both are scaled to exactly
    /// 1080 before stacking. Both boxes are free rectangles, cover-fit into
    /// their bands, so each can be positioned and cropped independently.
    static func splitStatements(_ layout: ShortLayout, media: MediaInfo,
                                input: String, output: String) -> [String] {
        let fullWidth = ASSBuilder.renderWidth   // 1080
        let fullHeight = ASSBuilder.renderHeight // 1920

        var camHeight = Int((Double(fullHeight) * layout.camFraction).rounded())
        camHeight = max(2, min(fullHeight - 2, camHeight - camHeight % 2))
        let gameHeight = fullHeight - camHeight

        let camChain = boxChain(layout.camRect, boxWidth: fullWidth, boxHeight: camHeight, media: media)
        let gameChain = boxChain(layout.gameRect, boxWidth: fullWidth, boxHeight: gameHeight, media: media)

        var statements = [
            "[\(input)]split=2[splitcam][splitgame]",
            "[splitcam]\(camChain)[cambox]",
            "[splitgame]\(gameChain)[gamebox]",
        ]
        let order = layout.camOnTop ? "[cambox][gamebox]" : "[gamebox][cambox]"
        statements.append("\(order)vstack=inputs=2[\(output)]")
        return statements
    }

    /// The video filter graph for a clip's framing, shared by export and the
    /// output preview so the sidebar shows exactly what renders. `simpleChain`
    /// is non-nil only for a plain single crop, which can take the `-vf` fast
    /// path; the split layout always needs `-filter_complex`.
    static func videoGraph(candidate: ShortCandidate, media: MediaInfo,
                           assFilter: String?, output: String = "vout")
        -> (statements: [String], simpleChain: [String]?) {
        switch candidate.layout.mode {
        case .fill:
            // The single crop is a resizable rectangle, cover-fit to 1080×1920.
            // The editor keeps it 9:16 so cover-fit is exact (no extra crop),
            // but cover-fit also keeps a non-16:9 source or a hand-typed rect
            // filling the frame.
            var simple = [boxChain(candidate.layout.fillRect, boxWidth: renderWidth,
                                   boxHeight: renderHeight, media: media)]
            if let assFilter { simple.append(assFilter) }
            return (["[0:v]\(simple.joined(separator: ","))[\(output)]"], simple)
        case .split:
            var statements = splitStatements(candidate.layout, media: media, input: "0:v",
                                             output: assFilter == nil ? output : "vstacked")
            if let assFilter { statements.append("[vstacked]\(assFilter)[\(output)]") }
            return (statements, nil)
        }
    }

    static let renderWidth = ASSBuilder.renderWidth
    static let renderHeight = ASSBuilder.renderHeight

    /// Renders one frame of a clip's framing to an image, for the output
    /// sidebar. No captions or audio — just the composed picture, through the
    /// same graph the export uses.
    func renderPreviewFrame(candidate: ShortCandidate, source: URL, media: MediaInfo,
                            time: Double, assURL: URL? = nil, destination: URL) async throws {
        let assFilter = assURL.map { "ass=\(escapeFilterPath($0.path))" }
        let (statements, _) = Self.videoGraph(candidate: candidate, media: media, assFilter: assFilter)
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error",
                         "-ss", String(format: "%.3f", max(0, time))]
        arguments += HLSSource.inputArguments(for: source)
        arguments += ["-frames:v", "1",
                      "-filter_complex", statements.joined(separator: ";"),
                      "-map", "[vout]", "-q:v", "3", "-y", destination.path]
        try await Shell.runChecked(ffmpeg, arguments: arguments)
    }

    func exportShort(candidate: ShortCandidate,
                     source: URL,
                     media: MediaInfo,
                     lines: [CaptionLine],
                     style: CaptionStyle,
                     settings: ExportSettings,
                     tuning: AudioTuning = .standard,
                     speech: [ClosedRange<Double>] = [],
                     destination: URL,
                     workingDirectory: URL,
                     onProgress: @escaping (Double) -> Void,
                     onLog: @escaping (String) -> Void) async throws -> ExportResult {
        guard media.width > 0, media.height > 0 else { throw ExportError.noMediaInfo }

        let filters = await ToolLocator.ffmpegFilters()
        let hasCaptions = !lines.isEmpty
        let burnsIn = hasCaptions && settings.captionMode.burnsIn
        let embedsTrack = hasCaptions && settings.captionMode.embedsTrack
        if burnsIn && !filters.contains("ass") { throw ExportError.captionsUnsupported }

        let tunes = tuning.isActive
        if tunes, tuning.duckDB > 0, !filters.contains("acrossover") {
            throw ExportError.filterUnsupported("acrossover")
        }

        // The ASS file sits next to the output so a failed render can be
        // inspected rather than guessed at.
        let assURL = workingDirectory.appendingPathComponent("caption-\(candidate.id.uuidString).ass")
        if burnsIn {
            let contents = ASSBuilder.makeFile(lines: lines, style: style)
            try contents.write(to: assURL, atomically: true, encoding: .utf8)
        }

        // A soft track goes in as a second input and is muxed as mov_text —
        // the MP4 subtitle codec players can switch on and off.
        let softURL = workingDirectory.appendingPathComponent("caption-\(candidate.id.uuidString).srt")
        if embedsTrack {
            try CaptionExporter.srt(lines: lines).write(to: softURL, atomically: true, encoding: .utf8)
        }

        if hasCaptions, settings.wantsSidecars {
            try writeSidecars(lines: lines, settings: settings, beside: destination)
        }

        // The video filter graph, in two forms: a plain `chain` for the fast
        // `-vf` path (single crop, no tuning), and `videoStatements` for the
        // `-filter_complex` path that the split layout and audio tuning both
        // need. `chain` is left nil when only the complex form applies, which a
        // split graph always is.
        let assFilter = burnsIn ? "ass=\(escapeFilterPath(assURL.path))" : nil
        let (videoStatements, chain) = Self.videoGraph(candidate: candidate, media: media,
                                                       assFilter: assFilter)
        let needsComplex = tunes || chain == nil

        // The ducking envelope is written in clip time, so it lines up with the
        // trimmed audio without any offset arithmetic at render time.
        let keyURL = workingDirectory.appendingPathComponent("duck-\(candidate.id.uuidString).wav")
        let usesKey = tunes && tuning.needsSpeechKey && !speech.isEmpty
        if usesKey {
            try AudioTuner.writeDuckEnvelope(speech: speech, duration: candidate.duration,
                                             duckDB: tuning.duckDB, to: keyURL)
        }

        // Loudness is measured first so normalization can be applied as one
        // constant gain. Single-pass loudnorm moves its gain over time, and the
        // stretches it lifts hardest are the quiet ones — which here are the
        // stretches where only the game is playing.
        var loudness: LoudnessMeasurement?
        if tunes, tuning.normalize {
            var analysisInputs = ["-ss", String(format: "%.3f", candidate.start)]
            analysisInputs += HLSSource.inputArguments(for: source)
            if usesKey { analysisInputs += ["-i", keyURL.path] }
            analysisInputs += ["-t", String(format: "%.3f", candidate.duration), "-vn"]
            loudness = try await AudioTuner.measureLoudness(
                ffmpeg: ffmpeg, inputArguments: analysisInputs,
                key: usesKey ? "1:a" : nil, tuning: tuning
            )
            if loudness == nil { onLog("Loudness analysis produced no reading; normalizing dynamically instead") }
        }

        let encoder = settings.useHardwareEncoder ? "h264_videotoolbox" : "libx264"
        var arguments = [
            "-hide_banner", "-nostdin",
            "-progress", "pipe:1",
            "-ss", String(format: "%.3f", candidate.start),
        ]
        // A streamed project's source is a playlist, and seeking it pulls only
        // the segments this clip covers.
        arguments += HLSSource.inputArguments(for: source)
        var nextInput = 1
        var keyIndex: Int?
        if usesKey {
            keyIndex = nextInput
            nextInput += 1
            arguments += ["-i", keyURL.path]
        }
        var subtitleIndex: Int?
        if embedsTrack {
            subtitleIndex = nextInput
            nextInput += 1
            arguments += ["-i", softURL.path]
        }
        // `-t` must come after every input. Between two `-i` flags it is read as
        // an *input* option for the one that follows — which silently left the
        // video unbounded and encoded the whole four-hour source.
        arguments += ["-t", String(format: "%.3f", candidate.duration)]

        if needsComplex {
            // `-vf` and `-filter_complex` can't both feed the same output, so
            // whichever features are on, the video graph goes inside the complex
            // form here.
            var statements = videoStatements
            if tunes {
                statements += AudioTuner.filters(input: "0:a",
                                                 key: keyIndex.map { "\($0):a" },
                                                 tuning: tuning, output: "aout",
                                                 loudness: loudness)
                arguments += ["-filter_complex", statements.joined(separator: ";"),
                              "-map", "[vout]", "-map", "[aout]"]
            } else {
                arguments += ["-filter_complex", statements.joined(separator: ";"),
                              "-map", "[vout]", "-map", "0:a:0"]
            }
        } else {
            arguments += ["-map", "0:v:0", "-map", "0:a:0"]
        }
        if let subtitleIndex { arguments += ["-map", "\(subtitleIndex):0", "-c:s", "mov_text"] }
        if !needsComplex, let chain { arguments += ["-vf", chain.joined(separator: ",")] }
        arguments += ["-c:v", encoder]
        if settings.useHardwareEncoder {
            // VideoToolbox has no CRF; it's bitrate-targeted.
            let bitrate = Int(settings.videoBitrateMbps * 1000)
            arguments += [
                "-b:v", "\(bitrate)k",
                "-maxrate", "\(Int(Double(bitrate) * 1.25))k",
                "-bufsize", "\(bitrate * 2)k",
                "-profile:v", "high",
            ]
        } else {
            arguments += ["-crf", "19", "-preset", "medium"]
        }
        arguments += [
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "\(settings.audioBitrateKbps)k", "-ar", "48000", "-ac", "2",
            "-movflags", "+faststart",
            "-y", destination.path,
        ]

        var encoderConfirmed = false
        var encoderName = encoder
        var lastFPS: Double?
        let started = Date()
        let duration = candidate.duration

        try await Shell.runChecked(ffmpeg, arguments: arguments, onOutputLine: { line in
            if let seconds = FFmpegService.parseProgressTime(line), duration > 0 {
                onProgress(min(seconds / duration, 1))
            }
            if line.hasPrefix("fps="), let value = Double(line.dropFirst(4)) { lastFPS = value }
        }, onErrorLine: { line in
            // ffmpeg names the encoder it actually bound in the stream mapping.
            if line.contains("h264_videotoolbox") {
                encoderConfirmed = true
                encoderName = "h264_videotoolbox"
            } else if line.contains("libx264") {
                encoderName = "libx264"
            }
            if line.lowercased().contains("error") || line.contains("Unable to") {
                onLog(line)
            }
        })

        onProgress(1)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ExportResult(
            url: destination,
            elapsed: Date().timeIntervalSince(started),
            usedHardwareEncoder: encoderConfirmed,
            encoderName: encoderName,
            averageFPS: lastFPS,
            sizeBytes: Int64(size)
        )
    }

    /// Sidecar caption files land next to the video with the same stem, which
    /// is the convention players and upload tools expect.
    func writeSidecars(lines: [CaptionLine], settings: ExportSettings, beside destination: URL) throws {
        let stem = destination.deletingPathExtension()
        var formats: [CaptionFileFormat] = []
        if settings.writeSRTSidecar { formats.append(.srt) }
        if settings.writeVTTSidecar { formats.append(.vtt) }
        for format in formats {
            let url = stem.appendingPathExtension(format.fileExtension)
            try CaptionExporter.contents(lines: lines, format: format)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Long form

    /// Renders each kept range to a uniformly-encoded piece, then joins them
    /// with the concat demuxer. Cutting first and copying second is what keeps
    /// a 27-minute assembly out of a single monolithic filter graph over a
    /// four-hour source.
    func exportLongForm(pieces: [AssembledPiece],
                        source: URL,
                        media: MediaInfo,
                        settings: ExportSettings,
                        captionLines: [CaptionLine],
                        style: CaptionStyle,
                        tuning: AudioTuning = .standard,
                        speech: [ClosedRange<Double>] = [],
                        options: LongFormOptions,
                        destination: URL,
                        workingDirectory: URL,
                        onProgress: @escaping (Double) -> Void,
                        onLog: @escaping (String) -> Void) async throws -> ExportResult {
        guard !pieces.isEmpty else { throw ExportError.nothingToExport }
        guard media.width > 0, media.height > 0 else { throw ExportError.noMediaInfo }

        let hasCaptions = !captionLines.isEmpty
        let burnCaptions = hasCaptions && settings.captionMode.burnsIn
        let available = await ToolLocator.ffmpegFilters()
        if burnCaptions && !available.contains("ass") { throw ExportError.captionsUnsupported }
        if options.crossfadeEnabled && !available.contains("xfade") { throw ExportError.filterUnsupported("xfade") }
        if options.musicEnabled && options.musicDucking && !available.contains("sidechaincompress") {
            throw ExportError.filterUnsupported("sidechaincompress")
        }
        if tuning.isActive, tuning.duckDB > 0, !available.contains("acrossover") {
            throw ExportError.filterUnsupported("acrossover")
        }

        let fileManager = FileManager.default
        let piecesDirectory = workingDirectory.appendingPathComponent("longform-pieces", isDirectory: true)
        try? fileManager.removeItem(at: piecesDirectory)
        try fileManager.createDirectory(at: piecesDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: piecesDirectory) }

        let started = Date()
        var encoderConfirmed = false
        var encoderName = settings.useHardwareEncoder ? "h264_videotoolbox" : "libx264"
        let totalDuration = pieces.reduce(0) { $0 + $1.duration }
        var completedDuration: Double = 0

        // Pass 1 — cut and re-encode every piece to identical parameters.
        var pieceURLs: [URL] = []
        for (index, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            let pieceURL = piecesDirectory.appendingPathComponent(String(format: "piece_%04d.mp4", index))
            pieceURLs.append(pieceURL)

            var arguments = [
                "-hide_banner", "-nostdin",
                "-progress", "pipe:1",
                "-ss", String(format: "%.3f", piece.source.start),
            ]
            arguments += HLSSource.inputArguments(for: source)
            arguments += [
                "-t", String(format: "%.3f", piece.duration),
                "-vf", "scale=1920:1080:flags=lanczos,setsar=1",
                "-c:v", encoderName,
            ]
            arguments += encoderArguments(settings)
            arguments += [
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "\(settings.audioBitrateKbps)k", "-ar", "48000", "-ac", "2",
                "-y", pieceURL.path,
            ]

            let pieceDuration = piece.duration
            let alreadyDone = completedDuration
            try await Shell.runChecked(ffmpeg, arguments: arguments, onOutputLine: { line in
                if let seconds = FFmpegService.parseProgressTime(line), totalDuration > 0 {
                    let overall = (alreadyDone + min(seconds, pieceDuration)) / totalDuration
                    onProgress(min(overall * 0.85, 0.85))
                }
            }, onErrorLine: { line in
                if line.contains("h264_videotoolbox") { encoderConfirmed = true }
                if line.lowercased().contains("error") { onLog(line) }
            })
            completedDuration += piece.duration
        }

        // Pass 2 — join. Stream copy when nothing needs re-encoding; otherwise
        // one filter graph carrying crossfades, captions and the music bed.
        let listURL = piecesDirectory.appendingPathComponent("concat.txt")
        let listBody = pieceURLs
            .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
        try listBody.write(to: listURL, atomically: true, encoding: .utf8)

        var assURL: URL?
        if burnCaptions {
            let url = workingDirectory.appendingPathComponent("longform.ass")
            try ASSBuilder.makeFile(lines: captionLines, style: style, width: 1920, height: 1080)
                .write(to: url, atomically: true, encoding: .utf8)
            assURL = url
        }

        var softURL: URL?
        if hasCaptions, settings.captionMode.embedsTrack {
            let url = workingDirectory.appendingPathComponent("longform.srt")
            try CaptionExporter.srt(lines: captionLines).write(to: url, atomically: true, encoding: .utf8)
            softURL = url
        }

        if hasCaptions, settings.wantsSidecars {
            try writeSidecars(lines: captionLines, settings: settings, beside: destination)
        }

        // Built in composition time, so it lines up with the assembled cut
        // rather than the source — the same rebasing the captions get.
        var keyURL: URL?
        if tuning.isActive, tuning.needsSpeechKey, !speech.isEmpty {
            let url = workingDirectory.appendingPathComponent("longform-duck.wav")
            try AudioTuner.writeDuckEnvelope(speech: speech, duration: totalDuration,
                                             duckDB: tuning.duckDB, to: url)
            keyURL = url
        }

        var loudness: LoudnessMeasurement?
        if tuning.isActive, tuning.normalize {
            var analysisInputs = ["-f", "concat", "-safe", "0", "-i", listURL.path]
            if let keyURL { analysisInputs += ["-i", keyURL.path] }
            analysisInputs += ["-vn"]
            loudness = try await AudioTuner.measureLoudness(
                ffmpeg: ffmpeg, inputArguments: analysisInputs,
                key: keyURL != nil ? "1:a" : nil, tuning: tuning
            )
        }

        let joinArguments = joinCommand(
            pieceURLs: pieceURLs,
            pieceDurations: pieces.map(\.duration),
            listURL: listURL,
            assURL: assURL,
            softSubtitleURL: softURL,
            tuning: tuning,
            duckKeyURL: keyURL,
            loudness: loudness,
            options: options,
            settings: settings,
            encoderName: encoderName,
            destination: destination
        )

        var lastFPS: Double?
        try await Shell.runChecked(ffmpeg, arguments: joinArguments, onOutputLine: { line in
            if let seconds = FFmpegService.parseProgressTime(line), totalDuration > 0 {
                onProgress(0.85 + min(seconds / totalDuration, 1) * 0.15)
            }
            if line.hasPrefix("fps="), let value = Double(line.dropFirst(4)) { lastFPS = value }
        }, onErrorLine: { line in
            if line.contains("h264_videotoolbox") { encoderConfirmed = true }
            if line.lowercased().contains("error") { onLog(line) }
        })

        onProgress(1)
        if !settings.useHardwareEncoder { encoderName = "libx264" }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ExportResult(
            url: destination,
            elapsed: Date().timeIntervalSince(started),
            usedHardwareEncoder: encoderConfirmed,
            encoderName: encoderName,
            averageFPS: lastFPS,
            sizeBytes: Int64(size)
        )
    }

    // MARK: - Clip editor timeline

    /// The per-piece framing chain: cover-fit to 1080×1920 with the clip's own
    /// zoom on top, then the crop window parked at the clip's chosen centre.
    /// Zoom 1 / centre 0.5 must reproduce the plain cover-fit exactly.
    static func clipPieceVideoFilter(zoom: Double, centerX: Double, centerY: Double,
                                     width: Int = ASSBuilder.renderWidth,
                                     height: Int = ASSBuilder.renderHeight,
                                     speed: Double = 1) -> String {
        let z = min(4, max(1, zoom))
        let scale: String
        if abs(z - 1) < 0.001 {
            scale = "scale=\(width):\(height):force_original_aspect_ratio=increase:flags=lanczos"
        } else {
            // Even dimensions — encoders reject odd ones.
            let zw = Int((Double(width) * z / 2).rounded()) * 2
            let zh = Int((Double(height) * z / 2).rounded()) * 2
            scale = "scale=\(zw):\(zh):force_original_aspect_ratio=increase:flags=lanczos"
        }
        let cx = min(1, max(0, centerX))
        let cy = min(1, max(0, centerY))
        let crop: String
        if abs(z - 1) < 0.001, abs(cx - 0.5) < 0.001, abs(cy - 0.5) < 0.001 {
            crop = "crop=\(width):\(height)"
        } else {
            crop = String(format: "crop=%d:%d:(in_w-%d)*%.4f:(in_h-%d)*%.4f",
                          width, height, width, cx, height, cy)
        }
        let clamped = min(3, max(0.25, speed))
        // setpts re-times before fps snaps back to constant 60.
        let pts = abs(clamped - 1) < 0.001 ? "" : String(format: ",setpts=PTS/%.4f", clamped)
        return "\(scale),\(crop),setsar=1\(pts),fps=60"
    }

    /// A piecewise-linear ffmpeg expression over sorted keyframes: flat
    /// before the first key, flat after the last, linear in between —
    /// exactly `MotionCurve.sample`, evaluated by ffmpeg per frame.
    static func piecewiseExpr(_ keys: [(t: Double, v: Double)], timeVar: String) -> String {
        func f(_ value: Double) -> String { String(format: "%.4f", value) }
        let sorted = keys.sorted { $0.t < $1.t }
        guard let first = sorted.first else { return "0" }
        guard sorted.count > 1 else { return f(first.v) }
        var expr = f(sorted[sorted.count - 1].v)
        for index in stride(from: sorted.count - 2, through: 0, by: -1) {
            let a = sorted[index]
            let b = sorted[index + 1]
            let span = max(0.0001, b.t - a.t)
            let seg = "\(f(a.v))+(\(f(b.v))-\(f(a.v)))*(\(timeVar)-\(f(a.t)))/\(f(span))"
            expr = "if(lt(\(timeVar)\\,\(f(b.t)))\\,\(seg)\\,\(expr))"
        }
        return "if(lt(\(timeVar)\\,\(f(first.t)))\\,\(f(first.v))\\,\(expr))"
    }

    /// The motion-aware piece filter. Static clips fall through to the
    /// proven chain. Pan-only motion keeps the single lanczos scale and
    /// slides the crop window with per-frame expressions (crop x/y take
    /// `t`, which runs in source time — key times are scaled by speed).
    /// Varying zoom goes through zoompan at 2× supersample, placed after
    /// the retiming so its clock is effective time.
    static func clipPieceVideoFilter(for clip: TimelineClip,
                                     width: Int = ASSBuilder.renderWidth,
                                     height: Int = ASSBuilder.renderHeight) -> String {
        let zoomVaries = clip.zoomKeys.contains { abs($0.v - 1) > 0.001 }
        guard !clip.isFreeze, clip.hasMotion, zoomVaries || !clip.panKeys.isEmpty else {
            return clipPieceVideoFilter(zoom: clip.zoom, centerX: clip.centerX,
                                        centerY: clip.centerY,
                                        width: width, height: height,
                                        speed: clip.isFreeze ? 1 : clip.clampedSpeed)
        }
        let speed = clip.clampedSpeed
        let zb = min(4, max(1, clip.zoom))
        let super2 = zoomVaries ? 2 : 1
        let boxW = Int((Double(width * super2) * zb / 2).rounded()) * 2
        let boxH = Int((Double(height * super2) * zb / 2).rounded()) * 2
        let cropW = width * super2
        let cropH = height * super2

        // Pan expressions run before setpts: source time = effective × speed.
        let xExpr: String
        let yExpr: String
        if clip.panKeys.isEmpty {
            xExpr = String(format: "(iw-ow)*%.4f", min(1, max(0, clip.centerX)))
            yExpr = String(format: "(ih-oh)*%.4f", min(1, max(0, clip.centerY)))
        } else {
            let xs = clip.panKeys.map { (t: $0.t * speed, v: min(1, max(0, $0.x))) }
            let ys = clip.panKeys.map { (t: $0.t * speed, v: min(1, max(0, $0.y))) }
            xExpr = "(iw-ow)*(\(piecewiseExpr(xs, timeVar: "t")))"
            yExpr = "(ih-oh)*(\(piecewiseExpr(ys, timeVar: "t")))"
        }

        var chain = [
            "scale=\(boxW):\(boxH):force_original_aspect_ratio=increase:flags=lanczos",
            "crop=\(cropW):\(cropH):x='\(xExpr)':y='\(yExpr)'",
            "setsar=1",
        ]
        if abs(speed - 1) > 0.001 {
            chain.append(String(format: "setpts=PTS/%.4f", speed))
        }
        chain.append("fps=60")
        if zoomVaries {
            let pushes = clip.zoomKeys.map { (t: $0.t, v: max(1, $0.v)) }
            let zExpr = "max(1\\,\(piecewiseExpr(pushes, timeVar: "it")))"
            chain.append("zoompan=z='\(zExpr)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2'"
                + ":d=1:s=\(width)x\(height):fps=60")
        }
        return chain.joined(separator: ",")
    }

    /// atempo only accepts 0.5–2 per instance, so out-of-range speeds chain.
    static func atempoChain(speed: Double) -> [String] {
        var remaining = min(3, max(0.25, speed))
        guard abs(remaining - 1) > 0.001 else { return [] }
        var chain: [String] = []
        while remaining > 2 { chain.append("atempo=2.0"); remaining /= 2 }
        while remaining < 0.5 { chain.append("atempo=0.5"); remaining /= 0.5 }
        chain.append(String(format: "atempo=%.4f", remaining))
        return chain
    }

    /// The clip's own audio chain — pitch-preserving speed plus gain; nil
    /// means leave the stream untouched.
    static func clipPieceAudioFilter(gainDB: Double, speed: Double = 1) -> String? {
        var parts = atempoChain(speed: speed)
        if abs(gainDB) > 0.05 {
            parts.append(String(format: "volume=%.1fdB", gainDB))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// A freeze piece: one extracted frame looped for the hold, silence under
    /// it, framed through the same piece filter as everything else.
    static func clipFreezeArguments(framePNG: URL, duration: Double, videoFilter: String,
                                    settings: ExportSettings, encoderName: String,
                                    destination: URL) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-progress", "pipe:1",
                         "-loop", "1", "-i", framePNG.path,
                         "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
                         "-t", String(format: "%.3f", max(0.1, duration)),
                         "-map", "0:v", "-map", "1:a",
                         "-vf", videoFilter,
                         "-c:v", encoderName]
        // Also an intermediate: it gets joined and re-encoded like any piece.
        arguments += encoderArguments(settings, mbps: settings.intermediateBitrateMbps)
        arguments += ["-pix_fmt", "yuv420p",
                      "-c:a", "aac", "-b:a", "\(settings.intermediateAudioKbps)k",
                      "-ar", "48000", "-ac", "2",
                      "-y", destination.path]
        return arguments
    }

    /// Renders the editor timeline: each clip cover-fit to 1080×1920 and
    /// encoded uniformly, joined with the concat demuxer, then the social
    /// overlay and music laid on in one final pass. Same piece-then-join shape
    /// as the long-form export, and for the same reason — clips can come from
    /// different files at different sizes.
    func exportClipEdit(clips: [TimelineClip],
                        overlays: [TimedOverlay],
                        videoOverlays: [VideoOverlay] = [],
                        voiceover: VoiceoverInput? = nil,
                        sfx: [SFXInput] = [],
                        musicURL: URL?,
                        musicGainDB: Double,
                        crossfade: Double = 0,
                        transition: String = "fade",
                        renderWidth: Int = ASSBuilder.renderWidth,
                        renderHeight: Int = ASSBuilder.renderHeight,
                        settings: ExportSettings,
                        destination: URL,
                        workingDirectory: URL,
                        onProgress: @escaping (Double) -> Void,
                        onLog: @escaping (String) -> Void) async throws -> ExportResult {
        guard !clips.isEmpty else { throw ExportError.nothingToExport }

        let fileManager = FileManager.default
        let piecesDirectory = workingDirectory.appendingPathComponent("timeline-pieces", isDirectory: true)
        try? fileManager.removeItem(at: piecesDirectory)
        try fileManager.createDirectory(at: piecesDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: piecesDirectory) }

        let started = Date()
        var encoderConfirmed = false
        let encoderName = settings.useHardwareEncoder ? "h264_videotoolbox" : "libx264"
        let totalDuration = clips.reduce(0) { $0 + $1.effectiveDuration }
        var completedDuration: Double = 0

        var pieceURLs: [URL] = []
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let pieceURL = piecesDirectory.appendingPathComponent(String(format: "piece_%03d.mp4", index))
            pieceURLs.append(pieceURL)

            let arguments: [String]
            if clip.isFreeze {
                // Extract the held frame, then loop it for the duration.
                let frameURL = piecesDirectory.appendingPathComponent("freeze_\(index).png")
                var extract = ["-hide_banner", "-nostdin",
                               "-ss", String(format: "%.3f", clip.start)]
                extract += HLSSource.inputArguments(for: clip.url)
                extract += ["-frames:v", "1", "-y", frameURL.path]
                try await Shell.runChecked(ffmpeg, arguments: extract,
                                           onOutputLine: { _ in }, onErrorLine: { _ in })
                arguments = Self.clipFreezeArguments(
                    framePNG: frameURL, duration: clip.duration,
                    videoFilter: Self.clipPieceVideoFilter(zoom: clip.zoom, centerX: clip.centerX,
                                                           centerY: clip.centerY,
                                                           width: renderWidth, height: renderHeight),
                    settings: settings, encoderName: encoderName, destination: pieceURL)
            } else {
                // -ss and -t are INPUT options here — with a speed change the
                // output is shorter than the source range, so an output-side
                // -t would keep reading source past the clip's out point.
                var built = [
                    "-hide_banner", "-nostdin", "-progress", "pipe:1",
                    "-ss", String(format: "%.3f", clip.start),
                    "-t", String(format: "%.3f", clip.duration),
                ]
                built += HLSSource.inputArguments(for: clip.url)
                built += [
                    "-vf", Self.clipPieceVideoFilter(for: clip,
                                                     width: renderWidth, height: renderHeight),
                ]
                if let audio = Self.clipPieceAudioFilter(gainDB: clip.gainDB, speed: clip.clampedSpeed) {
                    built += ["-af", audio]
                }
                built += ["-c:v", encoderName]
                // Intermediates carry far more bitrate than the delivered
                // file: this piece is about to be decoded and encoded again,
                // so anything thrown away here is gone for good.
                built += Self.encoderArguments(settings, mbps: settings.intermediateBitrateMbps)
                built += [
                    "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "\(settings.intermediateAudioKbps)k",
                    "-ar", "48000", "-ac", "2",
                    "-y", pieceURL.path,
                ]
                arguments = built
            }

            let pieceDuration = clip.effectiveDuration
            let alreadyDone = completedDuration
            try await Shell.runChecked(ffmpeg, arguments: arguments, onOutputLine: { line in
                if let seconds = FFmpegService.parseProgressTime(line), totalDuration > 0 {
                    onProgress(min((alreadyDone + min(seconds, pieceDuration)) / totalDuration * 0.85, 0.85))
                }
            }, onErrorLine: { line in
                if line.contains("h264_videotoolbox") { encoderConfirmed = true }
                if line.lowercased().contains("error") { onLog(line) }
            })
            completedDuration += clip.effectiveDuration
        }

        let joinArguments: [String]
        if crossfade > 0, pieceURLs.count > 1 {
            joinArguments = Self.clipEditCrossfadeCommand(
                pieceURLs: pieceURLs, pieceDurations: clips.map(\.effectiveDuration),
                overlays: overlays, videoOverlays: videoOverlays, voiceover: voiceover,
                sfx: sfx,
                musicURL: musicURL, musicGainDB: musicGainDB,
                crossfade: crossfade, transition: transition,
                renderWidth: renderWidth, renderHeight: renderHeight,
                settings: settings,
                encoderName: encoderName, destination: destination
            )
        } else {
            let listURL = piecesDirectory.appendingPathComponent("concat.txt")
            try pieceURLs
                .map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: "\n")
                .write(to: listURL, atomically: true, encoding: .utf8)
            joinArguments = Self.clipEditJoinCommand(
                listURL: listURL, overlays: overlays,
                videoOverlays: videoOverlays, voiceover: voiceover,
                sfx: sfx,
                musicURL: musicURL,
                musicGainDB: musicGainDB,
                renderWidth: renderWidth, renderHeight: renderHeight,
                settings: settings,
                encoderName: encoderName, destination: destination
            )
        }
        try await Shell.runChecked(ffmpeg, arguments: joinArguments, onOutputLine: { line in
            if let seconds = FFmpegService.parseProgressTime(line), totalDuration > 0 {
                onProgress(0.85 + min(seconds / totalDuration, 1) * 0.15)
            }
        }, onErrorLine: { line in
            if line.contains("h264_videotoolbox") { encoderConfirmed = true }
            if line.lowercased().contains("error") { onLog(line) }
        })

        onProgress(1)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ExportResult(url: destination, elapsed: Date().timeIntervalSince(started),
                            usedHardwareEncoder: encoderConfirmed, encoderName: encoderName,
                            averageFPS: nil, sizeBytes: Int64(size))
    }

    /// An overlay PNG and the window it's shown in — nil bounds mean always on.
    struct TimedOverlay {
        var url: URL
        var start: Double?
        var end: Double?

        /// The ffmpeg enable clause for the window; empty for always-on.
        var enableClause: String {
            guard start != nil || end != nil else { return "" }
            let from = String(format: "%.3f", start ?? 0)
            let to = end.map { String(format: "%.3f", $0) } ?? "1e9"
            return ":enable='between(t,\(from),\(to))'"
        }
    }

    /// Chains every overlay onto the running video label, timed ones gated by
    /// their enable window.
    private static func overlayChain(_ overlays: [TimedOverlay], firstInput: Int,
                                     videoLabel: inout String, filters: inout [String]) {
        for (offset, overlay) in overlays.enumerated() {
            let label = "vov\(offset)"
            filters.append("[\(videoLabel)][\(firstInput + offset):v]overlay=0:0:format=auto"
                           + overlay.enableClause + "[\(label)]")
            videoLabel = label
        }
    }

    /// A video composited on top of the cut — scaled to its rect, optionally
    /// chroma-keyed, shown for exactly its window.
    struct VideoOverlay {
        var url: URL
        var sourceStart: Double
        var duration: Double
        var startTime: Double
        var rect: NormalizedRect
        /// nil = no keying; otherwise RRGGBB dropped to transparency.
        var chromaHex: String?
        var similarity: Double = 0.22
        var blend: Double = 0.08
        var muted: Bool = false
        var gainDB: Double = 0
    }

    /// A recorded voice-over mixed in from `start`.
    struct VoiceoverInput {
        var url: URL
        var start: Double
        var gainDB: Double
    }

    /// A sound effect fired at `start` — same mixing shape as the
    /// voice-over, of which there can be many.
    struct SFXInput {
        var url: URL
        var start: Double
        var gainDB: Double
    }

    /// The edit's SFX events as export inputs, missing files dropped.
    static func sfxInputs(for edit: ClipEdit) -> [SFXInput] {
        edit.sfxEvents
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { SFXInput(url: $0.url, start: $0.startTime, gainDB: $0.gainDB) }
    }

    /// Each overlay video is its own input, trimmed at the demuxer.
    private static func appendVideoOverlayInputs(_ videoOverlays: [VideoOverlay],
                                                 arguments: inout [String],
                                                 nextInput: inout Int) -> [Int] {
        var indices: [Int] = []
        for overlay in videoOverlays {
            arguments += ["-ss", String(format: "%.3f", overlay.sourceStart),
                          "-t", String(format: "%.3f", overlay.duration),
                          "-i", overlay.url.path]
            indices.append(nextInput)
            nextInput += 1
        }
        return indices
    }

    /// Scales, keys, re-times and parks each overlay video. The setpts shift
    /// matters: the trimmed input's frames start at t≈0, but the enable window
    /// opens at startTime — without the shift the footage would already be
    /// finished by the time its window opens.
    private static func videoOverlayChain(_ videoOverlays: [VideoOverlay], indices: [Int],
                                          renderWidth: Int, renderHeight: Int,
                                          videoLabel: inout String, filters: inout [String]) {
        for (offset, overlay) in videoOverlays.enumerated() {
            let width = max(2, Int((overlay.rect.width * Double(renderWidth) / 2).rounded()) * 2)
            var chain = "[\(indices[offset]):v]scale=\(width):-2"
            if let hex = overlay.chromaHex {
                chain += String(format: ",chromakey=0x%@:%.2f:%.2f", hex, overlay.similarity, overlay.blend)
            }
            chain += String(format: ",setpts=PTS-STARTPTS+%.3f/TB", overlay.startTime)
            let scaled = "ovv\(offset)"
            chain += "[\(scaled)]"
            filters.append(chain)
            let x = Int((overlay.rect.x * Double(renderWidth)).rounded())
            let y = Int((overlay.rect.y * Double(renderHeight)).rounded())
            let out = "vvo\(offset)"
            filters.append(String(format: "[%@][%@]overlay=%d:%d:enable='between(t,%.3f,%.3f)'[%@]",
                                  videoLabel, scaled, x, y,
                                  overlay.startTime, overlay.startTime + overlay.duration, out))
            videoLabel = out
        }
    }

    /// Maps the edit's overlay clips to export inputs, muting any whose file
    /// has no audio stream — an optional stream would fail the filter graph.
    static func videoOverlayInputs(for edit: ClipEdit) async -> [VideoOverlay] {
        var overlays: [VideoOverlay] = []
        for clip in edit.overlayClips where FileManager.default.fileExists(atPath: clip.sourcePath) {
            let asset = AVURLAsset(url: clip.url)
            let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            overlays.append(VideoOverlay(
                url: clip.url, sourceStart: clip.sourceStart, duration: clip.duration,
                startTime: clip.startTime, rect: clip.rect.clamped(),
                chromaHex: clip.chromaEnabled ? clip.chromaHex : nil,
                similarity: clip.chromaSimilarity, blend: clip.chromaBlend,
                muted: clip.muted || !hasAudio, gainDB: clip.gainDB))
        }
        return overlays
    }

    /// The whole audio side: the cut's own audio joined with music, overlay
    /// audio and the voice-over through one amix.
    private static func audioMixChain(baseLabel: String,
                                      musicIndex: Int?, musicGainDB: Double,
                                      videoOverlays: [VideoOverlay], overlayIndices: [Int],
                                      voiceoverIndex: Int?, voiceover: VoiceoverInput?,
                                      sfxIndices: [Int] = [], sfx: [SFXInput] = [],
                                      filters: inout [String]) -> String {
        var extras: [String] = []
        if let musicIndex {
            let gain = pow(10, musicGainDB / 20)
            filters.append("[\(musicIndex):a]volume=\(String(format: "%.3f", gain))[mus]")
            extras.append("mus")
        }
        for (offset, overlay) in videoOverlays.enumerated() where !overlay.muted {
            let label = "aov\(offset)"
            filters.append(String(format: "[%d:a]adelay=%d:all=1,volume=%.3f[%@]",
                                  overlayIndices[offset],
                                  Int((overlay.startTime * 1000).rounded()),
                                  pow(10, overlay.gainDB / 20), label))
            extras.append(label)
        }
        if let voiceoverIndex, let voiceover {
            filters.append(String(format: "[%d:a]adelay=%d:all=1,volume=%.3f[vo]",
                                  voiceoverIndex,
                                  Int((voiceover.start * 1000).rounded()),
                                  pow(10, voiceover.gainDB / 20)))
            extras.append("vo")
        }
        for (offset, event) in sfx.enumerated() where sfxIndices.indices.contains(offset) {
            let label = "sfx\(offset)"
            filters.append(String(format: "[%d:a]adelay=%d:all=1,volume=%.3f[%@]",
                                  sfxIndices[offset],
                                  Int((event.start * 1000).rounded()),
                                  pow(10, event.gainDB / 20), label))
            extras.append(label)
        }
        guard !extras.isEmpty else {
            filters.append("[\(baseLabel)]anull[amixed]")
            return "amixed"
        }
        let inputs = ([baseLabel] + extras).map { "[\($0)]" }.joined()
        filters.append("\(inputs)amix=inputs=\(extras.count + 1):duration=first:normalize=0[amixed]")
        return "amixed"
    }

    // MARK: - Platform derivatives

    /// One platform file from the portrait master. Portrait targets are a fast
    /// stream-copy remux (trimmed only when the platform cap demands it); the
    /// landscape target re-encodes the frame centred over a blurred blow-up of
    /// itself — the standard treatment for a vertical clip on YouTube proper.
    static func platformDeriveCommand(master: URL, planned: PlatformPreset.Planned,
                                      settings: ExportSettings, encoderName: String,
                                      destination: URL) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-i", master.path]
        if let cap = planned.trimmedTo {
            arguments += ["-t", String(format: "%.3f", cap)]
        }
        switch planned.preset.kind {
        case .portrait:
            arguments += ["-c", "copy"]
        case .landscapeBlur:
            arguments += ["-filter_complex",
                "[0:v]split=2[bg][fg];"
                + "[bg]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,boxblur=32,setsar=1[bgb];"
                + "[fg]scale=-2:1080[fgs];"
                + "[bgb][fgs]overlay=(W-w)/2:(H-h)/2[v]",
                "-map", "[v]", "-map", "0:a?",
                "-c:v", encoderName]
            if settings.useHardwareEncoder {
                let bitrate = Int(settings.videoBitrateMbps * 1000)
                arguments += ["-b:v", "\(bitrate)k",
                              "-maxrate", "\(Int(Double(bitrate) * 1.25))k",
                              "-bufsize", "\(bitrate * 2)k",
                              "-profile:v", "high"]
            } else {
                arguments += ["-crf", "19", "-preset", "medium"]
            }
            arguments += ["-pix_fmt", "yuv420p", "-c:a", "copy"]
        }
        arguments += ["-movflags", "+faststart", "-y", destination.path]
        return arguments
    }

    /// Derives the whole platform set from an already-rendered portrait
    /// master. The master renders once; everything else is seconds.
    func exportPlatformSet(master: URL, duration: Double, stem: String,
                           directory: URL, settings: ExportSettings,
                           onLog: @escaping (String) -> Void) async throws -> [URL] {
        let encoderName = settings.useHardwareEncoder ? "h264_videotoolbox" : "libx264"
        var outputs: [URL] = []
        for planned in PlatformPreset.plan(duration: duration) {
            let destination = directory.appendingPathComponent("\(stem)-\(planned.preset.name).mp4")
            let arguments = Self.platformDeriveCommand(
                master: master, planned: planned, settings: settings,
                encoderName: encoderName, destination: destination)
            try await Shell.runChecked(ffmpeg, arguments: arguments, onOutputLine: { _ in },
                                       onErrorLine: { line in
                if line.lowercased().contains("error") { onLog(line) }
            })
            if let cap = planned.trimmedTo {
                onLog("\(planned.preset.label): trimmed to \(Int(cap))s (platform cap)")
            }
            outputs.append(destination)
        }
        return outputs
    }

    /// The crossfaded join: every piece is its own input, chained through
    /// xfade/acrossfade with each transition starting `crossfade` before the
    /// end of everything assembled so far — then the overlays and music go on
    /// the faded result. Static so the index bookkeeping is testable.
    static func clipEditCrossfadeCommand(pieceURLs: [URL], pieceDurations: [Double],
                                         overlays: [TimedOverlay],
                                         videoOverlays: [VideoOverlay] = [],
                                         voiceover: VoiceoverInput? = nil,
                                         sfx: [SFXInput] = [],
                                         musicURL: URL?,
                                         musicGainDB: Double, crossfade: Double,
                                         transition: String = "fade",
                                         renderWidth: Int = ASSBuilder.renderWidth,
                                         renderHeight: Int = ASSBuilder.renderHeight,
                                         settings: ExportSettings, encoderName: String,
                                         destination: URL) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-progress", "pipe:1"]
        for url in pieceURLs { arguments += ["-i", url.path] }
        var nextInput = pieceURLs.count
        let overlayBase = nextInput
        for overlay in overlays {
            nextInput += 1
            arguments += ["-i", overlay.url.path]
        }
        let videoOverlayIndices = appendVideoOverlayInputs(videoOverlays, arguments: &arguments,
                                                           nextInput: &nextInput)
        var musicIndex: Int?
        if let musicURL {
            musicIndex = nextInput
            nextInput += 1
            arguments += ["-stream_loop", "-1", "-i", musicURL.path]
        }
        var voiceoverIndex: Int?
        if let voiceover {
            voiceoverIndex = nextInput
            nextInput += 1
            arguments += ["-i", voiceover.url.path]
        }
        var sfxIndices: [Int] = []
        for event in sfx {
            sfxIndices.append(nextInput)
            nextInput += 1
            arguments += ["-i", event.url.path]
        }

        var filters: [String] = []
        var videoLabel = "0:v"
        var audioLabel = "0:a"
        var accumulated = pieceDurations.first ?? 0
        for index in 1..<pieceURLs.count {
            let offset = max(0, accumulated - crossfade)
            filters.append("[\(videoLabel)][\(index):v]xfade=transition=\(transition):duration=\(String(format: "%.3f", crossfade)):offset=\(String(format: "%.3f", offset))[vx\(index)]")
            filters.append("[\(audioLabel)][\(index):a]acrossfade=d=\(String(format: "%.3f", crossfade)):c1=tri:c2=tri[ax\(index)]")
            videoLabel = "vx\(index)"
            audioLabel = "ax\(index)"
            accumulated += (pieceDurations.indices.contains(index) ? pieceDurations[index] : 0) - crossfade
        }

        overlayChain(overlays, firstInput: overlayBase, videoLabel: &videoLabel, filters: &filters)
        videoOverlayChain(videoOverlays, indices: videoOverlayIndices,
                          renderWidth: renderWidth, renderHeight: renderHeight,
                          videoLabel: &videoLabel, filters: &filters)
        audioLabel = audioMixChain(baseLabel: audioLabel,
                                   musicIndex: musicIndex, musicGainDB: musicGainDB,
                                   videoOverlays: videoOverlays, overlayIndices: videoOverlayIndices,
                                   voiceoverIndex: voiceoverIndex, voiceover: voiceover,
                                   sfxIndices: sfxIndices, sfx: sfx,
                                   filters: &filters)

        arguments += ["-filter_complex", filters.joined(separator: ";"),
                      "-map", "[\(videoLabel)]", "-map", "[\(audioLabel)]",
                      "-c:v", encoderName]
        if settings.useHardwareEncoder {
            let bitrate = Int(settings.videoBitrateMbps * 1000)
            arguments += ["-b:v", "\(bitrate)k",
                          "-maxrate", "\(Int(Double(bitrate) * 1.25))k",
                          "-bufsize", "\(bitrate * 2)k",
                          "-profile:v", "high"]
        } else {
            arguments += ["-crf", "19", "-preset", "medium"]
        }
        arguments += ["-pix_fmt", "yuv420p",
                      "-c:a", "aac", "-b:a", "\(settings.audioBitrateKbps)k", "-ar", "48000", "-ac", "2"]
        if musicURL != nil { arguments += ["-shortest"] }
        arguments += ["-movflags", "+faststart", "-y", destination.path]
        return arguments
    }

    /// The final pass: overlay and music, or a plain stream copy when there's
    /// neither. Static so the input-index bookkeeping is testable — mapping the
    /// wrong stream is silent.
    static func clipEditJoinCommand(listURL: URL, overlays: [TimedOverlay],
                                    videoOverlays: [VideoOverlay] = [],
                                    voiceover: VoiceoverInput? = nil,
                                    sfx: [SFXInput] = [],
                                    musicURL: URL?,
                                    musicGainDB: Double,
                                    renderWidth: Int = ASSBuilder.renderWidth,
                                    renderHeight: Int = ASSBuilder.renderHeight,
                                    settings: ExportSettings,
                                    encoderName: String, destination: URL) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-progress", "pipe:1",
                         "-f", "concat", "-safe", "0", "-i", listURL.path]

        guard !overlays.isEmpty || !videoOverlays.isEmpty || voiceover != nil
                || !sfx.isEmpty || musicURL != nil else {
            arguments += ["-c", "copy", "-movflags", "+faststart", "-y", destination.path]
            return arguments
        }

        var nextInput = 1
        let overlayBase = nextInput
        for overlay in overlays {
            nextInput += 1
            arguments += ["-i", overlay.url.path]
        }
        let videoOverlayIndices = appendVideoOverlayInputs(videoOverlays, arguments: &arguments,
                                                           nextInput: &nextInput)
        var musicIndex: Int?
        if let musicURL {
            musicIndex = nextInput
            nextInput += 1
            arguments += ["-stream_loop", "-1", "-i", musicURL.path]
        }
        var voiceoverIndex: Int?
        if let voiceover {
            voiceoverIndex = nextInput
            nextInput += 1
            arguments += ["-i", voiceover.url.path]
        }
        var sfxIndices: [Int] = []
        for event in sfx {
            sfxIndices.append(nextInput)
            nextInput += 1
            arguments += ["-i", event.url.path]
        }

        var filters: [String] = []
        var videoLabel = "0:v"
        if overlays.isEmpty && videoOverlays.isEmpty {
            filters.append("[0:v]null[vovbase]")
            videoLabel = "vovbase"
        } else {
            overlayChain(overlays, firstInput: overlayBase, videoLabel: &videoLabel, filters: &filters)
            videoOverlayChain(videoOverlays, indices: videoOverlayIndices,
                              renderWidth: renderWidth, renderHeight: renderHeight,
                              videoLabel: &videoLabel, filters: &filters)
        }

        let audioLabel = audioMixChain(baseLabel: "0:a",
                                       musicIndex: musicIndex, musicGainDB: musicGainDB,
                                       videoOverlays: videoOverlays, overlayIndices: videoOverlayIndices,
                                       voiceoverIndex: voiceoverIndex, voiceover: voiceover,
                                       sfxIndices: sfxIndices, sfx: sfx,
                                       filters: &filters)

        arguments += ["-filter_complex", filters.joined(separator: ";"),
                      "-map", "[\(videoLabel)]", "-map", "[\(audioLabel)]",
                      "-c:v", encoderName]
        if settings.useHardwareEncoder {
            let bitrate = Int(settings.videoBitrateMbps * 1000)
            arguments += ["-b:v", "\(bitrate)k",
                          "-maxrate", "\(Int(Double(bitrate) * 1.25))k",
                          "-bufsize", "\(bitrate * 2)k",
                          "-profile:v", "high"]
        } else {
            arguments += ["-crf", "19", "-preset", "medium"]
        }
        arguments += ["-pix_fmt", "yuv420p",
                      "-c:a", "aac", "-b:a", "\(settings.audioBitrateKbps)k", "-ar", "48000", "-ac", "2"]
        if musicURL != nil { arguments += ["-shortest"] }
        arguments += ["-movflags", "+faststart", "-y", destination.path]
        return arguments
    }

    /// Builds the join command.
    ///
    /// Without crossfades, music or captions this is a plain concat-demuxer
    /// stream copy — no re-encode at all. Any of those three forces one filter
    /// graph over the pieces instead.
    func joinCommand(pieceURLs: [URL],
                     pieceDurations: [Double],
                     listURL: URL,
                     assURL: URL?,
                     softSubtitleURL: URL? = nil,
                     tuning: AudioTuning = .standard,
                     duckKeyURL: URL? = nil,
                     loudness: LoudnessMeasurement? = nil,
                     options: LongFormOptions,
                     settings: ExportSettings,
                     encoderName: String,
                     destination: URL) -> [String] {
        let crossfade = options.crossfadeEnabled && pieceURLs.count > 1 && options.crossfadeDuration > 0
        let musicURL = options.musicEnabled ? options.musicURL : nil
        let tunes = tuning.isActive
        let needsFilter = crossfade || musicURL != nil || assURL != nil || tunes

        var arguments = ["-hide_banner", "-nostdin", "-progress", "pipe:1"]

        guard needsFilter else {
            arguments += ["-f", "concat", "-safe", "0", "-i", listURL.path]
            if let softSubtitleURL {
                arguments += ["-i", softSubtitleURL.path,
                              "-map", "0", "-map", "1:0",
                              "-c", "copy", "-c:s", "mov_text"]
            } else {
                arguments += ["-c", "copy"]
            }
            arguments += ["-movflags", "+faststart", "-y", destination.path]
            return arguments
        }

        if crossfade {
            for url in pieceURLs { arguments += ["-i", url.path] }
        } else {
            arguments += ["-f", "concat", "-safe", "0", "-i", listURL.path]
        }
        // Input indices are bookkeeping, and getting them wrong maps the wrong
        // stream silently — so they're counted rather than derived.
        var nextInput = crossfade ? pieceURLs.count : 1
        var musicIndex: Int?
        if let musicURL {
            musicIndex = nextInput
            nextInput += 1
            // Looped so a short track still covers a 27-minute cut.
            arguments += ["-stream_loop", "-1", "-i", musicURL.path]
        }
        var subtitleIndex: Int?
        if let softSubtitleURL {
            subtitleIndex = nextInput
            nextInput += 1
            arguments += ["-i", softSubtitleURL.path]
        }
        var keyIndex: Int?
        if tunes, tuning.needsSpeechKey, let duckKeyURL {
            keyIndex = nextInput
            nextInput += 1
            arguments += ["-i", duckKeyURL.path]
        }

        var filters: [String] = []
        var videoLabel: String
        var audioLabel: String

        if crossfade {
            let fade = options.crossfadeDuration
            var previousVideo = "0:v"
            var previousAudio = "0:a"
            // Each transition starts `fade` before the end of everything
            // assembled so far, and every join shortens the result by `fade`.
            var accumulated = pieceDurations.first ?? 0

            for index in 1..<pieceURLs.count {
                let offset = max(0, accumulated - fade)
                filters.append("[\(previousVideo)][\(index):v]xfade=transition=fade:duration=\(format(fade)):offset=\(format(offset))[vx\(index)]")
                filters.append("[\(previousAudio)][\(index):a]acrossfade=d=\(format(fade)):c1=tri:c2=tri[ax\(index)]")
                previousVideo = "vx\(index)"
                previousAudio = "ax\(index)"
                accumulated += (pieceDurations.indices.contains(index) ? pieceDurations[index] : 0) - fade
            }
            videoLabel = previousVideo
            audioLabel = previousAudio
        } else {
            // Normalise raw stream refs into filter labels so mapping is uniform.
            filters.append("[0:v]null[v0]")
            filters.append("[0:a]anull[a0]")
            videoLabel = "v0"
            audioLabel = "a0"
        }

        if let assURL {
            filters.append("[\(videoLabel)]ass=\(escapeFilterPath(assURL.path))[vcap]")
            videoLabel = "vcap"
        }

        // Tuning happens before the bed is laid in: the duck envelope describes
        // where speech is in the programme, and the bed has its own ducking.
        if tunes {
            filters += AudioTuner.filters(input: audioLabel,
                                          key: keyIndex.map { "\($0):a" },
                                          tuning: tuning, output: "atuned",
                                          loudness: loudness)
            audioLabel = "atuned"
        }

        if let musicIndex {
            let gain = pow(10, options.musicGainDB / 20)
            filters.append("[\(musicIndex):a]volume=\(format(gain))[mus]")
            if options.musicDucking {
                // Speech keys the compressor, so the bed drops whenever anyone
                // talks and comes back up in the gaps.
                filters.append("[\(audioLabel)]asplit=2[aprog][akey]")
                filters.append("[mus][akey]sidechaincompress=threshold=0.03:ratio=\(format(options.duckRatio)):attack=20:release=400[aduck]")
                filters.append("[aprog][aduck]amix=inputs=2:duration=first:normalize=0[amixed]")
            } else {
                filters.append("[\(audioLabel)][mus]amix=inputs=2:duration=first:normalize=0[amixed]")
            }
            audioLabel = "amixed"
        }

        arguments += ["-filter_complex", filters.joined(separator: ";")]
        arguments += ["-map", "[\(videoLabel)]", "-map", "[\(audioLabel)]"]
        if let subtitleIndex {
            arguments += ["-map", "\(subtitleIndex):0", "-c:s", "mov_text"]
        }
        arguments += ["-c:v", encoderName]
        arguments += encoderArguments(settings)
        arguments += [
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "\(settings.audioBitrateKbps)k", "-ar", "48000", "-ac", "2",
        ]
        if musicURL != nil { arguments += ["-shortest"] }
        arguments += ["-movflags", "+faststart", "-y", destination.path]
        return arguments
    }

    /// Expected runtime after crossfades shorten every join.
    static func expectedDuration(pieceDurations: [Double], options: LongFormOptions) -> Double {
        let raw = pieceDurations.reduce(0, +)
        guard options.crossfadeEnabled, pieceDurations.count > 1, options.crossfadeDuration > 0 else {
            return raw
        }
        return raw - Double(pieceDurations.count - 1) * options.crossfadeDuration
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func encoderArguments(_ settings: ExportSettings) -> [String] {
        Self.encoderArguments(settings, mbps: settings.videoBitrateMbps)
    }

    /// Shared so the intermediate and final passes can't drift apart in
    /// anything but bitrate.
    static func encoderArguments(_ settings: ExportSettings, mbps: Double) -> [String] {
        guard settings.useHardwareEncoder else {
            // x264's quality ladder is a CRF, not a bitrate: 16 for the
            // headroom-rich intermediate, 19 for delivery.
            return ["-crf", mbps > settings.videoBitrateMbps ? "16" : "19", "-preset", "medium"]
        }
        // Rounded, not truncated: 24 × 2.4 in binary floating point is
        // 57.599…, which would otherwise print as 57599k.
        let bitrate = Int((mbps * 1000).rounded())
        return [
            "-b:v", "\(bitrate)k",
            "-maxrate", "\(Int(Double(bitrate) * 1.25))k",
            "-bufsize", "\(bitrate * 2)k",
            "-profile:v", "high",
        ]
    }

    /// Filter arguments treat `:` and `\` specially, and the ASS path is
    /// embedded directly in the filter graph.
    private func escapeFilterPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
