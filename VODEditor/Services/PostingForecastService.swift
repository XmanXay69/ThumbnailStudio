import Foundation

/// The dashboard's forward look: how much exported-but-unposted material
/// each client has, how long it lasts at their cadence, and the two
/// failure modes worth flagging — dry spells and same-day dumps.
enum PostingForecastService {
    struct Runway: Equatable {
        var clientName: String
        var readyCount = 0
        var postedCount = 0
        var postsPerWeek: Double = 7
        /// Today + ready ÷ cadence. nil when nothing is ready.
        var runwayEnds: Date?
        var lastPostedAt: Date?
        var warnings: [String] = []
    }

    /// One item per exported candidate across every project.
    struct Item: Equatable {
        var clientName: String
        var postedAt: Date?

        init(clientName: String, postedAt: Date? = nil) {
            self.clientName = clientName
            self.postedAt = postedAt
        }
    }

    static func forecast(items: [Item], cadences: [String: Double],
                         now: Date = Date()) -> [Runway] {
        let calendar = Calendar.current
        return Dictionary(grouping: items, by: \.clientName)
            .map { name, group in
                var runway = Runway(clientName: name)
                runway.postsPerWeek = max(0.5, cadences[name] ?? 7)
                runway.readyCount = group.filter { $0.postedAt == nil }.count
                let posted = group.compactMap(\.postedAt).sorted()
                runway.postedCount = posted.count
                runway.lastPostedAt = posted.last

                if runway.readyCount > 0 {
                    let days = Double(runway.readyCount) / (runway.postsPerWeek / 7)
                    runway.runwayEnds = calendar.date(byAdding: .hour,
                                                      value: Int(days * 24), to: now)
                }

                // Dry spell: silence for more than two cadence intervals.
                if let last = posted.last {
                    let interval = 7 / runway.postsPerWeek * 86400
                    let silence = now.timeIntervalSince(last)
                    if silence > interval * 2, runway.readyCount > 0 {
                        runway.warnings.append(String(
                            format: "Quiet for %.0f days with %d clip(s) ready",
                            silence / 86400, runway.readyCount))
                    }
                }
                // Dump: three or more posts on one calendar day.
                let byDay = Dictionary(grouping: posted) {
                    calendar.startOfDay(for: $0)
                }
                if let (day, dump) = byDay.max(by: { $0.value.count < $1.value.count }),
                   dump.count >= 3 {
                    runway.warnings.append(
                        "\(dump.count) posts on \(day.formatted(date: .abbreviated, time: .omitted)) — spacing them out reads better")
                }
                if runway.readyCount == 0, runway.postedCount > 0 {
                    runway.warnings.append("Out of material — nothing exported and unposted")
                }
                return runway
            }
            .sorted { $0.clientName < $1.clientName }
    }
}
