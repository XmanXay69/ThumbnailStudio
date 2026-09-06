import Foundation

struct ScoreWeights: Codable, Equatable {
    var audio: Double = 0.22
    var speech: Double = 0.10
    var excitement: Double = 0.18
    var chat: Double = 0.25
    /// Only contributes when a scene pass has been run; otherwise the other
    /// weights renormalise, exactly like chat.
    var scene: Double = 0.12
    /// How sharply loudness *rises* — a shout after quiet is emphasis in a way
    /// absolute level can't express.
    var emphasis: Double = 0.13
    /// Loud, deeply-modulated bursts — laughter, and also rapid shouting. Named
    /// for the common case, but it is a burst detector, not a laugh classifier.
    var laughter: Double = 0.10

    static let standard = ScoreWeights()

    /// The focus presets scale the standard weights rather than replacing
    /// them — every signal keeps contributing, the chosen kind just dominates.
    /// The curve normalises the weighted sum, so only the ratios matter.
    func focused(_ focus: ContentFocus) -> ScoreWeights {
        var weights = self
        switch focus {
        case .balanced:
            break
        case .funny:
            weights.laughter *= 2.4
            weights.excitement *= 1.6
            weights.chat *= 1.2
            weights.speech *= 0.8
        case .chat:
            weights.chat *= 2.2
            weights.excitement *= 1.2
            weights.audio *= 0.8
            weights.scene *= 0.6
        case .story:
            weights.speech *= 2.4
            weights.emphasis *= 1.4
            weights.audio *= 0.7
            weights.scene *= 0.4
            weights.laughter *= 0.8
        case .missions:
            weights.scene *= 1.9
            weights.audio *= 1.5
            weights.excitement *= 1.3
            weights.speech *= 0.7
        }
        return weights
    }
}

/// What the analysis hunts for. Local signals can't read a game's quest log,
/// so each focus leans on the measurable signature of that kind of moment.
enum ContentFocus: String, Codable, CaseIterable, Identifiable {
    case balanced
    case funny
    case chat
    case story
    case missions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .funny: return "Funny moments"
        case .chat: return "Chat interaction"
        case .story: return "Story times"
        case .missions: return "Missions & gameplay"
        }
    }

    var explainer: String {
        switch self {
        case .balanced: return "Every signal at its standard weight."
        case .funny: return "Laughter bursts and hype language lead."
        case .chat: return "Chat spikes and call-outs lead — import the chat replay for this one."
        case .story: return "Sustained talking leads; game noise and scene cuts step back."
        case .missions: return "Scene changes and game audio lead — action over commentary."
        }
    }
}

/// Per-second interest curve plus the components that produced it, so the UI
/// can show *why* a moment scored well rather than just asserting a number.
struct ScoreCurve: Codable, Equatable {
    var windowSeconds: Double = 1
    var values: [Double] = []
    var audio: [Double] = []
    var speech: [Double] = []
    var excitement: [Double] = []
    var chat: [Double] = []
    var scene: [Double] = []
    var emphasis: [Double] = []
    var laughter: [Double] = []
    var hasChat = false
    var hasScene = false
    var weights = ScoreWeights.standard

    var isEmpty: Bool { values.isEmpty }
    var duration: Double { Double(values.count) * windowSeconds }

    func index(for time: Double) -> Int {
        max(0, min(values.count - 1, Int(time / windowSeconds)))
    }

    func value(at time: Double) -> Double {
        values.isEmpty ? 0 : values[index(for: time)]
    }

    /// Mean of each component over a range — the breakdown shown on a candidate.
    func breakdown(from start: Double, to end: Double) -> [String: Double] {
        guard !values.isEmpty, end > start else { return [:] }
        let lower = index(for: start)
        let upper = max(lower + 1, index(for: end))
        func mean(_ series: [Double]) -> Double {
            let slice = series[lower..<min(upper, series.count)]
            return slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
        }
        var result = ["audio": mean(audio), "speech": mean(speech), "excitement": mean(excitement),
                      "emphasis": mean(emphasis), "laughter": mean(laughter)]
        if hasChat { result["chat"] = mean(chat) }
        if hasScene { result["scene"] = mean(scene) }
        return result
    }
}

enum ScoringService {
    /// Laughter, hype and disbelief markers. Deliberately a flat lexicon and a
    /// weighted sum — per the brief, this is not the place for a model.
    private static let excitementTokens: Set<String> = [
        "lol", "lmao", "lmfao", "rofl", "kekw", "kek", "omegalul", "lulw", "lul",
        "bruh", "bro", "yo", "damn", "insane", "crazy", "wild", "nuts", "sheesh",
        "clip", "clipped", "chat", "actually", "literally", "dude", "man",
        "wtf", "omg", "god", "jesus", "holy", "shit", "fuck", "fucking", "hell",
        "no", "stop", "wait", "what", "huh", "yooo", "yoo", "ayo", "oh",
        "pog", "pogchamp", "poggers", "w", "dub", "ez", "gg", "sadge", "monkas",
    ]

    private static let excitementPhrases = [
        "let's go", "lets go", "no way", "oh my god", "what the", "are you serious",
        "you serious", "i can't", "i cant", "shut up", "on god", "for real",
        "hold on", "wait wait", "look at", "did you see", "that's crazy",
    ]

    private static let hypeEmotes: Set<String> = [
        "kekw", "omegalul", "lulw", "lul", "pog", "poggers", "pogchamp", "pogu",
        "ez", "gg", "w", "monkas", "pepelaugh", "kekl", "icant", "sadge", "copium",
    ]

    /// Chat asking for a clip is chat telling you exactly where the clip is.
    private static let clipRequests: Set<String> = [
        "clip", "clipped", "clipit", "clipthat", "clips", "clipper", "vod",
    ]

    static func score(duration: Double,
                      waveform: WaveformData?,
                      transcript: Transcript,
                      chat: [ChatMessage],
                      scenes: [Double] = [],
                      weights: ScoreWeights = .standard,
                      windowSeconds: Double = 1) -> ScoreCurve {
        guard duration > 0 else { return ScoreCurve() }
        let binCount = max(1, Int(ceil(duration / windowSeconds)))

        var audio = [Double](repeating: 0, count: binCount)
        var speech = [Double](repeating: 0, count: binCount)
        var excitement = [Double](repeating: 0, count: binCount)
        var chatRate = [Double](repeating: 0, count: binCount)
        var sceneRate = [Double](repeating: 0, count: binCount)
        var emphasis = [Double](repeating: 0, count: binCount)
        var laughter = [Double](repeating: 0, count: binCount)

        func bin(_ time: Double) -> Int? {
            let index = Int(time / windowSeconds)
            return index >= 0 && index < binCount ? index : nil
        }

        // Audio envelope, averaged from the peaks already on disk — plus two
        // signals derived from the *shape* of that envelope rather than its
        // level.
        if let waveform, waveform.peaksPerSecond > 0 {
            let peaksPerBin = max(1, Int(waveform.peaksPerSecond * windowSeconds))
            var previousMean = 0.0

            for index in 0..<binCount {
                let lower = index * peaksPerBin
                let upper = min(lower + peaksPerBin, waveform.peaks.count)
                guard lower < upper else { break }

                let window = waveform.peaks[lower..<upper].map { Double($0) / 255 }
                let mean = window.reduce(0, +) / Double(window.count)
                audio[index] = mean

                // Emphasis: how far loudness climbed versus the previous
                // window. Only rises count — a drop into silence isn't emphasis.
                emphasis[index] = max(0, mean - previousMean)
                previousMean = mean

                // Bursts: loud, deeply-modulated stretches — what laughter and
                // rapid shouting look like in an envelope.
                //
                // Rate alone is not enough. Ordinary connected speech modulates
                // at its syllable rate, 4–7 Hz, which sits squarely inside the
                // band laughter occupies; gating on rate only fired on ~90% of
                // windows, i.e. it was detecting speech. What separates a burst
                // is *depth* — laughter drops to near-silence between hahs,
                // where connected speech stays up — and loudness.
                guard window.count > 3 else { continue }
                var crossings = 0
                var previousSign = 0
                for value in window {
                    let delta = value - mean
                    let sign = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
                    if sign != 0, previousSign != 0, sign != previousSign { crossings += 1 }
                    if sign != 0 { previousSign = sign }
                }
                let rate = Double(crossings) / windowSeconds
                let high = window.max() ?? 0
                let low = window.min() ?? 0
                let depth = high + low > 0 ? (high - low) / (high + low) : 0

                if rate >= 6, rate <= 16, depth > 0.65, mean > 0.08 {
                    let centred = max(0, 1 - abs(rate - 11) / 5)
                    laughter[index] = centred * depth * mean
                }
            }
        }

        // Speech density and excitement markers, attributed to word start times.
        for segment in transcript.segments {
            let lowercased = segment.text.lowercased()
            var phraseHits = 0
            for phrase in excitementPhrases where lowercased.contains(phrase) { phraseHits += 1 }
            if phraseHits > 0, let index = bin(segment.start) {
                excitement[index] += Double(phraseHits) * 1.5
            }

            for word in segment.words {
                guard let index = bin(word.start) else { continue }
                speech[index] += 1

                let cleaned = word.text
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                if excitementTokens.contains(cleaned) { excitement[index] += 1 }
                if isLaughter(cleaned) { excitement[index] += 2 }
                excitement[index] += Double(word.text.filter { $0 == "!" }.count)
            }
        }

        // Chat velocity. Not every message is equal evidence: chat explicitly
        // asking for a clip is the single most direct signal a moment landed,
        // and hype emotes beat ordinary chatter.
        for message in chat {
            guard let index = bin(message.offset) else { continue }
            let lowercased = message.body.lowercased()
            let words = lowercased.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)

            if words.contains(where: { clipRequests.contains($0) }) {
                chatRate[index] += 5
            } else if words.contains(where: { hypeEmotes.contains($0) }) {
                chatRate[index] += 2
            } else {
                chatRate[index] += 1
            }
        }

        // Chat *accelerating* marks the instant something happened; a sustained
        // high level only says the stream is busy. Blend both.
        if !chat.isEmpty {
            var level = chatRate
            normalize(&level)
            var acceleration = [Double](repeating: 0, count: binCount)
            for index in 1..<binCount {
                acceleration[index] = max(0, chatRate[index] - chatRate[index - 1])
            }
            normalize(&acceleration)
            for index in 0..<binCount {
                chatRate[index] = level[index] * 0.7 + acceleration[index] * 0.3
            }
        }

        // Cuts cluster, so scene density over a window reads as visual activity.
        for scene in scenes {
            guard let index = bin(scene) else { continue }
            sceneRate[index] += 1
        }

        // Robust normalisation: scale by the 95th percentile so one screaming
        // moment doesn't flatten the rest of the VOD to zero.
        normalize(&audio)
        normalize(&speech)
        normalize(&excitement)
        normalize(&chatRate)
        normalize(&sceneRate)
        normalize(&emphasis)
        normalize(&laughter)

        smooth(&audio, radius: 2)
        smooth(&speech, radius: 2)
        smooth(&excitement, radius: 3)
        smooth(&chatRate, radius: 3)
        // Cuts are sparse — a wider window turns them into a usable density.
        smooth(&sceneRate, radius: 8)
        // Emphasis is a spike by construction; widen it enough to cover the
        // moment it marks rather than a single second.
        smooth(&emphasis, radius: 4)
        smooth(&laughter, radius: 3)

        let hasChat = !chat.isEmpty
        let hasScene = !scenes.isEmpty
        var effective = weights
        if !hasChat { effective.chat = 0 }
        if !hasScene { effective.scene = 0 }
        if waveform == nil { effective.emphasis = 0; effective.laughter = 0 }
        let total = effective.audio + effective.speech + effective.excitement
            + effective.chat + effective.scene + effective.emphasis + effective.laughter
        guard total > 0 else { return ScoreCurve() }

        var combined = [Double](repeating: 0, count: binCount)
        for index in 0..<binCount {
            combined[index] = (audio[index] * effective.audio
                               + speech[index] * effective.speech
                               + excitement[index] * effective.excitement
                               + chatRate[index] * effective.chat
                               + sceneRate[index] * effective.scene
                               + emphasis[index] * effective.emphasis
                               + laughter[index] * effective.laughter) / total
        }
        smooth(&combined, radius: 3)

        return ScoreCurve(windowSeconds: windowSeconds, values: combined,
                          audio: audio, speech: speech, excitement: excitement,
                          chat: chatRate, scene: sceneRate,
                          emphasis: emphasis, laughter: laughter,
                          hasChat: hasChat, hasScene: hasScene, weights: weights)
    }

    /// `haha`, `hahaha`, `ahah` and friends.
    private static func isLaughter(_ token: String) -> Bool {
        guard token.count >= 3, token.allSatisfy({ $0 == "a" || $0 == "h" }) else { return false }
        return token.contains("ha") || token.contains("ah")
    }

    private static func normalize(_ series: inout [Double]) {
        let positive = series.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return }
        let reference = positive[min(positive.count - 1, Int(Double(positive.count) * 0.95))]
        guard reference > 0 else { return }
        for index in series.indices {
            series[index] = min(1, series[index] / reference)
        }
    }

    private static func smooth(_ series: inout [Double], radius: Int) {
        guard radius > 0, series.count > radius * 2 else { return }
        let source = series
        var runningTotal = 0.0
        for index in 0...min(radius, source.count - 1) { runningTotal += source[index] }
        var count = min(radius, source.count - 1) + 1

        for index in series.indices {
            series[index] = runningTotal / Double(count)
            let dropping = index - radius
            let adding = index + radius + 1
            if dropping >= 0 { runningTotal -= source[dropping]; count -= 1 }
            if adding < source.count { runningTotal += source[adding]; count += 1 }
        }
    }
}
