import Foundation

/// A kind of moment the clip finder hunts for. The description is not
/// decoration — it is injected verbatim into the analysis prompt, so editing
/// it changes what gets detected. Emote hints feed the chat-spike heuristic.
struct ClipCategory: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var description: String
    /// Chat emotes/tokens whose spikes point at this category. Case-insensitive.
    var emoteHints: [String] = []
    var enabled: Bool = true

    init(id: UUID = UUID(), name: String, description: String,
         emoteHints: [String] = [], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.emoteHints = emoteHints
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        name = try container.decode(String.self, forKey: .name)
        description = value(.description, "")
        emoteHints = value(.emoteHints, [])
        enabled = value(.enabled, true)
    }

    /// The roster new projects start with.
    static let defaults: [ClipCategory] = [
        ClipCategory(name: "Funny moments",
                     description: "Laughter, punchlines, reaction beats, things going wrong.",
                     emoteHints: ["KEKW", "LULW", "OMEGALUL", "LMAO", "LUL", "💀", "😂", "ICANT"]),
        ClipCategory(name: "Chat interaction",
                     description: "Reading chat aloud, responding to a donation or sub, chat-driven bits."),
        ClipCategory(name: "Story time",
                     description: "An extended personal anecdote or narrative — usually low audio energy but high engagement."),
        ClipCategory(name: "Missions / challenges",
                     description: "Attempting a goal or task, especially the outcome moment — the win, the fail, the clutch."),
        ClipCategory(name: "Reactions",
                     description: "Genuine surprise, shock, or a strong opinion landing in the moment.",
                     emoteHints: ["Pog", "PogChamp", "POGGERS", "WTF", "OMG", "W", "L", "??"]),
        ClipCategory(name: "Hot takes",
                     description: "Opinionated statements likely to drive comments and arguments."),
    ]
}

/// What the setup sheet asked for.
struct AutoClipRequest: Codable, Equatable {
    var count: Int = 5
    /// Target length band. Treated as a target, not a hard rule — a natural
    /// boundary just outside gets ±15s of overflow.
    var minSeconds: Double = 30
    var maxSeconds: Double = 60
    var categoryIDs: [UUID] = []

    static let lengthOverflow: Double = 15
}

/// One clip the finder proposes. Everything stays editable — this is a
/// timestamped starting point, not a finished short.
struct AutoClipCandidate: Codable, Identifiable, Equatable {
    enum Source: String, Codable {
        /// Local model analysis.
        case model
        /// Emote spikes / chat-reading / monologue heuristics.
        case heuristic
    }
    enum State: String, Codable {
        /// Shown in the bin.
        case suggested
        /// Found but held back — promoted when a suggestion is rejected.
        case surplus
        /// Turned into a shorts candidate.
        case added
        case rejected
    }

    var id: UUID = UUID()
    var start: Double
    var end: Double
    var categoryID: UUID
    var confidence: Double
    var title: String
    var hook: String = ""
    var why: String = ""
    var suggestedCaption: String = ""
    var source: Source = .model
    var state: State = .suggested

    init(id: UUID = UUID(), start: Double, end: Double, categoryID: UUID,
         confidence: Double, title: String, hook: String = "", why: String = "",
         suggestedCaption: String = "", source: Source = .model, state: State = .suggested) {
        self.id = id
        self.start = start
        self.end = end
        self.categoryID = categoryID
        self.confidence = confidence
        self.title = title
        self.hook = hook
        self.why = why
        self.suggestedCaption = suggestedCaption
        self.source = source
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        categoryID = try container.decode(UUID.self, forKey: .categoryID)
        confidence = value(.confidence, 0.5)
        title = value(.title, "")
        hook = value(.hook, "")
        why = value(.why, "")
        suggestedCaption = value(.suggestedCaption, "")
        source = value(.source, Source.model)
        state = value(.state, State.suggested)
    }

    var duration: Double { end - start }
}

/// One analysis window sent to the model.
struct AutoClipChunk: Codable, Equatable, Identifiable {
    var index: Int
    var start: Double
    var end: Double
    var id: Int { index }
}

/// The whole run, persisted after every chunk so a crash at 30 of 36 keeps
/// 30 — and re-opening a project never re-runs inference.
struct AutoClipRun: Codable, Equatable {
    var request: AutoClipRequest
    /// Snapshot of the categories the run used; editing the live list later
    /// doesn't silently invalidate cached results.
    var categories: [ClipCategory]
    var chunks: [AutoClipChunk] = []
    var completedChunks: Set<Int> = []
    var failedChunks: Set<Int> = []
    var candidates: [AutoClipCandidate] = []
    /// "llama3.1:8b" or "heuristics" — surfaced so it's obvious at a glance
    /// whether this was full analysis or the fallback.
    var backend: String = ""
    var startedAt: Date = Date()
    var finishedAt: Date?

    init(request: AutoClipRequest, categories: [ClipCategory]) {
        self.request = request
        self.categories = categories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        request = value(.request, AutoClipRequest())
        categories = value(.categories, ClipCategory.defaults)
        chunks = value(.chunks, [])
        completedChunks = value(.completedChunks, [])
        failedChunks = value(.failedChunks, [])
        candidates = value(.candidates, [])
        backend = value(.backend, "")
        startedAt = value(.startedAt, Date())
        finishedAt = try? container.decodeIfPresent(Date.self, forKey: .finishedAt)
    }

    var isFinished: Bool { finishedAt != nil }
    var progress: Double {
        chunks.isEmpty ? 0 : Double(completedChunks.count) / Double(chunks.count)
    }

    func category(_ id: UUID) -> ClipCategory? {
        categories.first { $0.id == id }
    }
}
