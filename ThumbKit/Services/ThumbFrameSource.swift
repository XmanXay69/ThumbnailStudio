import Foundation

/// Where the studio can get video frames from, when there is any video at all.
/// The VOD app supplies a project session plus its player; the standalone app
/// supplies nothing and the frame-grab affordances simply don't appear.
///
/// This is the whole of what `ThumbnailStudioPane` used to reach into
/// `ProjectSession` and `PlayerController` for.
@MainActor
protocol ThumbFrameSource {
    /// Length of the scrubbable source, in seconds. Zero means "nothing to
    /// scrub" and hides the frame picker.
    var frameSourceDuration: Double { get }

    /// Where the host app's own playhead is sitting right now.
    var playheadTime: Double { get }

    /// "Frame at playhead": grab through whatever the host is previewing and
    /// drop the result on the canvas. Errors surface through the store's
    /// `thumbStudioError`, exactly as before.
    func grabFrameToCanvas(at time: Double)

    /// Writes the raw source frame at `time` to `destination` — used for the
    /// picker's live preview and for its final grab.
    func writeSourceFrame(at time: Double, to destination: URL) async throws

    /// A place to write a picked frame before it becomes a layer. The host
    /// creates any directories it needs.
    func frameGrabDestination(at time: Double) -> URL

    /// Adds an already-written image file to the canvas as a layer.
    func addFrameToCanvas(path: String, time: Double)
}
