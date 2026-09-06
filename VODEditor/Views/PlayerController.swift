import AVFoundation
import AVKit
import SwiftUI

/// Wraps AVPlayer and publishes the playhead. Everything else in the review UI
/// — waveform, transcript sync — reads `currentTime` from here.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var rate: Float = 1.0 {
        didSet { if isPlaying { player.rate = rate } }
    }

    let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    init() {
        // 30 Hz is enough to keep the playhead and caption highlight smooth
        // without flooding the main actor on a multi-hour asset.
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.currentTime = time.seconds
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            Task { @MainActor in self.isPlaying = player.rate != 0 }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(url: URL) {
        load(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]))
    }

    /// Also used for the long-form AVComposition, so the player previews the
    /// assembled cut rather than the raw source.
    func load(asset: AVAsset) {
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        currentTime = 0

        Task {
            let loaded = try? await asset.load(.duration)
            await MainActor.run {
                self.duration = loaded?.seconds ?? 0
            }
        }
    }

    /// For the clip editor's preview, whose item carries an AVAudioMix for
    /// the music gain.
    func load(item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        currentTime = 0
        Task {
            let loaded = try? await item.asset.load(.duration)
            await MainActor.run { self.duration = loaded?.seconds ?? 0 }
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            player.rate = rate
        }
    }

    func play() { player.rate = rate }

    func pause() { player.pause() }

    /// `precise` is used for transcript clicks, where landing on the right word
    /// matters more than latency. Scrubbing uses the loose path — exact seeking
    /// on a 4-hour h264 file with sparse keyframes is noticeably slow.
    func seek(to seconds: Double, precise: Bool = false) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        if precise {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    func skip(_ delta: Double) {
        seek(to: currentTime + delta)
    }
}

/// AVPlayerView rather than SwiftUI's VideoPlayer so the native inline controls
/// can be kept while the surrounding chrome stays custom.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
