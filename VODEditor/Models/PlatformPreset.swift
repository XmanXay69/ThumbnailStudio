import Foundation

/// One destination the portrait master ships to. The master is rendered once;
/// every platform file is derived from it — a fast remux for the portrait
/// platforms, a blurred-fill pillarbox re-encode for the landscape one.
struct PlatformPreset: Identifiable, Equatable {
    enum Kind: Equatable {
        /// The 1080×1920 master as-is (trimmed if the platform caps length).
        case portrait
        /// 1920×1080: the portrait frame centred over a blurred blow-up of
        /// itself — the standard look for vertical clips on YouTube proper.
        case landscapeBlur
    }

    let name: String
    let label: String
    let kind: Kind
    /// The platform's hard length cap in seconds; nil = no cap.
    let maxSeconds: Double?

    var id: String { name }

    static let all: [PlatformPreset] = [
        PlatformPreset(name: "shorts", label: "YouTube Shorts", kind: .portrait, maxSeconds: 180),
        PlatformPreset(name: "reels", label: "Instagram Reels", kind: .portrait, maxSeconds: 90),
        PlatformPreset(name: "tiktok", label: "TikTok", kind: .portrait, maxSeconds: 600),
        PlatformPreset(name: "youtube", label: "YouTube (16:9)", kind: .landscapeBlur, maxSeconds: nil),
    ]

    /// One planned output file.
    struct Planned: Equatable {
        let preset: PlatformPreset
        /// Set when the platform's cap forces a trim; nil ships full length.
        let trimmedTo: Double?
    }

    /// What a master of this duration becomes on each platform. A file is
    /// trimmed only when the cap demands it — never padded, never stretched.
    static func plan(duration: Double) -> [Planned] {
        all.map { preset in
            let trim = preset.maxSeconds.flatMap { cap in
                duration > cap + 0.01 ? cap : nil
            }
            return Planned(preset: preset, trimmedTo: trim)
        }
    }
}
