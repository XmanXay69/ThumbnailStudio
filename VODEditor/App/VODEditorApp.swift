import SwiftUI

@main
struct VODEditorApp: App {
    @StateObject private var store = ProjectStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Paths.ensureAppDirectories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                // One control language: every native toggle, picker, slider
                // and prominent button speaks the accent — no more blue
                // system switches fighting the purple.
                .tint(Theme.accent)
                .frame(minWidth: 1200, minHeight: 760)
                .background(Theme.background)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open VOD…") {
                    NotificationCenter.default.post(name: .requestOpenVOD, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // The thumbnail tab's layer verbs, minus the design-file items —
            // this app has its own File menu. Every one of these is disabled
            // unless the studio is on screen.
            ThumbLayerCommands()
        }
    }
}

extension Notification.Name {
    static let requestOpenVOD = Notification.Name("requestOpenVOD")
}

/// `VODEditor.app/Contents/MacOS/VODEditor --ingest /path/to/vod.mp4` runs the
/// whole pipeline unattended and reports to stdout, so ingest can be exercised
/// against a real multi-hour VOD without driving the UI by hand.
enum LaunchOptions {
    static var ingestPath: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ingest"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `--link <url>` downloads a VOD from a link, then ingests it.
    static var linkURL: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--link"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static var isHeadlessRun: Bool { ingestPath != nil || linkURL != nil }

    /// Only `--ingest` ends the process when the pipeline finishes. `--link` may
    /// have more items queued behind this one, and the download queue owns when
    /// the run is over.
    static var exitsAfterIngest: Bool { ingestPath != nil }

    private static func value(for flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `--export-shorts <dir> [--export-count N]` renders the top-scoring
    /// candidates after ingest, for verifying the render path end to end.
    static var exportDirectory: String? { value(for: "--export-shorts") }
    static var exportCount: Int { Int(value(for: "--export-count") ?? "") ?? 1 }

    /// `--export-longform <file.mp4>` renders the assembled long-form cut.
    static var longFormOutput: String? { value(for: "--export-longform") }

    /// `--detect-scenes` runs the opt-in video scene pass during a headless run.
    static var wantsSceneDetection: Bool { CommandLine.arguments.contains("--detect-scenes") }

    /// `--chat <file.json>` attaches a chat replay before scoring.
    static var chatPath: String? { value(for: "--chat") }

    /// `--open <name substring>` selects a project on launch instead of
    /// landing on the dashboard — for driving the UI in scripted runs and
    /// screenshots without clicking.
    static var openProjectQuery: String? { value(for: "--open") }

    /// `--window 1280x800` pins the window size on launch, for reproducing
    /// layout bugs at exact dimensions.
    static var windowSize: (width: Double, height: Double)? {
        guard let spec = value(for: "--window") else { return nil }
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 700, parts[1] >= 500 else { return nil }
        return (parts[0], parts[1])
    }

    /// `--match-style <file>` analyses a reference edit and applies its style.
    static var stylePath: String? { value(for: "--match-style") }

    /// `--tune-audio` measures the mix, applies the suggested tuning, and
    /// reports the before/after on a rendered sample.
    static var wantsAudioTuning: Bool { CommandLine.arguments.contains("--tune-audio") }

    /// `--thumbnail <file.jpg> [--thumbnail-text "..."]` pulls stills and
    /// renders a thumbnail without the UI.
    static var thumbnailOutput: String? { value(for: "--thumbnail") }
    static var thumbnailText: String? { value(for: "--thumbnail-text") }

    static func report(_ message: String) {
        guard isHeadlessRun else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }
}
