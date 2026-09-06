import Foundation

/// The VOD app's half of the thumbnail contract: the session already has the
/// document, the undo plumbing and the cutout call, so conformance is free.
extension ProjectSession: ThumbStore {}

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
}
