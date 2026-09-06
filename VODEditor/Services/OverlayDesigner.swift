import Foundation

/// Thumbnail overlay art as SVG — manual edition.
///
/// Claude doesn't generate images, but it does draw — and vector art is exactly
/// what a thumbnail overlay wants: badges, arrows, bursts, banners, outlines.
/// The copied prompt asks for a bare SVG document; the pasted reply is
/// sanitized and rasterized locally through AppKit, so nothing executes and
/// nothing reaches off the machine.
enum OverlayDesigner {
    static let rules = """
    You draw overlay graphics for YouTube thumbnails, as SVG.

    The SVG is composited on top of a still from a gaming stream, so:
    - The background must be transparent. Never draw a background rectangle \
    covering the canvas.
    - It has to read at 120 pixels wide. Bold shapes, heavy strokes, high \
    contrast. No thin lines, no fine detail, no small text.
    - Use a `viewBox` and no fixed width/height, so it scales.
    - Give shapes a dark outline or drop shadow, or they vanish against dark \
    footage.
    - Keep it to a few dozen elements. This is a badge or a flourish, not an \
    illustration.
    - No `<image>`, no external references, no scripts, no embedded fonts — it \
    is rendered offline. If you want text, use `<text>` with a common system \
    family and a heavy weight.

    Reply with ONLY the SVG document — no fences needed, no commentary.
    """

    static func manualPrompt(brief: String, context: String) -> String {
        var prompt = rules + "\n\nDraw this overlay: \(brief)"
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            prompt += "\n\nIt sits on a thumbnail for: \(trimmed)"
        }
        return prompt
    }

    /// The pasted reply, fences and prose tolerated, sanitized to plain SVG.
    static func parseReply(_ reply: String) throws -> String {
        try sanitize(reply)
    }

    /// The SVG is rendered locally by AppKit, so anything that could reach off
    /// the machine or execute is stripped rather than trusted.
    static func sanitize(_ raw: String) throws -> String {
        var svg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chat replies often wrap the document in a fence despite being asked
        // not to.
        if svg.hasPrefix("```") {
            svg = svg.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = svg.range(of: "```", options: .backwards) {
                svg = String(svg[..<fence.lowerBound])
            }
            svg = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = svg.range(of: "<svg") else {
            throw CoherenceError.malformed("The pasted text contained no SVG")
        }
        svg = String(svg[start.lowerBound...])
        if let end = svg.range(of: "</svg>", options: .backwards) {
            svg = String(svg[..<end.upperBound])
        }

        let forbidden = ["<script", "<foreignObject", "<image", "xlink:href", "href=\"http",
                         "href='http", "<use", "javascript:", "<iframe", "@import"]
        for token in forbidden where svg.lowercased().contains(token.lowercased()) {
            throw CoherenceError.malformed("SVG contained a disallowed element (\(token))")
        }
        return svg
    }
}
