import Foundation

/// Best-of compilations out of work already done. Every accepted clip across
/// every project is sitting on disk with a score, a category and a decision
/// attached — this queries them and hands back a running order.
enum CompilationService {
    struct Entry: Identifiable, Equatable {
        var id: UUID { candidateID }
        var candidateID: UUID
        var projectID: UUID
        var projectName: String
        var sourcePath: String
        var title: String
        var start: Double
        var end: Double
        var score: Double
        var category: String
        var createdAt: Date
        var posted: Bool

        var duration: Double { end - start }
    }

    struct Query: Equatable {
        /// Empty means every category.
        var categories: Set<String> = []
        var since: Date?
        var minimumScore: Double = 0
        /// Cap the running time; 0 is uncapped.
        var maximumMinutes: Double = 10
        var includePosted = true
        var order: Order = .scoreDescending

        enum Order: String, CaseIterable, Identifiable {
            case scoreDescending, chronological, shortestFirst
            var id: String { rawValue }
            var label: String {
                switch self {
                case .scoreDescending: return "Best first"
                case .chronological: return "Oldest first"
                case .shortestFirst: return "Shortest first"
                }
            }
        }

        init() {}
    }

    /// Filters, orders and caps. Pure — the session gathers the entries.
    static func select(_ entries: [Entry], query: Query) -> [Entry] {
        var pool = entries.filter { entry in
            if !query.includePosted, entry.posted { return false }
            if entry.score < query.minimumScore { return false }
            if let since = query.since, entry.createdAt < since { return false }
            if !query.categories.isEmpty, !query.categories.contains(entry.category) { return false }
            return true
        }

        switch query.order {
        case .scoreDescending:
            pool.sort { $0.score > $1.score }
        case .chronological:
            pool.sort { $0.createdAt < $1.createdAt }
        case .shortestFirst:
            pool.sort { $0.duration < $1.duration }
        }

        guard query.maximumMinutes > 0 else { return pool }
        let cap = query.maximumMinutes * 60
        var running = 0.0
        var picked: [Entry] = []
        for entry in pool {
            guard running + entry.duration <= cap else { continue }
            picked.append(entry)
            running += entry.duration
        }
        return picked
    }

    /// The picks as timeline clips, in the order given.
    static func timelineClips(from entries: [Entry]) -> [TimelineClip] {
        entries.map { entry in
            TimelineClip(sourcePath: entry.sourcePath,
                         start: entry.start, end: entry.end,
                         sourceDuration: max(entry.end, entry.end),
                         name: entry.title)
        }
    }

    static func totalDuration(_ entries: [Entry]) -> Double {
        entries.reduce(0) { $0 + $1.duration }
    }

    /// Every category present in the pool, for the picker.
    static func categories(in entries: [Entry]) -> [String] {
        Array(Set(entries.map(\.category))).sorted()
    }
}
