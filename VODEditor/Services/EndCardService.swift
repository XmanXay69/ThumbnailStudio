import Foundation

/// Series bookends from the client profile: an end card composed as a
/// ThumbDocument (so the Thumbnail Studio renderer draws it — one renderer,
/// no drift) and baked once into a video piece the timeline treats like any
/// other clip. Trim it, move it, delete it; export needs no special case.
enum EndCardService {
    /// The end-card layout, pure and testable: brand-dark background, the
    /// client's handles, the sign-off line, logo when there is one.
    static func document(for client: ClientProfile, aspect: EditAspect) -> ThumbDocument {
        var doc = ThumbDocument()
        doc.width = aspect.width
        doc.height = aspect.height

        var background = ShapeSpec(shape: "rectangle")
        background.fillHex = "101016"
        doc.layers.append(ThumbLayer(kind: .shape(background),
                                     x: 0.5, y: 0.5,
                                     widthFraction: 1.4, heightFraction: 1.4))

        var accent = ShapeSpec(shape: "rectangle")
        accent.fillHex = client.brandColorHex
        doc.layers.append(ThumbLayer(kind: .shape(accent),
                                     x: 0.5, y: aspect == .portrait ? 0.315 : 0.27,
                                     widthFraction: 0.26, heightFraction: 0.008))

        var prompt = TextSpec(text: client.subscribePrompt.isEmpty
                              ? "LIKE & SUBSCRIBE" : client.subscribePrompt)
        prompt.sizeFraction = 0.085
        prompt.fillHex = "FFFFFF"
        prompt.gradientHex = client.brandColorHex
        prompt.strokeWidth = 0
        prompt.shadowEnabled = true
        doc.layers.append(ThumbLayer(kind: .text(prompt),
                                     x: 0.5, y: 0.38, widthFraction: 0.86))

        var handles: [String] = []
        if !client.twitchHandle.isEmpty { handles.append("twitch.tv/\(client.twitchHandle)") }
        if !client.instagramHandle.isEmpty { handles.append("@\(client.instagramHandle)") }
        if !handles.isEmpty {
            var handleText = TextSpec(text: handles.joined(separator: "   ·   "))
            handleText.sizeFraction = 0.038
            handleText.fillHex = "D7DAE1"
            handleText.strokeWidth = 0
            doc.layers.append(ThumbLayer(kind: .text(handleText),
                                         x: 0.5, y: 0.52, widthFraction: 0.9))
        }

        if let logo = client.logoPath, FileManager.default.fileExists(atPath: logo) {
            doc.layers.append(ThumbLayer(kind: .image(ImageSpec(path: logo)),
                                         x: 0.5, y: 0.72, widthFraction: 0.14))
        }
        return doc
    }

    /// The ffmpeg arguments that loop the rendered card PNG into a silent
    /// video piece of the right length. Encoded like any intermediate.
    static func bakeArguments(cardPNG: URL, seconds: Double, width: Int, height: Int,
                              destination: URL) -> [String] {
        ["-hide_banner", "-nostdin",
         "-loop", "1", "-i", cardPNG.path,
         "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
         "-t", String(format: "%.2f", min(15, max(2, seconds))),
         "-map", "0:v", "-map", "1:a",
         "-vf", "scale=\(width):\(height),setsar=1,format=yuv420p,fade=t=in:d=0.4",
         "-c:v", "libx264", "-preset", "fast", "-crf", "18",
         "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
         "-r", "60",
         "-y", destination.path]
    }
}
