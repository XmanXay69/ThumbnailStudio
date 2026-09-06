import Foundation

/// The clip finder's brain: prompts, parsing, boundary snapping, dedupe,
/// and category-balanced selection. Everything here is pure and testable —
/// the session owns the loop, Ollama owns the inference.
enum AutoClipService {
    // MARK: - Prompt

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "candidates": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "category": ["type": "string"],
                        "confidence": ["type": "number"],
                        "title": ["type": "string"],
                        "hook": ["type": "string"],
                        "why": ["type": "string"],
                        "suggested_caption": ["type": "string"],
                    ],
                    "required": ["start", "end", "category", "confidence", "title"],
                ],
            ],
        ],
        "required": ["candidates"],
    ]

    static func systemPrompt(categories: [ClipCategory]) -> String {
        var prompt = """
        You find short-form clip moments in Twitch VOD transcripts. You get one \
        window of a longer stream: the transcript with timestamps, the chat for \
        that window, and hints from signal analysis.

        Categories you may use (use the name exactly as written):
        """
        for category in categories {
            prompt += "\n- \(category.name): \(category.description)"
        }
        prompt += """
        \n
        Rules:
        - Timestamps in your answer must come from the transcript shown — never invent times.
        - A clip is 20–90 seconds of one self-contained moment: setup only if the payoff needs it, cut before the conversation drifts.
        - Only report moments that genuinely fit a category. An empty list is a valid answer.
        - confidence is 0 to 1: how sure you are this works as a standalone short.
        - hook is the first spoken line a viewer would hear; title is for the editor's bin, under 60 characters.
        - suggested_caption is for the TikTok/Reels caption field, casual voice.
        """
        return prompt
    }

    static func userPrompt(chunk: AutoClipChunk, transcript: Transcript,
                           chat: [ChatMessage], categories: [ClipCategory],
                           streamer: String, vocabulary: String,
                           hints: [String]) -> String {
        var prompt = String(format: "Window %.0fs to %.0fs of the stream.", chunk.start, chunk.end)
        if !streamer.isEmpty { prompt += " Streamer: \(streamer)." }
        let vocab = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty { prompt += "\nNames and terms: \(vocab)" }
        if !hints.isEmpty {
            prompt += "\n\nSignal hints for this window (from chat and audio analysis, imperfect but usually right):"
            for hint in hints { prompt += "\n- \(hint)" }
        }
        prompt += "\n\nTranscript ([seconds] text):\n"
        for segment in transcript.segments
        where segment.end > chunk.start && segment.start < chunk.end {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            prompt += "[\(Int(segment.start))] \(text)\n"
        }
        let windowChat = chat.filter { $0.offset >= chunk.start && $0.offset < chunk.end }
        if !windowChat.isEmpty {
            prompt += "\nChat ([seconds] author: message):\n"
            // Cap so a chat flood can't crowd the transcript out of context.
            for message in windowChat.prefix(220) {
                prompt += "[\(Int(message.offset))] \(message.author): \(message.body.prefix(80))\n"
            }
        }
        return prompt
    }

    /// The Step-1.5 hints for one window, phrased for the prompt.
    static func hints(for chunk: AutoClipChunk, spikes: [ClipSignals.EmoteSpike],
                      chatReads: [Double], monologues: [ClipSignals.Monologue],
                      categories: [ClipCategory]) -> [String] {
        var lines: [String] = []
        for spike in spikes where spike.time >= chunk.start && spike.time < chunk.end {
            let name = categories.first { $0.id == spike.categoryID }?.name ?? "?"
            lines.append(String(format: "around %.0fs chat spiked with %@-type emotes (%d messages)",
                                spike.time, name, spike.strength))
        }
        for read in chatReads where read >= chunk.start && read < chunk.end {
            lines.append(String(format: "around %.0fs the streamer read chat aloud", read))
        }
        for monologue in monologues
        where monologue.start < chunk.end && monologue.end > chunk.start {
            lines.append(String(format: "%.0fs–%.0fs is one long uninterrupted monologue (story-time shape)",
                                max(monologue.start, chunk.start), min(monologue.end, chunk.end)))
        }
        return lines
    }

    // MARK: - Parsing

    private struct Payload: Decodable {
        struct Item: Decodable {
            let start: Double
            let end: Double
            let category: String
            let confidence: Double?
            let title: String?
            let hook: String?
            let why: String?
            let suggested_caption: String?
        }
        let candidates: [Item]
    }

    /// One chunk's reply → candidates. Tolerant of fences and prose (schema
    /// constraint mostly prevents them; mostly). Times outside the chunk are
    /// invented, and category names that match nothing are dropped rather
    /// than guessed.
    static func parseReply(_ reply: String, chunk: AutoClipChunk,
                           categories: [ClipCategory]) throws -> [AutoClipCandidate] {
        let data = try ManualReply.extractJSON(from: reply)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CoherenceError.malformed("Shape mismatch: \(error.localizedDescription)")
        }
        return payload.candidates.compactMap { item in
            guard item.end > item.start + 5,
                  item.start >= chunk.start - 5, item.end <= chunk.end + 5,
                  let category = match(item.category, in: categories) else { return nil }
            return AutoClipCandidate(
                start: max(chunk.start, item.start),
                end: min(chunk.end, item.end),
                categoryID: category.id,
                confidence: min(1, max(0, item.confidence ?? 0.5)),
                title: String((item.title ?? "Clip").prefix(70)),
                hook: item.hook ?? "",
                why: item.why ?? "",
                suggestedCaption: item.suggested_caption ?? "",
                source: .model)
        }
    }

    static func match(_ name: String, in categories: [ClipCategory]) -> ClipCategory? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = categories.first(where: { $0.name.lowercased() == wanted }) { return exact }
        // Small models abbreviate ("funny" for "Funny moments"); prefix or
        // containment either way is close enough to keep the candidate.
        return categories.first {
            let own = $0.name.lowercased()
            return own.hasPrefix(wanted) || wanted.hasPrefix(own)
                || own.contains(wanted) || wanted.contains(own)
        }
    }

    // MARK: - Heuristic fallback

    /// Candidates straight from the free signals — what ships when the local
    /// model isn't installed, and honestly labelled as such.
    static func heuristicCandidates(chunk: AutoClipChunk, transcript: Transcript,
                                    spikes: [ClipSignals.EmoteSpike],
                                    chatReads: [Double],
                                    monologues: [ClipSignals.Monologue],
                                    categories: [ClipCategory],
                                    request: AutoClipRequest) -> [AutoClipCandidate] {
        var candidates: [AutoClipCandidate] = []
        let target = min(60, max(request.minSeconds, 40))

        for spike in spikes where spike.time >= chunk.start && spike.time < chunk.end {
            // The moment sits ~8s before chat lands on it.
            let start = max(chunk.start, spike.time - 12)
            candidates.append(AutoClipCandidate(
                start: start, end: min(chunk.end, start + target),
                categoryID: spike.categoryID,
                confidence: min(0.7, 0.35 + Double(spike.strength) / 60),
                title: firstLine(transcript, after: start) ?? "Chat went off",
                why: "Chat spiked with \(spike.strength) matching emotes.",
                source: .heuristic))
        }
        if let chatCategory = categories.first(where: { $0.name.lowercased().contains("chat") }) {
            for read in chatReads where read >= chunk.start && read < chunk.end {
                let start = max(chunk.start, read - 6)
                candidates.append(AutoClipCandidate(
                    start: start, end: min(chunk.end, start + target),
                    categoryID: chatCategory.id, confidence: 0.55,
                    title: firstLine(transcript, after: start) ?? "Reading chat",
                    why: "The streamer echoed a chat message here.",
                    source: .heuristic))
            }
        }
        if let storyCategory = categories.first(where: { $0.name.lowercased().contains("story") }) {
            for monologue in monologues
            where monologue.start >= chunk.start && monologue.start < chunk.end {
                let length = min(request.maxSeconds + AutoClipRequest.lengthOverflow,
                                 monologue.end - monologue.start)
                candidates.append(AutoClipCandidate(
                    start: monologue.start, end: monologue.start + length,
                    categoryID: storyCategory.id, confidence: 0.5,
                    title: firstLine(transcript, after: monologue.start) ?? "Story time",
                    why: String(format: "%.0f seconds of uninterrupted talking with quiet chat.",
                                monologue.end - monologue.start),
                    source: .heuristic))
            }
        }
        return candidates
    }

    private static func firstLine(_ transcript: Transcript, after time: Double) -> String? {
        guard let segment = transcript.segments.first(where: { $0.start >= time }) else { return nil }
        let text = segment.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(60))
    }

    // MARK: - Boundaries

    /// Never cut mid-sentence: start snaps back to the beginning of the
    /// sentence under it, end snaps forward to the end of the sentence under
    /// it — inside the length band (±15s overflow when a natural boundary
    /// falls just outside). Then a breath of padding either side.
    static func snapBoundaries(_ candidate: AutoClipCandidate, transcript: Transcript,
                               request: AutoClipRequest,
                               duration: Double) -> AutoClipCandidate {
        var snapped = candidate
        if let opening = transcript.segments.last(where: { $0.start <= candidate.start + 0.5 }) {
            // Only pull back to the sentence start if it doesn't stretch the
            // clip absurdly — an 8-second wind-up is throat-clearing, not setup.
            if candidate.start - opening.start <= 8 {
                snapped.start = opening.start
            } else if let next = transcript.segments.first(where: { $0.start > candidate.start - 0.5 }) {
                snapped.start = next.start
            }
        }
        let ceiling = snapped.start + request.maxSeconds + AutoClipRequest.lengthOverflow
        if let closing = transcript.segments.first(where: { $0.end >= candidate.end && $0.end <= ceiling }) {
            snapped.end = closing.end
        } else if let inside = transcript.segments.last(where: { $0.end <= ceiling && $0.end > snapped.start }) {
            snapped.end = inside.end
        }
        if snapped.end - snapped.start < max(15, request.minSeconds - AutoClipRequest.lengthOverflow),
           let further = transcript.segments.first(where: {
               $0.end >= snapped.start + request.minSeconds && $0.end <= ceiling
           }) {
            snapped.end = further.end
        }
        // ~0.3s before the first word, ~0.5s after the last, clamped.
        snapped.start = max(0, snapped.start - 0.3)
        snapped.end = min(duration, snapped.end + 0.5)
        return snapped
    }

    // MARK: - Dedupe and selection

    /// Chunk overlap regions produce the same moment twice; near-identical
    /// spans collapse to the more confident report.
    static func dedupe(_ candidates: [AutoClipCandidate]) -> [AutoClipCandidate] {
        var kept: [AutoClipCandidate] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let duplicate = kept.contains { existing in
                let overlap = min(existing.end, candidate.end) - max(existing.start, candidate.start)
                guard overlap > 0 else { return false }
                let shorter = min(existing.duration, candidate.duration)
                let ratio = overlap / max(1, shorter)
                return existing.categoryID == candidate.categoryID ? ratio > 0.45 : ratio > 0.8
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// The requested count, spread across categories rather than ten of
    /// whichever scores highest — plus roughly another request's worth held
    /// as surplus so a rejection has a replacement ready.
    static func select(_ candidates: [AutoClipCandidate], request: AutoClipRequest)
        -> [AutoClipCandidate] {
        var byCategory: [UUID: [AutoClipCandidate]] = [:]
        for candidate in candidates {
            byCategory[candidate.categoryID, default: []].append(candidate)
        }
        for key in byCategory.keys {
            byCategory[key]?.sort { $0.confidence > $1.confidence }
        }
        // Round-robin over categories ordered by their best candidate.
        let order = byCategory.keys.sorted {
            (byCategory[$0]?.first?.confidence ?? 0) > (byCategory[$1]?.first?.confidence ?? 0)
        }
        var suggested: [UUID] = []
        var exhausted = false
        while suggested.count < request.count && !exhausted {
            exhausted = true
            for key in order where suggested.count < request.count {
                if let next = byCategory[key]?.first {
                    byCategory[key]?.removeFirst()
                    suggested.append(next.id)
                    exhausted = false
                }
            }
        }
        let surplusCount = request.count
        var surplus: Set<UUID> = []
        outer: while surplus.count < surplusCount {
            var advanced = false
            for key in order where surplus.count < surplusCount {
                if let next = byCategory[key]?.first {
                    byCategory[key]?.removeFirst()
                    surplus.insert(next.id)
                    advanced = true
                }
            }
            if !advanced { break outer }
        }
        return candidates.map { candidate in
            var updated = candidate
            if suggested.contains(candidate.id) {
                updated.state = .suggested
            } else if surplus.contains(candidate.id) {
                updated.state = .surplus
            } else {
                updated.state = .rejected
            }
            return updated
        }
    }
}
