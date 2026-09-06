import Foundation

/// The first three seconds decide whether a short survives the swipe. This
/// reads the cut's opening like a viewer: when does the first word land,
/// how dense is the talk, and where's the payoff — the loudest emphasized
/// moment — relative to the 3-second mark.
enum HookDoctorService {
    struct Report: Equatable {
        var firstWordAt: Double?
        var wordsInFirst3 = 0
        var payoffWord: String?
        var payoffAt: Double?
        var findings: [Finding] = []
    }

    struct Finding: Equatable {
        enum Severity: String { case good, warn, bad }
        var severity: Severity
        var message: String
    }

    /// Words in timeline time with a loudness reading each (0–1, from the
    /// waveform under the word). Pure — the session assembles the inputs.
    static func report(words: [(t: Double, text: String, peak: Double)],
                       totalDuration: Double) -> Report {
        var report = Report()
        let opening = words.filter { $0.t < 10 }.sorted { $0.t < $1.t }

        report.firstWordAt = opening.first?.t
        report.wordsInFirst3 = opening.filter { $0.t < 3 }.count

        // Payoff: the loudest word in the first 8 seconds, with a bonus for
        // written emphasis — a yell beats a murmur, "WHAT!" beats both.
        let candidates = opening.filter { $0.t < 8 && $0.text.count > 1 }
        if let payoff = candidates.max(by: { score($0) < score($1) }), score(payoff) > 0.15 {
            report.payoffWord = payoff.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            report.payoffAt = payoff.t
        }

        // The verdicts, in the order a fix would happen.
        if let first = report.firstWordAt {
            if first > 1.0 {
                report.findings.append(Finding(severity: .bad, message: String(
                    format: "First word lands at %.1fs — trim the opening; the swipe happens before it.", first)))
            } else if first > 0.5 {
                report.findings.append(Finding(severity: .warn, message: String(
                    format: "First word at %.1fs — tight enough, tighter is better.", first)))
            } else {
                report.findings.append(Finding(severity: .good, message: "Talk starts immediately."))
            }
        } else if totalDuration > 3 {
            report.findings.append(Finding(severity: .bad,
                message: "No speech in the opening 10 seconds — a silent open needs a visual reason to stay."))
        }

        if report.firstWordAt != nil {
            if report.wordsInFirst3 < 4 {
                report.findings.append(Finding(severity: .warn, message:
                    "Only \(report.wordsInFirst3) word\(report.wordsInFirst3 == 1 ? "" : "s") in the first 3 seconds — sparse opens read as dead air."))
            } else {
                report.findings.append(Finding(severity: .good,
                    message: "\(report.wordsInFirst3) words in the first 3 seconds — dense open."))
            }
        }

        if let at = report.payoffAt, let word = report.payoffWord {
            if at > 3 {
                report.findings.append(Finding(severity: .warn, message: String(
                    format: "The payoff (\u{201C}%@\u{201D}) lands at %.1fs — after the 3s mark. Consider opening with it and rewinding.", word, at)))
            } else {
                report.findings.append(Finding(severity: .good, message: String(
                    format: "Payoff (\u{201C}%@\u{201D}) inside the first 3 seconds.", word)))
            }
        }
        return report
    }

    private static func score(_ word: (t: Double, text: String, peak: Double)) -> Double {
        var value = word.peak
        if word.text.contains("!") { value += 0.25 }
        if word.text.count >= 4, word.text == word.text.uppercased(),
           word.text.rangeOfCharacter(from: .letters) != nil { value += 0.15 }
        return value
    }
}
