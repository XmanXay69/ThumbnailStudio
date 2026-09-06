import Foundation

/// Running bits, found rather than remembered. Global search answers "where
/// did I say X" when you already know X — this goes looking on its own,
/// finding phrases that recur across separate VODs. Told three times is a
/// series; told once is a Tuesday.
enum RecurringBitService {
    struct Occurrence: Identifiable, Equatable {
        var id: String { "\(projectID)-\(segmentID)" }
        var projectID: UUID
        var projectName: String
        var segmentID: Int
        var time: Double
        var line: String
    }

    struct Bit: Identifiable, Equatable {
        var id: String { phrase }
        var phrase: String
        var occurrences: [Occurrence]
        /// How many separate VODs it turned up in — a bit told twice in one
        /// stream is a stutter, twice across two streams is a running joke.
        var projectCount: Int
        var score: Double
    }

    /// Words too common to carry meaning. Deliberately short — over-filtering
    /// throws away the gaming vocabulary that makes a bit findable.
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "so", "then", "that", "this",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "them",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "as",
        "my", "your", "his", "its", "our", "their", "just", "like", "gonna",
        "yeah", "okay", "oh", "uh", "um", "know", "what", "not", "no", "yes",
    ]

    /// Normalizes a line into comparable word tokens.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    /// Overlapping n-word phrases, skipping ones that are mostly filler.
    static func shingles(_ text: String, size: Int = 4) -> [String] {
        let words = tokens(text)
        guard words.count >= size else { return [] }
        var out: [String] = []
        for start in 0...(words.count - size) {
            let window = Array(words[start..<(start + size)])
            let meaningful = window.filter { !stopWords.contains($0) }
            // At least half the window has to carry meaning, or "and then i
            // was like" becomes everyone's top bit.
            guard meaningful.count * 2 >= size else { continue }
            out.append(window.joined(separator: " "))
        }
        return out
    }

    /// Phrases appearing in two or more separate projects, ranked by how many
    /// projects they span and how distinctive the wording is.
    static func find(in sources: [(projectID: UUID, name: String, transcript: Transcript)],
                     phraseSize: Int = 4,
                     minimumProjects: Int = 2,
                     limit: Int = 40) -> [Bit] {
        var hits: [String: [Occurrence]] = [:]
        for source in sources {
            // One occurrence per phrase per project keeps a repeated line
            // inside a single stream from inflating the count.
            var seenHere = Set<String>()
            for segment in source.transcript.segments {
                for phrase in shingles(segment.text, size: phraseSize)
                where seenHere.insert(phrase).inserted {
                    hits[phrase, default: []].append(Occurrence(
                        projectID: source.projectID, projectName: source.name,
                        segmentID: segment.id, time: segment.start,
                        line: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }

        var bits: [Bit] = []
        for (phrase, occurrences) in hits {
            let projects = Set(occurrences.map(\.projectID)).count
            guard projects >= minimumProjects else { continue }
            let distinctive = Double(
                phrase.split(separator: " ").filter { !stopWords.contains(String($0)) }.count)
            bits.append(Bit(phrase: phrase,
                            occurrences: occurrences.sorted { $0.time < $1.time },
                            projectCount: projects,
                            score: Double(projects) * 2 + distinctive))
        }

        // One told bit produces a dozen overlapping windows, and they aren't
        // substrings of each other ("people keep running into" / "keep
        // running into me"). What actually identifies them as one bit is
        // that they point at the same lines — so dedupe on the occurrences,
        // not the wording.
        let ranked = bits.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.phrase < $1.phrase
        }
        var kept: [Bit] = []
        var claimed = Set<String>()
        for bit in ranked {
            let ids = Set(bit.occurrences.map(\.id))
            let overlap = ids.intersection(claimed).count
            // More than half its sightings already explained by a stronger
            // phrase means this is the same bit said another way.
            if overlap * 2 > ids.count { continue }
            kept.append(bit)
            claimed.formUnion(ids)
            if kept.count >= limit { break }
        }
        return kept
    }
}
