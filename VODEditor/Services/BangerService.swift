import Foundation

/// The banger pass: which of these clips would actually stop a scroll?
///
/// Two stages. The heuristic runs instantly on signals already computed —
/// laughter, emote spikes, how early the payoff lands, exclamation density.
/// Then the local model re-judges the top of the list clip by clip, seeing
/// each transcript, and its verdict blends with (never replaces) the
/// heuristic. Everything stays local; without a model the heuristic alone
/// still ranks.
enum BangerService {
    struct Inputs: Equatable {
        var duration: Double
        /// Confidence-weighted seconds of laughter inside the clip.
        var laughSeconds: Double
        /// Chat emote spikes inside the clip (0 without a chat import).
        var emoteSpikes: Int
        /// When the loudest moment lands, as a fraction of the clip.
        var peakPosition: Double
        /// Exclamations and question marks per 100 words.
        var punchPer100: Double
        /// Words in the first 3 seconds.
        var openingWords: Int
    }

    /// 0–100. Weights chosen so each signal can carry a clip on its own but
    /// two together beat any single one.
    static func heuristicScore(_ inputs: Inputs) -> Double {
        guard inputs.duration > 3 else { return 0 }
        var score = 0.0

        // Laughter is the strongest single signal there is.
        score += min(38, inputs.laughSeconds / inputs.duration * 130)
        // Chat reacting in numbers.
        score += min(22, Double(inputs.emoteSpikes) * 8)
        // A peak in the first half hooks; a peak at the very end means the
        // clip makes people wait.
        if inputs.peakPosition < 0.5 { score += 14 * (1 - inputs.peakPosition / 0.5) }
        // Delivery energy.
        score += min(14, inputs.punchPer100 * 2.4)
        // A dense open survives the swipe.
        score += inputs.openingWords >= 5 ? 12 : Double(inputs.openingWords) * 2
        return min(100, score)
    }

    /// What earns the flame. High enough that a badge means something.
    static let bangerThreshold = 70.0

    /// 60/40 toward the model when it has spoken — it read the words, the
    /// heuristic only heard the shape.
    static func blended(heuristic: Double, model: Double?) -> Double {
        guard let model else { return heuristic }
        return min(100, max(0, model * 0.6 + heuristic * 0.4))
    }

    // MARK: - The model stage

    static let judgeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "verdicts": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "score": ["type": "integer"],
                        "hook": ["type": "string"],
                    ],
                    "required": ["id", "score", "hook"],
                ],
            ],
        ],
        "required": ["verdicts"],
    ]

    static let judgeSystem = """
    You judge Twitch clips for short-form. For each clip, score 0-100 for how \
    likely it is to stop a stranger's scroll in the first three seconds and \
    hold them to the end — funny beats interesting, specific beats generic, \
    a story with a turn beats a highlight without context. Also write "hook": \
    the single line from the transcript (verbatim or lightly trimmed) the clip \
    should open on. Return JSON only. Score honestly across the full range; \
    most clips are 30-60 and a 90 should be rare.
    """

    /// One judging batch: numbered transcript snippets in, verdicts out.
    static func judgeUser(batch: [(id: Int, title: String, transcript: String)]) -> String {
        batch.map { entry in
            "CLIP \(entry.id) — \(entry.title)\n\(entry.transcript)"
        }.joined(separator: "\n\n---\n\n")
    }

    /// Parses verdicts, dropping invented ids and clamping scores.
    static func parseVerdicts(_ json: String,
                              knownIDs: Set<Int>) -> [(id: Int, score: Double, hook: String)] {
        guard let data = try? ManualReply.extractJSON(from: json),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdicts = object["verdicts"] as? [[String: Any]] else { return [] }
        return verdicts.compactMap { entry in
            guard let id = entry["id"] as? Int, knownIDs.contains(id) else { return nil }
            let raw = (entry["score"] as? Int).map(Double.init)
                ?? (entry["score"] as? Double) ?? 0
            let hook = (entry["hook"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (id, min(100, max(0, raw)), hook)
        }
    }

    /// Snippet budget per clip so a batch of eight fits an 8B's context.
    static func snippet(_ text: String, limit: Int = 700) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
