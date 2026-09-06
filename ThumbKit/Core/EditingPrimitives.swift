import Foundation

/// Slider streams and arrow-key nudges fire dozens of mutations a second; each
/// one is not an undo step. The same action name landing inside the window
/// folds into the entry already registered. Pure so the policy is testable.
enum UndoCoalescing {
    static func shouldCoalesce(action: String?, lastAction: String?,
                               lastAt: Date, now: Date) -> Bool {
        guard let action, action == lastAction else { return false }
        return now.timeIntervalSince(lastAt) < 0.8
    }
}

/// Snapping: the nearest target within reach, or nothing. Pure so the feel
/// is testable.
enum TimelineSnap {
    static func snapped(_ value: Double, to targets: [Double], threshold: Double) -> Double? {
        guard let nearest = targets.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) <= threshold else { return nil }
        return nearest
    }
}

extension TimeInterval {
    /// H:MM:SS for durations and playhead readouts.
    var timecode: String {
        guard isFinite, self >= 0 else { return "0:00:00" }
        let total = Int(self)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    var shortTimecode: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
