import Foundation

/// Search every project's transcript at once — "find every time I told the
/// story about X" is how callbacks and compilation material get found. The
/// transcripts are already JSON on disk; this reads them once per session
/// and keeps them warm.
enum GlobalSearchService {
    struct Hit: Identifiable, Equatable {
        var id: String { "\(projectID.uuidString)-\(segmentID)" }
        var projectID: UUID
        var projectName: String
        var segmentID: Int
        var time: Double
        var text: String
    }

    /// Case-insensitive substring over the given transcripts. Pure over its
    /// inputs; capped so a one-letter query can't flood the sheet.
    static func search(_ query: String,
                       in sources: [(projectID: UUID, name: String, transcript: Transcript)],
                       limit: Int = 200) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return [] }
        var hits: [Hit] = []
        for source in sources {
            for segment in source.transcript.segments
            where segment.text.localizedCaseInsensitiveContains(needle) {
                hits.append(Hit(projectID: source.projectID, name: source.name,
                                segmentID: segment.id, time: segment.start,
                                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }
}

extension GlobalSearchService.Hit {
    init(projectID: UUID, name: String, segmentID: Int, time: Double, text: String) {
        self.projectID = projectID
        self.projectName = name
        self.segmentID = segmentID
        self.time = time
        self.text = text
    }
}
