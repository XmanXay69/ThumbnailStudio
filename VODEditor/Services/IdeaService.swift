import Foundation

/// The packaging pass — titles, hooks, thumbnail text, description, tags —
/// manual edition: one copied prompt with the transcript and the scorer's
/// moments baked in, one pasted JSON reply.
enum IdeaService {
    /// Moments handed to the model as anchors, so a title can be traced back to
    /// something that actually happened.
    struct Moment {
        var start: Double
        var score: Double
        var text: String
    }

    static let rules = """
    You write the packaging for a Twitch streamer's YouTube uploads: titles, \
    short-form hooks, thumbnail text, a description, and tags. You are given the \
    stream's transcript and the moments an automatic scorer rated highest.

    Rules:
    - Everything you write must be true of the stream. A title promising \
    something that doesn't happen is the one failure mode that matters — it \
    costs the channel more than a boring title does.
    - Titles: at most 60 characters, or YouTube truncates them. Lead with the \
    thing that happened, not with setup. No manufactured shock, no ALL CAPS, no \
    "you won't believe".
    - Every title carries a `why`: the moment it comes from, with its timestamp.
    - Hooks are the first spoken line of a vertical clip. Under ten words, and \
    they must work with no context at all.
    - Thumbnail text is two to four words. It has to be legible at 120 pixels \
    wide, so short beats clever.
    - Tags are plain search terms, lowercase, no hashes.
    - `best_moment_seconds` must be a timestamp that appears in the moments you \
    were given.
    - `image_prompt` describes a thumbnail background image for an image \
    generator.
    - Transcription is automatic. Slang, usernames and game terms are often \
    misheard — judge intent, and don't repeat an obvious mistranscription back \
    in a title.
    """

    static func manualPrompt(transcript: Transcript,
                             range: ClosedRange<Double>?,
                             moments: [Moment],
                             vocabulary: String) -> String {
        var prompt = rules
        prompt += """
        \n
        Reply with ONLY a JSON code block in exactly this shape, nothing else:

        ```json
        {"titles": [{"text": "...", "why": "..."}], "hooks": ["..."], \
        "thumbnail_texts": ["..."], "description": "...", "tags": ["..."], \
        "best_moment_seconds": 120, "image_prompt": "..."}
        ```

        The highest-scoring moments, by timestamp:
        """
        for moment in moments.prefix(24) {
            prompt += "\n[\(Int(moment.start))] (\(String(format: "%.2f", moment.score))) \(moment.text)"
        }
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            prompt += "\n\nNames and terms that may be mistranscribed: \(vocab)"
        }
        prompt += "\n\nThe transcript ([seconds] text):\n\n" + render(transcript, range: range)
        return prompt
    }

    /// Whole seconds and no word timings — the model is anchoring to moments,
    /// not cutting on frames.
    static func render(_ transcript: Transcript, range: ClosedRange<Double>?) -> String {
        var output = String()
        for segment in transcript.segments {
            if let range, segment.end < range.lowerBound || segment.start > range.upperBound { continue }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            output += "[\(Int(segment.start))] \(text)\n"
        }
        return output
    }

    // MARK: - Reply

    private struct Payload: Decodable {
        struct Title: Decodable {
            let text: String
            let why: String
        }
        let titles: [Title]
        let hooks: [String]
        let thumbnail_texts: [String]
        let description: String
        let tags: [String]
        let best_moment_seconds: Double
        let image_prompt: String
    }

    static func parseReply(_ reply: String, scopeLabel: String) throws -> IdeaPack {
        let data = try ManualReply.extractJSON(from: reply)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CoherenceError.malformed("Shape mismatch: \(error.localizedDescription)")
        }

        return IdeaPack(
            generatedAt: Date(),
            scopeLabel: scopeLabel,
            titles: payload.titles
                .map { TitleIdea(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 why: $0.why) }
                .filter { !$0.text.isEmpty },
            hooks: payload.hooks.filter { !$0.isEmpty },
            thumbnailTexts: payload.thumbnail_texts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            descriptionText: payload.description,
            tags: payload.tags.map { $0.lowercased() }.filter { !$0.isEmpty },
            bestMomentSeconds: payload.best_moment_seconds >= 0 ? payload.best_moment_seconds : nil,
            imagePrompt: payload.image_prompt
        )
    }
}
