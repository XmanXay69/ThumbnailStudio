import Foundation

/// Ready-made prompts for claude.ai. The editor used to call the API for
/// titles and post copy; the manual route replaced it — copy a prompt with
/// the timeline's transcript baked in, paste it into a claude.ai chat, and it
/// comes out of the subscription instead of a metered API key.
enum ManualPrompts {
    static func titles(transcript: String, vocabulary: String) -> String {
        var prompt = """
        I need titles for a short-form vertical clip (TikTok/Reels/Shorts) cut \
        from my Twitch stream. The transcript of exactly what's in the clip is \
        below.

        Rules:
        - Every title must be true of what's actually said. A title promising \
        something that doesn't happen costs more than a boring one.
        - At most 60 characters. Lead with the thing that happened.
        - Match the energy of the clip; no manufactured shock, no "you won't \
        believe".
        - The transcript is automatic and imperfect — judge intent, don't \
        repeat obvious mishearings.

        Give me exactly 5 titles, most promising first.

        Transcript:
        \(transcript)
        """
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            prompt += "\n\nNames and terms in this stream: \(vocab)"
        }
        return prompt
    }

    static func post(transcript: String, title: String, vocabulary: String) -> String {
        var prompt = """
        I need the post copy for a short-form vertical clip (TikTok/Reels/\
        Shorts) cut from my Twitch stream. The transcript of exactly what's in \
        the clip is below.

        Rules:
        - The description is 1–2 sentences, under 220 characters, in my own \
        casual voice — it should read like I typed it. True to what actually \
        happens; no manufactured shock, no "you won't believe".
        - No hashtags inside the description.
        - Then one separate line with 10 hashtags (with the # symbol, no \
        spaces inside a tag), most relevant first: two or three broad \
        discovery tags, the rest specific to the game and the moment.
        - The transcript is automatic and imperfect — judge intent, don't \
        repeat obvious mishearings.
        """
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            prompt += "\n\nThe clip is titled: \(trimmedTitle)"
        }
        prompt += "\n\nTranscript:\n\(transcript)"
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            prompt += "\n\nNames and terms in this stream: \(vocab)"
        }
        return prompt
    }
}
