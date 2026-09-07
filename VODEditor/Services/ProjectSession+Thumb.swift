import Foundation

/// The VOD app's half of the thumbnail contract: the session already has the
/// document, the undo plumbing and the cutout call, so conformance is free.
extension ProjectSession: ThumbStore {
    /// A held arrow key is one undo step; letting go ends the run so the next
    /// press starts a new one.
    func endUndoRun() { endThumbUndoRun() }
}

/// The frame-grab bridge. ThumbKit's studio asks for frames through
/// `ThumbFrameSource`; here that is the project session plus the editor's
/// player, so the two grab paths behave exactly as they did when the pane
/// reached into both directly.
@MainActor
struct ProjectFrameSource: ThumbFrameSource {
    let session: ProjectSession
    let player: PlayerController?

    var frameSourceDuration: Double { session.project.media?.durationSeconds ?? 0 }

    var playheadTime: Double { player?.currentTime ?? 0 }

    func grabFrameToCanvas(at time: Double) {
        session.grabTimelineFrame(at: time)
    }

    func writeSourceFrame(at time: Double, to destination: URL) async throws {
        try await session.grabSourceFrame(at: time, to: destination)
    }

    func frameGrabDestination(at time: Double) -> URL {
        try? session.project.paths.createDirectories()
        return session.project.paths.thumbnailsDir
            .appendingPathComponent("grab-\(Int(time * 10)).png")
    }

    func addFrameToCanvas(path: String, time: Double) {
        session.addSourceGrabToCanvas(path: path, time: time)
    }

    /// The middle of each of the strongest clip candidates. The middle rather
    /// than the start because a candidate opens on the run-up to the thing,
    /// not the thing.
    var suggestedMoments: [Double] {
        session.shorts
            .sorted { $0.score > $1.score }
            .prefix(6)
            .map { ($0.start + $0.end) / 2 }
    }

    func rankedFrames(around moments: [Double]) async throws -> [RankedFramePick] {
        try? session.project.paths.createDirectories()
        let ranked = try await ThumbnailService.bestFrames(
            source: session.project.sourceURL,
            around: moments,
            into: session.project.paths.thumbnailsDir)
        return ranked.map {
            RankedFramePick(time: $0.time, path: $0.url.path,
                            score: $0.quality.overall,
                            explanation: $0.quality.explanation)
        }
    }
}
