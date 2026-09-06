import Foundation

/// What the tuner measured about the source mix.
///
/// Every level is dBFS RMS, measured over the same audio split into the band
/// speech lives in and everything either side of it, and separated into the
/// stretches where whisper heard words and the stretches where it didn't.
struct AudioProfile: Codable, Equatable {
    var measuredAt: Date
    var speechSeconds: Double
    var backgroundSeconds: Double

    /// Level in the 200–3600 Hz speech band while someone is talking.
    var voiceBandSpeechDB: Double
    /// Level in that same band when nobody is. This is the game bleeding into
    /// the voice band — the part a band split can never take away.
    var voiceBandBackgroundDB: Double
    /// Level outside the speech band while you're talking: engine noise,
    /// explosions, music low end, hiss, all sitting under your voice. This is
    /// the part ducking removes.
    var outOfBandSpeechDB: Double
    /// The same, in the gaps.
    var outOfBandBackgroundDB: Double

    /// How far your voice rises above the game in its own band.
    ///
    /// This is the diagnostic: it says how bad the problem is. It is *not* what
    /// tuning improves — nothing in a single mixed stream can separate two
    /// sources sharing a frequency band.
    var voiceToBackgroundDB: Double { voiceBandSpeechDB - voiceBandBackgroundDB }

    /// How far your voice band sits above everything outside it, while you're
    /// talking.
    ///
    /// This is what tuning moves, and by how much is arithmetic rather than
    /// hope: ducking lowers the second term, presence raises the first.
    var clarityDB: Double { voiceBandSpeechDB - outOfBandSpeechDB }

    /// How much of the background sits where ducking can reach it. Negative
    /// means the game is competing inside the speech band, where it can't.
    var duckableDB: Double { outOfBandBackgroundDB - voiceBandBackgroundDB }

    /// Under ~20 seconds of either side there isn't enough to compare.
    var isReliable: Bool { backgroundSeconds >= 20 && speechSeconds >= 20 }

    /// A comfortable margin. Below this the game starts competing with speech;
    /// well above it, tuning has nothing to fix.
    static let comfortableMarginDB: Double = 12

    var verdict: String {
        guard isReliable else {
            return "Not enough of both to compare — needs at least 20 seconds of speech and 20 of gaps."
        }
        let inBand: String
        switch voiceToBackgroundDB {
        case ..<4:
            inBand = "The game is nearly as loud as you are, in the same frequencies your voice uses."
        case 4..<9:
            inBand = "Your voice sits close to the game."
        case 9..<Self.comfortableMarginDB:
            inBand = "Slightly tight, but close to comfortable."
        default:
            inBand = "Your voice sits well clear of the game."
        }

        if duckableDB > 3 {
            return inBand + " Most of the background is outside the speech band, so ducking has plenty to work with."
        } else if duckableDB > -3 {
            return inBand + " The background is spread evenly across the spectrum; ducking helps with about half of it."
        } else {
            return inBand + " Most of the background sits inside the speech band, where nothing here can reach it — that needs fixing at the source, in your stream mixer."
        }
    }
}

/// Loudness of a finished mix, measured so normalization can be applied as one
/// constant gain rather than a moving one.
struct LoudnessMeasurement: Codable, Equatable {
    var integrated: Double
    var truePeak: Double
    var range: Double
    var threshold: Double
    var offset: Double
}

/// How the export treats the audio.
///
/// The knobs map onto exactly one filter each, so what the panel says is what
/// ffmpeg does.
struct AudioTuning: Codable, Equatable {
    var enabled: Bool = false

    /// How far the out-of-band background drops while you're talking. Applied
    /// as a gain envelope, not a compressor, so this is the literal number of
    /// decibels — not a target a detector might undershoot.
    var duckDB: Double = 6

    /// Gain on the 200–3600 Hz band, applied throughout.
    var presenceDB: Double = 2

    /// Normalize the finished mix to a platform loudness target.
    var normalize: Bool = true
    var targetLUFS: Double = -14

    /// Where the speech band is taken to start and end. Fixed rather than
    /// exposed: these are the edges of intelligibility for speech, not taste.
    static let bandLow: Double = 200
    static let bandHigh: Double = 3600

    /// Edge ramp on the ducking envelope. Short enough to catch the first word,
    /// long enough not to click.
    static let rampSeconds: Double = 0.06

    /// Padding either side of a run of words, so the duck opens just before the
    /// first syllable and closes after the last.
    static let speechPadding: Double = 0.25

    var isActive: Bool { enabled && (duckDB > 0 || presenceDB != 0 || normalize) }
    var needsSpeechKey: Bool { enabled && duckDB > 0 }

    static let standard = AudioTuning()

    /// Settings derived from a measurement.
    ///
    /// Both knobs are aimed at `clarityDB` — how far the voice band sits above
    /// everything else while you're talking — because that is the only thing
    /// either of them can actually move. How much ducking is safe depends on
    /// how much background is out of band in the first place: duck 12 dB out of
    /// a mix whose noise is all in the speech band and you've thinned the sound
    /// for nothing.
    static func recommended(for profile: AudioProfile) -> AudioTuning {
        var tuning = AudioTuning()
        tuning.enabled = true
        tuning.normalize = true

        guard profile.isReliable else {
            tuning.duckDB = 4
            tuning.presenceDB = 2
            return tuning
        }

        // Clarity below ~10 dB means the rumble under the voice is competing.
        let shortfall = max(0, 14 - profile.clarityDB)
        tuning.duckDB = min(12, max(2, shortfall * 0.7).rounded())
        // Presence lifts the whole speech band, in-band game audio included, so
        // it stays modest and only grows when the voice is genuinely buried.
        let inBandShortfall = max(0, AudioProfile.comfortableMarginDB - profile.voiceToBackgroundDB)
        tuning.presenceDB = min(4, (inBandShortfall / 3).rounded())
        return tuning
    }
}

/// Before-and-after from a rendered sample, so the settings can be checked
/// rather than trusted.
struct AudioTuningPreview: Equatable {
    var sampleStart: Double
    var sampleDuration: Double
    var before: AudioProfile
    var after: AudioProfile

    /// What tuning moved: the voice band's margin over everything outside it
    /// while you're talking.
    var improvementDB: Double { after.clarityDB - before.clarityDB }

    /// What it didn't, and can't. Should come out near zero — if it doesn't,
    /// something in the chain is squashing dynamics rather than rebalancing.
    var inBandChangeDB: Double { after.voiceToBackgroundDB - before.voiceToBackgroundDB }
}
