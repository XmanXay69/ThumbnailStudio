import SwiftUI

/// Turns the measurement into the one line worth saying about it.
extension ThumbLegibility {
    struct Verdict {
        var message: String
        var symbol: String
        var tint: Color
    }

    @MainActor
    static func verdict(for document: ThumbDocument) -> Verdict {
        let facts = report(for: document)

        if facts.textLayerCount == 0 {
            return Verdict(message: "No text on this design — nothing to check for small-size legibility.",
                           symbol: "info.circle",
                           tint: Studio.Palette.textTertiary)
        }

        var parts: [String] = []
        if let pixels = facts.smallestTextPixels {
            parts.append(String(format: "Smallest text is %.0f px tall in the up-next rail", pixels))
        }
        if facts.layersUnderDurationStamp > 0 {
            parts.append(facts.layersUnderDurationStamp == 1
                         ? "one text layer sits under the duration stamp"
                         : "\(facts.layersUnderDurationStamp) text layers sit under the duration stamp")
        }

        if !facts.isReadable {
            parts.append("below the ~\(Int(readablePixels)) px where text stops resolving at a glance")
            return Verdict(message: parts.joined(separator: "; ") + ".",
                           symbol: "exclamationmark.triangle",
                           tint: Studio.Palette.warning)
        }
        if facts.layersUnderDurationStamp > 0 {
            return Verdict(message: parts.joined(separator: "; ") + ".",
                           symbol: "exclamationmark.triangle",
                           tint: Studio.Palette.warning)
        }
        return Verdict(message: parts.joined(separator: "; ") + " — readable at every size above.",
                       symbol: "checkmark.circle",
                       tint: Studio.Palette.success)
    }
}
