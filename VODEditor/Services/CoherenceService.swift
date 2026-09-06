import Foundation

enum CoherenceError: LocalizedError {
    case transcriptEmpty
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .transcriptEmpty:
            return "This project has no transcript yet."
        case .malformed(let detail):
            return "Could not read the pasted reply: \(detail)"
        }
    }
}

/// Shared plumbing for the manual Claude loop: a copied prompt asks for a
/// fenced JSON reply, and the pasted answer comes back through here. Chat
/// replies wrap JSON in fences and prose, so extraction is tolerant: it takes
/// everything between the first brace and the last.
enum ManualReply {
    static func extractJSON(from reply: String) throws -> Data {
        guard let first = reply.firstIndex(of: "{"),
              let last = reply.lastIndex(of: "}"), first < last else {
            throw CoherenceError.malformed("No JSON object in the pasted text — paste Claude's whole reply")
        }
        return Data(String(reply[first...last]).utf8)
    }
}

/// The throughlines pass, manual edition: one copied prompt over the whole
/// transcript, one pasted reply. (This was a live API call before the manual
/// route replaced every metered feature.)
enum CoherenceService {
    static let rules = """
    You analyse transcripts of long Twitch livestreams to find throughlines: \
    sets of moments spread across the stream that belong together and would \
    read as incoherent if an editor kept one without the others.

    A throughline is one of:
    - running_bit: a joke, catchphrase, or gag that recurs and escalates
    - story: a multi-part anecdote told across separate stretches
    - arc: a goal, feud, or situation set up early and paid off later

    Rules:
    - Only report throughlines whose beats are genuinely separated in time. \
    Two adjacent lines about the same subject are not a throughline.
    - Every beat must be anchored to timestamps that appear in the transcript.
    - Prefer a handful of strong throughlines over many weak ones. If the \
    stream has none, return an empty list — that is a valid answer.
    - `strength` is your confidence that an editor keeping only one beat would \
    produce a worse cut: 1.0 means the beats are meaningless apart, 0.3 means \
    they are merely related.
    - Transcription is automatic and imperfect. Slang, names, and game terms \
    may be misheard; judge intent rather than literal wording.
    """

    static func manualPrompt(transcript: Transcript, vocabulary: String) -> String {
        var prompt = rules
        prompt += """
        \n
        Reply with ONLY a JSON code block in exactly this shape, nothing else:

        ```json
        {"throughlines": [{"title": "...", "summary": "...", "kind": "running_bit", \
        "strength": 0.8, "beats": [{"start_seconds": 120, "end_seconds": 180, "why": "..."}]}]}
        ```
        """
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            prompt += "\n\nNames and terms that may be mistranscribed: \(vocab)"
        }
        prompt += "\n\nThe transcript ([seconds] text):\n\n" + render(transcript)
        return prompt
    }

    /// Whole seconds are enough for the model to anchor beats, and cost far
    /// fewer characters than millisecond precision over 6,000+ lines.
    static func render(_ transcript: Transcript) -> String {
        var output = String()
        output.reserveCapacity(transcript.segments.count * 48)
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            output += "[\(Int(segment.start))] \(text)\n"
        }
        return output
    }

    // MARK: - Reply

    private struct Payload: Decodable {
        struct Beat: Decodable {
            let start_seconds: Double
            let end_seconds: Double
            let why: String
        }
        struct Item: Decodable {
            let title: String
            let summary: String
            let kind: String
            let strength: Double
            let beats: [Beat]
        }
        let throughlines: [Item]
    }

    // MARK: - Local model path

    /// The 8B can't hold a four-hour transcript, so local throughlines run in
    /// two stages: each ~10-minute chunk reports its notable bits, then one
    /// merge pass over all the reported bits assembles the throughlines. The
    /// merge sees labels and timestamps, not raw transcript — small enough to
    /// fit, and exactly the information a throughline is made of.
    static let stageOneSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "bits": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "label": ["type": "string"],
                        "kind": ["type": "string", "enum": ["running_bit", "story", "arc"]],
                        "start_seconds": ["type": "number"],
                        "end_seconds": ["type": "number"],
                        "why": ["type": "string"],
                    ],
                    "required": ["label", "kind", "start_seconds", "end_seconds", "why"],
                ],
            ],
        ],
        "required": ["bits"],
    ]

    static let stageTwoSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "throughlines": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "summary": ["type": "string"],
                        "kind": ["type": "string", "enum": ["running_bit", "story", "arc"]],
                        "strength": ["type": "number"],
                        "beats": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "start_seconds": ["type": "number"],
                                    "end_seconds": ["type": "number"],
                                    "why": ["type": "string"],
                                ],
                                "required": ["start_seconds", "end_seconds", "why"],
                            ],
                        ],
                    ],
                    "required": ["title", "summary", "kind", "strength", "beats"],
                ],
            ],
        ],
        "required": ["throughlines"],
    ]

    struct Bit: Codable, Equatable {
        var label: String
        var kind: String
        var start_seconds: Double
        var end_seconds: Double
        var why: String
    }

    static func stageOneSystem() -> String {
        """
        You read one window of a long Twitch stream transcript and report the \
        notable bits in it: a joke or gag that could recur, a personal story \
        being told, a goal or feud being set up or paid off. Give each a short \
        reusable label (the same bit should get the same label if seen again), \
        anchor it to timestamps from the transcript, and say why it's notable. \
        Report only genuinely notable moments — an empty list is a valid answer.
        """
    }

    static func stageOneUser(chunk: AutoClipChunk, transcript: Transcript,
                             vocabulary: String) -> String {
        var prompt = String(format: "Window %.0fs to %.0fs.", chunk.start, chunk.end)
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty { prompt += "\nNames and terms: \(vocab)" }
        prompt += "\n\nTranscript ([seconds] text):\n"
        for segment in transcript.segments
        where segment.end > chunk.start && segment.start < chunk.end {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            prompt += "[\(Int(segment.start))] \(text)\n"
        }
        return prompt
    }

    static func parseBits(_ reply: String, chunk: AutoClipChunk) throws -> [Bit] {
        struct Payload: Decodable { let bits: [Bit] }
        let data = try ManualReply.extractJSON(from: reply)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.bits.filter {
            $0.end_seconds > $0.start_seconds
                && $0.start_seconds >= chunk.start - 5 && $0.end_seconds <= chunk.end + 5
        }
    }

    static func stageTwoSystem() -> String {
        rules + """
        \n
        You are given bits extracted from every window of the stream, with \
        labels and timestamps. Assemble the throughlines: group bits that are \
        the same running gag, the same multi-part story, or the same arc — \
        matching on meaning, since labels from different windows vary. A \
        throughline needs beats genuinely separated in time; drop singletons.
        """
    }

    static func stageTwoUser(bits: [Bit]) -> String {
        var prompt = "The bits found across the stream, in order:\n"
        for bit in bits.sorted(by: { $0.start_seconds < $1.start_seconds }) {
            prompt += String(format: "[%.0f–%.0fs] %@ (%@): %@\n",
                             bit.start_seconds, bit.end_seconds, bit.label, bit.kind, bit.why)
        }
        return prompt
    }

    static func parseReply(_ reply: String) throws -> [Throughline] {
        let data = try ManualReply.extractJSON(from: reply)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CoherenceError.malformed("Shape mismatch: \(error.localizedDescription)")
        }
        return payload.throughlines.compactMap { item in
            let beats = item.beats
                .filter { $0.end_seconds > $0.start_seconds }
                .map { Throughline.Beat(start: $0.start_seconds, end: $0.end_seconds, why: $0.why) }
                .sorted { $0.start < $1.start }
            // A single beat isn't a throughline — nothing would be lost by
            // keeping it alone.
            guard beats.count >= 2 else { return nil }
            return Throughline(
                title: item.title,
                summary: item.summary,
                kind: Throughline.Kind(rawValue: item.kind) ?? .arc,
                strength: min(1, max(0, item.strength)),
                beats: beats
            )
        }
    }
}
