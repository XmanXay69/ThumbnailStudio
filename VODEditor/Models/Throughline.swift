import Foundation

/// A run of related moments — a running bit, a multi-part story, an arc that
/// pays off later. Used so the long-form pass doesn't select one beat of a
/// three-part joke and drop the setup.
struct Throughline: Codable, Identifiable, Equatable {
    struct Beat: Codable, Equatable {
        var start: Double
        var end: Double
        var why: String

        var duration: Double { max(0, end - start) }
    }

    var id: UUID = UUID()
    var title: String
    var summary: String
    var kind: Kind
    /// How strongly the model believes these moments belong together, 0…1.
    var strength: Double
    var beats: [Beat]

    enum Kind: String, Codable {
        case runningBit = "running_bit"
        case story
        case arc

        var label: String {
            switch self {
            case .runningBit: return "Running bit"
            case .story: return "Story"
            case .arc: return "Arc"
            }
        }
    }

    var span: ClosedRange<Double>? {
        guard let first = beats.map(\.start).min(), let last = beats.map(\.end).max(),
              last > first else { return nil }
        return first...last
    }

    func contains(_ time: Double) -> Bool {
        beats.contains { time >= $0.start && time < $0.end }
    }
}
