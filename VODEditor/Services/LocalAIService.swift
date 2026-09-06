import Foundation

/// The copy-paste flows, run locally instead.
///
/// The 8B already does the hardest job in this app — reading ten-minute
/// transcript chunks and returning schema-constrained clip candidates. Titles,
/// descriptions, hashtags and polish are strictly easier, so there's no reason
/// they should still cost a round trip through the browser. The manual panel
/// stays as an explicit fallback for when you want a better answer than a
/// local 8B gives.
enum LocalAIService {
    enum Job: String, CaseIterable, Identifiable {
        case packaging
        case editorCopy
        case polish
        case overlayBrief

        var id: String { rawValue }

        var label: String {
            switch self {
            case .packaging: return "Titles & description"
            case .editorCopy: return "Post copy"
            case .polish: return "Fix transcript wording"
            case .overlayBrief: return "Overlay text"
            }
        }
    }

    struct Packaging: Equatable {
        var titles: [String] = []
        var description: String = ""
        var hashtags: [String] = []
    }

    // MARK: - Schemas

    /// Ollama constrains decoding to these, which is what keeps a small model
    /// from answering in prose with a markdown fence around it.
    static let packagingSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "titles": ["type": "array", "items": ["type": "string"]],
            "description": ["type": "string"],
            "hashtags": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["titles", "description", "hashtags"],
    ]

    static let polishSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "fixes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "text": ["type": "string"],
                    ],
                    "required": ["id", "text"],
                ],
            ],
        ],
        "required": ["fixes"],
    ]

    // MARK: - Prompts

    static func packagingSystem(vertical: Bool) -> String {
        """
        You write packaging for a Twitch streamer's \(vertical ? "vertical short" : "YouTube video").
        Return JSON only. Titles are 4-10 words, specific to what actually happens, \
        no clickbait punctuation stacking, no emoji. The description is 1-2 sentences \
        in the streamer's own register. Hashtags are lowercase, no # prefix, 5-8 of them, \
        relevant to the game and the moment rather than generic growth tags.
        """
    }

    static func packagingUser(transcript: String, vocabulary: String) -> String {
        var parts = ["Transcript of the clip:", transcript]
        if !vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.insert("Names and terms that must be spelled this way: \(vocabulary)", at: 0)
        }
        return parts.joined(separator: "\n\n")
    }

    static let polishSystem = """
    You fix speech-to-text errors in a gaming stream transcript. Return JSON only. \
    Only include lines you actually changed. Fix misheard words, proper nouns and \
    obvious mishearings. Never rewrite for style, never censor, never change what \
    was said — this is a transcript, not a draft.
    """

    static func polishUser(segments: [(id: Int, text: String)], vocabulary: String) -> String {
        let lines = segments.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
        var parts = ["Lines:", lines]
        if !vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.insert("Correct spellings: \(vocabulary)", at: 0)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Parsing

    static func parsePackaging(_ json: String) -> Packaging? {
        guard let data = try? ManualReply.extractJSON(from: json),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var out = Packaging()
        out.titles = (object["titles"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        out.description = (object["description"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        out.hashtags = (object["hashtags"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() }
            .filter { !$0.isEmpty }
        guard !out.titles.isEmpty || !out.description.isEmpty else { return nil }
        return out
    }

    /// Only fixes for lines that actually exist, and only where the text
    /// genuinely changed — a local model likes to echo lines back unchanged.
    static func parsePolish(_ json: String,
                            knownIDs: Set<Int>) -> [(id: Int, text: String)] {
        guard let data = try? ManualReply.extractJSON(from: json),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fixes = object["fixes"] as? [[String: Any]] else { return [] }
        return fixes.compactMap { entry in
            guard let id = entry["id"] as? Int, knownIDs.contains(id),
                  let text = entry["text"] as? String else { return nil }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : (id, cleaned)
        }
    }

    /// Transcripts run long; a local context window doesn't. Takes the head
    /// and tail so both the setup and the payoff survive.
    static func condense(_ text: String, limit: Int = 6000) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 3)
        return head + "\n\n[…]\n\n" + tail
    }
}
