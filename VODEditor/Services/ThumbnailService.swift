import Foundation

enum ThumbnailError: LocalizedError {
    case noBackground
    case noText
    case textUnsupported

    var errorDescription: String? {
        switch self {
        case .noBackground:
            return "Pick a frame from the stream, or generate an image, before exporting."
        case .noText:
            return "Add some thumbnail text, or export the frame on its own."
        case .textUnsupported:
            return "This ffmpeg has no `ass` filter, so text can't be drawn onto the frame. Install the full build with: brew install ffmpeg-full"
        }
    }
}

/// Pulls stills out of the VOD and burns thumbnail text onto them.
///
/// Text goes through libass rather than `drawtext` so it renders through the
/// same path the burned-in captions do — same font resolution, same outline
/// maths, same escaping. The alternative would be a second text renderer whose
/// output only looks like the first one.
enum ThumbnailService {
    /// One JPEG per timestamp, scaled to thumbnail size.
    ///
    /// Seeking before the input rather than after keeps each extraction to a
    /// keyframe hop instead of a decode from the start of a four-hour file.
    static func extractFrames(source: URL,
                              times: [Double],
                              width: Int = ThumbnailDraft.horizontalSize.width,
                              height: Int = ThumbnailDraft.horizontalSize.height,
                              into directory: URL,
                              onProgress: @escaping (Double) -> Void = { _ in }) async throws -> [URL] {
        let ffmpeg = try FFmpegService()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Milliseconds, not seconds: dense sampling puts several candidates
        // inside the same second, and an integer-second name silently
        // overwrote all but the last of them.
        func destination(for time: Double) -> URL {
            directory.appendingPathComponent(
                String(format: "frame_%09d.jpg", Int((max(0, time) * 1000).rounded())))
        }

        func extract(at time: Double) async throws -> URL {
            let url = destination(for: time)
            var arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.3f", max(0, time)),
            ]
            arguments += HLSSource.inputArguments(for: source)
            arguments += [
                "-frames:v", "1",
                "-vf", "scale=\(width):\(height):force_original_aspect_ratio=increase,"
                     + "crop=\(width):\(height)",
                "-q:v", "2",
                "-y", url.path,
            ]
            try await Shell.runChecked(ffmpeg.ffmpeg, arguments: arguments)
            return url
        }

        // A few at a time. Each extraction is a keyframe seek plus one decode,
        // so they are independent; running them strictly serially made dense
        // sampling (dozens of frames per moment) unusably slow. Bounded
        // because an unbounded group would spawn one ffmpeg per frame.
        let lanes = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        var urls = [URL?](repeating: nil, count: times.count)
        var completed = 0
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var next = 0
            func submit() {
                guard next < times.count else { return }
                let index = next
                let time = times[index]
                next += 1
                group.addTask { (index, try await extract(at: time)) }
            }
            for _ in 0..<min(lanes, times.count) { submit() }
            while let (index, url) = try await group.next() {
                urls[index] = url
                completed += 1
                onProgress(Double(completed) / Double(max(1, times.count)))
                submit()
            }
        }
        return urls.compactMap { $0 }
    }

    /// A frame the ranker looked at, with the measurement that placed it.
    struct RankedFrame: Identifiable, Equatable {
        var id: String { url.path }
        var time: Double
        var url: URL
        var quality: FrameQuality
    }

    /// The best frames *around* a set of interesting moments.
    ///
    /// The moment finder says when something happened; it says nothing about
    /// whether the single frame sitting on that second is worth looking at.
    /// The funniest second of a stream is regularly a motion-blurred shot of
    /// the back of someone's head. So sample a spread around each moment and
    /// let `FrameQuality` pick.
    static func bestFrames(source: URL,
                           around moments: [Double],
                           spread: Double = 1.2,
                           samplesPerMoment: Int = 5,
                           keeping keep: Int = 12,
                           into directory: URL,
                           onProgress: @escaping (Double) -> Void = { _ in })
        async throws -> [RankedFrame] {
        guard !moments.isEmpty, samplesPerMoment > 0 else { return [] }

        let times = FrameSampling.times(around: moments, spread: spread,
                                        samplesPerMoment: samplesPerMoment)
        guard !times.isEmpty else { return [] }

        let urls = try await extractFrames(source: source, times: times,
                                           into: directory, onProgress: onProgress)

        // Scoring is CPU-bound and independent per frame.
        let scored: [RankedFrame] = await withTaskGroup(of: RankedFrame?.self) { group in
            for (index, url) in urls.enumerated() {
                let time = index < times.count ? times[index] : 0
                group.addTask {
                    guard let quality = FrameQualityScorer.score(imageAt: url) else { return nil }
                    return RankedFrame(time: time, url: url, quality: quality)
                }
            }
            var out: [RankedFrame] = []
            for await frame in group { if let frame { out.append(frame) } }
            return out
        }

        return Array(scored.sorted { $0.quality.overall > $1.quality.overall }.prefix(keep))
    }

    /// Renders the draft onto a background at the given size.
    static func render(draft: ThumbnailDraft,
                       background: URL,
                       width: Int,
                       height: Int,
                       cropToFill: Bool,
                       workingDirectory: URL,
                       destination: URL) async throws {
        let ffmpeg = try FFmpegService()
        let text = draft.style.uppercase ? draft.text.uppercased() : draft.text
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasText, !(await ToolLocator.ffmpegFilters()).contains("ass") {
            throw ThumbnailError.textUnsupported
        }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        var chain: [String] = []
        if cropToFill {
            chain.append("scale=\(width):\(height):force_original_aspect_ratio=increase")
            chain.append("crop=\(width):\(height):(iw-\(width))/2:(ih-\(height))/2")
        } else {
            chain.append("scale=\(width):\(height)")
        }
        chain.append("setsar=1")

        // Layers first, text last: whatever you stack on the frame, the words
        // stay on top and legible.
        let layers = draft.layers.filter { $0.isVisible && FileManager.default.fileExists(atPath: $0.path) }
        let assURL = workingDirectory.appendingPathComponent("thumbnail-\(width)x\(height).ass")
        if hasText {
            try assFile(text: text, style: draft.style, width: width, height: height)
                .write(to: assURL, atomically: true, encoding: .utf8)
        }

        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", background.path]

        guard !layers.isEmpty else {
            if hasText { chain.append("ass=\(escapeFilterPath(assURL.path))") }
            arguments += ["-vf", chain.joined(separator: ","),
                          "-frames:v", "1", "-q:v", "2", "-y", destination.path]
            try await Shell.runChecked(ffmpeg.ffmpeg, arguments: arguments)
            return
        }

        // Each layer is rasterised to PNG first. ffmpeg can't read SVG, and
        // AppKit renders it with the alpha intact — which is the whole point of
        // an overlay.
        var overlayFiles: [URL] = []
        for (index, layer) in layers.enumerated() {
            let png = workingDirectory
                .appendingPathComponent("layer-\(width)x\(height)-\(index).png")
            try LayerRasterizer.rasterize(layer.url, to: png,
                                          targetWidth: Int(Double(width) * layer.width))
            overlayFiles.append(png)
            arguments += ["-i", png.path]
        }

        var statements = ["[0:v]\(chain.joined(separator: ","))[base0]"]
        for (index, layer) in layers.enumerated() {
            var prepared = "scale=\(Int(Double(width) * layer.width)):-1"
            if layer.flipped { prepared += ",hflip" }
            if layer.opacity < 1 {
                prepared += ",format=rgba,colorchannelmixer=aa=\(String(format: "%.3f", layer.opacity))"
            }
            statements.append("[\(index + 1):v]\(prepared)[lay\(index)]")
            // Positioned by its centre, so a layer keeps its place when resized.
            let x = "\(Int(Double(width) * layer.centerX))-overlay_w/2"
            let y = "\(Int(Double(height) * layer.centerY))-overlay_h/2"
            statements.append("[base\(index)][lay\(index)]overlay=\(x):\(y)[base\(index + 1)]")
        }

        var output = "base\(layers.count)"
        if hasText {
            statements.append("[\(output)]ass=\(escapeFilterPath(assURL.path))[out]")
            output = "out"
        }

        arguments += ["-filter_complex", statements.joined(separator: ";"),
                      "-map", "[\(output)]",
                      "-frames:v", "1", "-q:v", "2", "-y", destination.path]
        try await Shell.runChecked(ffmpeg.ffmpeg, arguments: arguments)
        for url in overlayFiles { try? FileManager.default.removeItem(at: url) }
    }

    /// A one-event ASS file covering the whole (nonexistent) timeline of a still.
    static func assFile(text: String, style: ThumbnailTextStyle,
                        width: Int, height: Int) -> String {
        // The style is authored against 1280×720; scaling keeps a thumbnail and
        // its vertical cover looking like the same design.
        //
        // Type scales with *width*, not height. A 1080×1920 cover is taller but
        // narrower, and scaling by height made the font 2.7× larger inside a
        // frame 200 pixels narrower — the text ran straight off the right edge.
        // Margins scale on their own axis, so the bottom margin still clears
        // the platform's overlay on a vertical cover.
        let scale = Double(width) / Double(ThumbnailDraft.horizontalSize.width)
        let verticalScale = Double(height) / Double(ThumbnailDraft.horizontalSize.height)
        let borderStyle = style.useBox ? 3 : 1
        let back = style.useBox ? style.boxColor : CaptionColor(red: 0, green: 0, blue: 0, alpha: 0.5)

        let fields: [String] = [
            "Thumb",
            style.fontName,
            String(Int((Double(style.fontSize) * scale).rounded())),
            style.fill.assValue,
            style.fill.assValue,
            style.outline.assValue,
            back.assValue,
            "0", "0", "0", "0",
            "100", "100", "0", "0",
            String(borderStyle),
            String(format: "%.1f", style.outlineWidth * scale),
            String(format: "%.1f", style.shadow * scale),
            String(style.position.assAlignment),
            String(Int((Double(style.marginHorizontal) * scale).rounded())),
            String(Int((Double(style.marginHorizontal) * scale).rounded())),
            String(Int((Double(style.marginVertical) * verticalScale).rounded())),
            "1",
        ]

        let rows = wrap(text, limit: style.maxCharactersPerLine)
            .map(escape)
            .joined(separator: "\\N")

        return """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 2
        ScaledBorderAndShadow: yes
        YCbCr Matrix: TV.709

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: \(fields.joined(separator: ","))

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:10.00,Thumb,,0,0,0,,\(rows)

        """
    }

    /// Greedy wrap on words, with a long single word left to overflow rather
    /// than broken mid-syllable.
    static func wrap(_ text: String, limit: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard limit > 0, words.count > 1 else { return words.isEmpty ? [] : [text] }

        var rows: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > limit, !current.isEmpty {
                rows.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\u{200B}")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func escapeFilterPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}
