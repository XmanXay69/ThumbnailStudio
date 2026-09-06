import Foundation

/// The check you'd otherwise do by uploading and looking. Everything here is
/// arithmetic over the document — no rendering, so it runs in a blink and
/// can sit in front of the export button.
enum PreflightService {
    enum Severity: String {
        case blocker, warning, note
    }

    struct Finding: Identifiable, Equatable {
        var id: String { "\(severity.rawValue)-\(message)" }
        var severity: Severity
        var message: String
        /// Where to jump to, when the finding has a place on the timeline.
        var at: Double?
    }

    /// Platform chrome, as fractions of a 9:16 frame. TikTok is the tightest,
    /// so a caption clear of TikTok is clear everywhere.
    struct PlatformSafeArea {
        var name: String
        /// Fraction of frame height covered from the bottom.
        var bottom: Double
        /// Fraction of frame width covered from the right.
        var right: Double

        static let tiktok = PlatformSafeArea(name: "TikTok", bottom: 0.17, right: 0.13)
        static let reels = PlatformSafeArea(name: "Reels", bottom: 0.15, right: 0.12)
        static let shorts = PlatformSafeArea(name: "Shorts", bottom: 0.12, right: 0.11)
        static let all = [tiktok, reels, shorts]
    }

    /// Runs every check that doesn't need a decoded frame.
    /// `hasThumbnail` and `audioProfile` come from the session.
    static func run(edit: ClipEdit,
                    captionStyle: CaptionStyle,
                    captionsBurned: Bool,
                    missingMedia: Int,
                    hasThumbnail: Bool,
                    audioProfile: AudioProfile?,
                    renderHeight: Int = 1920) -> [Finding] {
        var findings: [Finding] = []

        if missingMedia > 0 {
            findings.append(Finding(
                severity: .blocker,
                message: "\(missingMedia) media file\(missingMedia == 1 ? " is" : "s are") offline — those clips export as black. Relink before exporting.",
                at: nil))
        }
        if edit.clips.isEmpty {
            findings.append(Finding(severity: .blocker,
                                    message: "Nothing on the timeline.", at: nil))
        }

        // Captions under platform UI. The caption band sits `marginVertical`
        // pixels off its edge; compare that against each platform's chrome.
        if captionsBurned, edit.aspect == .portrait {
            let marginFraction = Double(captionStyle.marginVertical) / Double(renderHeight)
            let bandFraction = Double(captionStyle.fontSize) * 2.2 / Double(renderHeight)
            if captionStyle.position == .bottom {
                for platform in PlatformSafeArea.all where marginFraction < platform.bottom {
                    findings.append(Finding(
                        severity: platform.name == "TikTok" ? .warning : .note,
                        message: "Captions sit \(Int(marginFraction * 100))% up from the bottom — \(platform.name) covers the bottom \(Int(platform.bottom * 100))%. Raise the margin to about \(Int(platform.bottom * Double(renderHeight)) + 40)px.",
                        at: nil))
                }
            }
            if marginFraction + bandFraction > 0.95 {
                findings.append(Finding(severity: .warning,
                                        message: "Captions run off the top of the frame at this margin and size.",
                                        at: nil))
            }
            if captionStyle.maxCharactersPerLine > 32 {
                findings.append(Finding(
                    severity: .note,
                    message: "\(captionStyle.maxCharactersPerLine) characters per line is long for vertical — 20 to 26 reads better on a phone.",
                    at: nil))
            }
        }

        // Socials block against the same chrome.
        if edit.showHandles, edit.aspect == .portrait {
            let handleFraction = edit.handleY
            if handleFraction > 1 - PlatformSafeArea.tiktok.bottom {
                findings.append(Finding(
                    severity: .warning,
                    message: "The socials block sits inside TikTok's bottom UI — move it up.",
                    at: nil))
            }
        }

        // Clips too short to register, and gaps in timed text.
        var cursor: Double = 0
        for clip in edit.clips {
            let width = clip.effectiveDuration
            if width < 0.7 {
                findings.append(Finding(
                    severity: .warning,
                    message: String(format: "A %.1fs clip is too short to read as anything but a flicker.", width),
                    at: cursor))
            }
            cursor += width
        }

        let total = edit.totalDuration
        if total > 0, total < 3 {
            findings.append(Finding(severity: .warning,
                                    message: String(format: "The whole cut is %.1fs — most platforms bury anything under 3s.", total),
                                    at: nil))
        }

        // Text and SFX past the end of the cut never play.
        for item in edit.textItems where item.isTimed && item.startTime >= total {
            findings.append(Finding(severity: .note,
                                    message: "Text “\(item.text.prefix(24))” starts after the cut ends.",
                                    at: item.startTime))
        }
        for event in edit.sfxEvents where event.startTime >= total {
            findings.append(Finding(severity: .note,
                                    message: "Sound effect “\(event.displayName)” fires after the cut ends.",
                                    at: event.startTime))
        }

        // The mix. The tuner measures dBFS in and out of the speech band —
        // not LUFS — so this reports what was actually measured rather than
        // inventing a loudness number.
        if let profile = audioProfile, profile.isReliable {
            if profile.voiceToBackgroundDB < 6 {
                findings.append(Finding(
                    severity: .warning,
                    message: String(format: "Your voice sits only %.1f dB above the game in its own band — it will fight the mix on a phone speaker.",
                                    profile.voiceToBackgroundDB),
                    at: nil))
            }
            if profile.clarityDB < 4 {
                findings.append(Finding(
                    severity: .note,
                    message: String(format: "Clarity is %.1f dB; Audio tuning can lift it before you export.",
                                    profile.clarityDB),
                    at: nil))
            }
        } else {
            findings.append(Finding(
                severity: .note,
                message: audioProfile == nil
                    ? "The mix hasn't been measured — run Audio tuning to see how your voice sits against the game."
                    : "The mix measurement isn't reliable yet (needs 20s each of speech and gaps).",
                at: nil))
        }

        if !hasThumbnail {
            findings.append(Finding(severity: .note,
                                    message: "No thumbnail built for this project yet.",
                                    at: nil))
        }

        return findings
    }

    static func blockers(_ findings: [Finding]) -> [Finding] {
        findings.filter { $0.severity == .blocker }
    }
}
