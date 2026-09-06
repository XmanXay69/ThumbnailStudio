import Foundation

/// Fixes what whisper misheard, and nothing else — manual edition.
///
/// Whisper's word error rate on fast, slangy stream speech is the accuracy
/// ceiling of everything downstream — captions, scoring, titles. Context is
/// the only lever that buys a lot, and a language model reading the whole
/// conversation is the only tool here that has any. The pass is strictly
/// constrained: it may rewrite the text of a line, it may never merge, split,
/// reorder or re-time anything. One copied prompt covers one batch of lines;
/// the pasted reply comes back through `parseReply`.
enum TranscriptPolisher {
    static let batchSize = 200

    static let rules = """
    You correct automatic speech-recognition errors in Twitch stream \
    transcripts. You receive numbered lines. Return corrections ONLY for lines \
    that contain a recognition error — a misheard word, a mangled username or \
    game term, nonsense syllables. Judge from the context of the surrounding \
    lines.

    Rules:
    - Correct only what was misheard. Do not rephrase, censor, tidy grammar or \
    complete sentences. Keep slang exactly as spoken.
    - Keep each correction roughly the same length as the original — the words \
    are timed against audio.
    - If a line is fine, do not return it. Most lines are fine.
    - Use the provided names and terms when the audio plausibly matches them.
    """

    struct Correction: Equatable {
        var id: Int
        var text: String
    }

    static func manualPrompt(segments: [(id: Int, text: String)], vocabulary: String) -> String {
        var prompt = rules
        prompt += """
        \n
        Reply with ONLY a JSON code block in exactly this shape, nothing else:

        ```json
        {"corrections": [{"id": 12, "text": "the corrected line"}]}
        ```
        """
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            prompt += "\n\nNames and terms that appear in this stream: \(vocab)"
        }
        prompt += "\n\nThe lines:\n\n"
        for segment in segments { prompt += "[\(segment.id)] \(segment.text)\n" }
        return prompt
    }

    // MARK: - Reply

    private struct Payload: Decodable {
        struct Item: Decodable {
            let id: Int
            let text: String
        }
        let corrections: [Item]
    }

    static func parseReply(_ reply: String) throws -> [Correction] {
        let data = try ManualReply.extractJSON(from: reply)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CoherenceError.malformed("Shape mismatch: \(error.localizedDescription)")
        }
        return payload.corrections
            .map { Correction(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
    }

    // MARK: - Applying

    /// A corrected segment, with the original timing kept intact.
    ///
    /// When the corrected text has the same word count as the original, each
    /// new word takes the old word's exact DTW timing — so fixing "fronts" to
    /// "trunks" doesn't cost the karaoke highlight its sample accuracy. Only a
    /// correction that changes the word count falls back to an even split.
    static func corrected(segment: TranscriptSegment, text: String) -> TranscriptSegment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else { return segment }

        var updated = segment
        updated.text = trimmed
        let original = segment.words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let tokens = trimmed.split(separator: " ").map(String.init)
        if tokens.count == original.count, !original.isEmpty {
            updated.words = zip(original, tokens).enumerated().map { offset, pair in
                TranscriptWord(text: (offset == 0 ? "" : " ") + pair.1,
                               start: pair.0.start, end: pair.0.end,
                               probability: pair.0.probability)
            }
        } else {
            updated.words = CaptionBuilder.redistribute(text: trimmed,
                                                        from: segment.start, to: segment.end)
        }
        return updated
    }
}
