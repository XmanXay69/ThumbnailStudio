import AVFoundation
import CoreGraphics
import Foundation

/// Builds the editor timeline into an AVComposition for the preview player.
///
/// Unlike the long-form preview, clips here can come from *different files* —
/// the seeded candidate reads the project source, added clips read whatever
/// the user picked. A video composition renders every clip through the same
/// cover-fit × zoom × pan maths the export runs (at the edit's own aspect),
/// applies per-clip speed by scaling the inserted range (varispeed in the
/// preview; pitch-preserved on export), holds freeze frames, and composites
/// overlay clips at their rects — un-keyed: chroma happens in ffmpeg, so the
/// preview shows the raw footage where the export will show it keyed. Music,
/// clip gains, overlay audio and the voice-over all ride one AVAudioMix.
enum ClipEditPreview {
    static func build(_ edit: ClipEdit) async throws
        -> (AVMutableComposition, AVMutableVideoComposition?, AVAudioMix?) {
        let renderSize = CGSize(width: edit.aspect.width, height: edit.aspect.height)
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        let audio = composition.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid)
        // Everything runs on exact 600-timescale ticks. Instruction ranges
        // built from Double seconds can land one tick apart — and a video
        // composition whose instructions don't tile perfectly makes
        // AVFoundation render nothing at all (a black player, not a glitch).
        var cursor = CMTime(value: 0, timescale: 600)
        var mixInputs: [AVMutableAudioMixInputParameters] = []

        struct MainSegment {
            let startTick: Int64
            let endTick: Int64
            let transform: CGAffineTransform
            /// For clips with motion keyframes: the framing at any effective
            /// second within the clip. nil for static clips.
            let transformAt: ((Double) -> CGAffineTransform)?
            /// Keyframe ticks (absolute) where instructions must split so
            /// each ramp segment stays linear.
            let motionTicks: [Int64]
        }
        var mainSegments: [MainSegment] = []
        var clipVolumes: [(at: CMTime, gain: Double)] = []

        for clip in edit.clips {
            let effective = CMTime(seconds: max(0.05, clip.effectiveDuration),
                                   preferredTimescale: 600)
            let asset = AVURLAsset(url: clip.url,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let sourceTrack = try? await asset.loadTracks(withMediaType: .video).first
            var transform = CGAffineTransform.identity
            var transformAt: ((Double) -> CGAffineTransform)?
            var motionTicks: [Int64] = []
            if let sourceTrack {
                let natural = (try? await sourceTrack.load(.naturalSize)) ?? renderSize
                let preferred = (try? await sourceTrack.load(.preferredTransform)) ?? .identity
                transform = self.transform(for: clip, naturalSize: natural,
                                           preferredTransform: preferred,
                                           renderSize: renderSize)
                if clip.hasMotion, !clip.isFreeze {
                    let captured = clip
                    transformAt = { t in
                        let m = captured.motionAt(t)
                        return Self.transform(zoom: m.zoom, centerX: m.cx, centerY: m.cy,
                                              naturalSize: natural,
                                              preferredTransform: preferred,
                                              renderSize: renderSize)
                    }
                    let base = cursor.value
                    let span = effective.value
                    motionTicks = clip.motionTimes
                        .map { base + Int64(($0 * 600).rounded()) }
                        .filter { $0 > base && $0 < base + span }
                }
            }

            if clip.isFreeze {
                // A sliver of source stretched across the hold; silence under it.
                if let sourceTrack, let video {
                    let sliver = CMTimeRange(
                        start: CMTime(seconds: clip.start, preferredTimescale: 600),
                        duration: CMTime(seconds: 0.1, preferredTimescale: 600))
                    try? video.insertTimeRange(sliver, of: sourceTrack, at: cursor)
                    video.scaleTimeRange(CMTimeRange(start: cursor, duration: sliver.duration),
                                         toDuration: effective)
                }
                audio?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: effective))
            } else {
                let range = CMTimeRange(
                    start: CMTime(seconds: clip.start, preferredTimescale: 600),
                    duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
                if let sourceTrack, let video {
                    try? video.insertTimeRange(range, of: sourceTrack, at: cursor)
                    if abs(clip.clampedSpeed - 1) > 0.001 {
                        video.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration),
                                             toDuration: effective)
                    }
                }
                if let track = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? audio?.insertTimeRange(range, of: track, at: cursor)
                    if abs(clip.clampedSpeed - 1) > 0.001 {
                        audio?.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration),
                                              toDuration: effective)
                    }
                }
            }
            clipVolumes.append((cursor, clip.isFreeze ? 0 : clip.gainDB))
            mainSegments.append(MainSegment(startTick: cursor.value,
                                            endTick: (cursor + effective).value,
                                            transform: transform,
                                            transformAt: transformAt,
                                            motionTicks: motionTicks))
            cursor = cursor + effective
        }
        let total = cursor.seconds

        if let audio, total > 0 {
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            for entry in clipVolumes {
                parameters.setVolume(Float(pow(10, entry.gain / 20)), at: entry.at)
            }
            mixInputs.append(parameters)
        }

        // Overlay clips: their own tracks, frontmost in every instruction that
        // intersects their window. Chroma is not previewable here — ffmpeg
        // keys it on export; the preview shows the raw footage in place.
        struct OverlayTrack {
            let clip: OverlayClip
            let track: AVMutableCompositionTrack
            let transform: CGAffineTransform
            let startTick: Int64
            let endTick: Int64
            /// The overlay's own source height, needed to convert its
            /// transform into Core Image's coordinate space.
            let sourceHeight: CGFloat
        }
        var overlayTracks: [OverlayTrack] = []
        for overlay in edit.overlayClips where total > 0 && overlay.startTime < total {
            let asset = AVURLAsset(url: overlay.url,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let playable = min(overlay.duration, total - overlay.startTime)
            let range = CMTimeRange(
                start: CMTime(seconds: overlay.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.1, playable), preferredTimescale: 600))
            let at = CMTime(seconds: overlay.startTime, preferredTimescale: 600)
            let startTick = at.value
            let endTick = min((at + range.duration).value, cursor.value)
            try? track.insertTimeRange(range, of: sourceTrack, at: at)

            let natural = (try? await sourceTrack.load(.naturalSize)) ?? renderSize
            let preferred = (try? await sourceTrack.load(.preferredTransform)) ?? .identity
            let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
            let width = max(1, abs(oriented.width))
            let scale = overlay.rect.width * renderSize.width / width
            let transform = preferred
                .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: overlay.rect.x * renderSize.width,
                                                 y: overlay.rect.y * renderSize.height))
            overlayTracks.append(OverlayTrack(clip: overlay, track: track, transform: transform,
                                              startTick: startTick, endTick: endTick,
                                              sourceHeight: abs(oriented.height)))

            if !overlay.muted,
               let audioSource = try? await asset.loadTracks(withMediaType: .audio).first,
               let overlayAudio = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? overlayAudio.insertTimeRange(range, of: audioSource, at: at)
                let parameters = AVMutableAudioMixInputParameters(track: overlayAudio)
                parameters.setVolume(Float(pow(10, overlay.gainDB / 20)), at: .zero)
                mixInputs.append(parameters)
            }
        }

        // Instructions partition the timeline at every clip and overlay
        // boundary, so an overlay appears for exactly its window.
        var videoComposition: AVMutableVideoComposition?
        if let video, total > 0 {
            var boundaries: Set<Int64> = [0, cursor.value]
            for segment in mainSegments {
                boundaries.insert(segment.startTick)
                for tick in segment.motionTicks { boundaries.insert(tick) }
            }
            for overlay in overlayTracks {
                boundaries.insert(min(max(0, overlay.startTick), cursor.value))
                boundaries.insert(min(overlay.endTick, cursor.value))
            }
            let ticks = boundaries.sorted()

            // Overlays need chroma keying, which the built-in compositor
            // cannot do (it ignores per-pixel alpha entirely), so those edits
            // render through the custom Core Image compositor. Without
            // overlays the stock path is kept — it's cheaper and proven.
            let needsCustomCompositor = !overlayTracks.isEmpty
            var instructions: [AVVideoCompositionInstructionProtocol] = []
            for (from, to) in zip(ticks, ticks.dropFirst()) {
                let range = CMTimeRange(start: CMTime(value: from, timescale: 600),
                                        duration: CMTime(value: to - from, timescale: 600))
                let segment = mainSegments.first { $0.startTick <= from && $0.endTick >= to }
                let visibleOverlays = overlayTracks.filter { $0.startTick <= from && $0.endTick >= to }

                // A motion clip's framing at this instruction's edges, in the
                // clip's own effective seconds.
                var rampStart: CGAffineTransform?
                var rampEnd: CGAffineTransform?
                if let segment, let transformAt = segment.transformAt {
                    let local = { (tick: Int64) in Double(tick - segment.startTick) / 600 }
                    rampStart = transformAt(local(from))
                    rampEnd = transformAt(local(to))
                }

                if needsCustomCompositor {
                    // Back to front: the cut first, overlays on top.
                    var layers: [EditVideoCompositor.Layer] = []
                    if let segment {
                        layers.append(.init(trackID: video.trackID,
                                            transform: rampStart ?? segment.transform,
                                            endTransform: rampEnd, chroma: nil))
                    }
                    for overlay in visibleOverlays {
                        layers.append(.init(
                            trackID: overlay.track.trackID,
                            transform: overlay.transform,
                            endTransform: nil,
                            chroma: overlay.clip.chromaEnabled
                                ? EditVideoCompositor.Chroma(hex: overlay.clip.chromaHex,
                                                             similarity: overlay.clip.chromaSimilarity,
                                                             blend: overlay.clip.chromaBlend)
                                : nil))
                    }
                    instructions.append(EditVideoCompositor.Instruction(timeRange: range, layers: layers))
                } else {
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = range
                    if let segment {
                        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
                        if let rampStart, let rampEnd, rampStart != rampEnd {
                            layer.setTransformRamp(fromStart: rampStart, toEnd: rampEnd,
                                                   timeRange: range)
                        } else {
                            layer.setTransform(rampStart ?? segment.transform, at: range.start)
                        }
                        instruction.layerInstructions = [layer]
                    }
                    instructions.append(instruction)
                }
            }
            if !instructions.isEmpty {
                let built = AVMutableVideoComposition()
                built.renderSize = renderSize
                built.frameDuration = CMTime(value: 1, timescale: 30)
                if needsCustomCompositor {
                    built.customVideoCompositorClass = EditVideoCompositor.self
                }
                built.instructions = instructions
                videoComposition = built
            }
        }

        // The voice-over sits under the cut from its start point.
        if let voURL = edit.voiceoverURL, total > 0,
           FileManager.default.fileExists(atPath: voURL.path) {
            let asset = AVURLAsset(url: voURL)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let duration = try? await asset.load(.duration), duration.seconds > 0.1,
               let bed = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid) {
                let at = CMTime(seconds: min(edit.voiceoverStart, total), preferredTimescale: 600)
                let playable = CMTime(seconds: min(duration.seconds, total - at.seconds),
                                      preferredTimescale: 600)
                try? bed.insertTimeRange(CMTimeRange(start: .zero, duration: playable),
                                         of: track, at: at)
                let parameters = AVMutableAudioMixInputParameters(track: bed)
                parameters.setVolume(Float(pow(10, edit.voiceoverGainDB / 20)), at: .zero)
                mixInputs.append(parameters)
            }
        }

        // Sound effects: one short track each, at their fire time.
        for event in edit.sfxEvents where total > 0 && event.startTime < total
            && FileManager.default.fileExists(atPath: event.path) {
            let asset = AVURLAsset(url: event.url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0.02,
                  let bed = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let at = CMTime(seconds: event.startTime, preferredTimescale: 600)
            let playable = CMTime(seconds: min(duration.seconds, total - event.startTime),
                                  preferredTimescale: 600)
            try? bed.insertTimeRange(CMTimeRange(start: .zero, duration: playable),
                                     of: track, at: at)
            let parameters = AVMutableAudioMixInputParameters(track: bed)
            parameters.setVolume(Float(pow(10, event.gainDB / 20)), at: .zero)
            mixInputs.append(parameters)
        }

        // Music underneath, looped to cover the cut, at the gain the export
        // will use.
        if let musicURL = edit.musicURL, cursor.seconds > 0,
           FileManager.default.fileExists(atPath: musicURL.path) {
            let asset = AVURLAsset(url: musicURL)
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let duration = try? await asset.load(.duration), duration.seconds > 0.2,
               let bed = composition.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid) {
                var position = CMTime.zero
                var loops = 0
                while position < cursor, loops < 200 {
                    let remaining = cursor - position
                    let piece = CMTimeRange(start: .zero, duration: min(duration, remaining))
                    try? bed.insertTimeRange(piece, of: track, at: position)
                    position = position + piece.duration
                    loops += 1
                }
                let parameters = AVMutableAudioMixInputParameters(track: bed)
                parameters.setVolume(Float(pow(10, edit.musicGainDB / 20)), at: .zero)
                mixInputs.append(parameters)
            }
        }

        var mix: AVAudioMix?
        if !mixInputs.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = mixInputs
            mix = audioMix
        }

        return (composition, videoComposition, mix)
    }

    /// Maps a source track into the render frame: orientation fix, then
    /// cover-fit scaled up by the clip's zoom, then the pan choosing which
    /// part of the spare area stays. Same maths as the export's
    /// `clipPieceVideoFilter`, in transform form.
    static func transform(for clip: TimelineClip, naturalSize: CGSize,
                          preferredTransform: CGAffineTransform,
                          renderSize: CGSize) -> CGAffineTransform {
        transform(zoom: clip.zoom, centerX: clip.centerX, centerY: clip.centerY,
                  naturalSize: naturalSize, preferredTransform: preferredTransform,
                  renderSize: renderSize)
    }

    /// The same framing from explicit values — what motion keyframes sample.
    static func transform(zoom: Double, centerX: Double, centerY: Double,
                          naturalSize: CGSize,
                          preferredTransform: CGAffineTransform,
                          renderSize: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(oriented.width)
        let height = abs(oriented.height)
        guard width > 0, height > 0 else { return .identity }

        let clamped = min(4, max(1, zoom))
        let scale = max(renderSize.width / width, renderSize.height / height) * clamped
        let panX = -(width * scale - renderSize.width) * min(1, max(0, centerX))
        let panY = -(height * scale - renderSize.height) * min(1, max(0, centerY))

        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: panX, y: panY))
    }
}
