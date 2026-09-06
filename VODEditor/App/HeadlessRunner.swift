import AppKit
import SwiftUI

/// Drives the command-line entry points.
///
/// This used to hang off `RootView.onAppear`, which meant the CLI only worked
/// when SwiftUI got around to showing a window — and when it didn't, the
/// process sat in `NSApplication.run` at 0% CPU forever, printing nothing.
/// `applicationDidFinishLaunching` always fires, so the work no longer depends
/// on anything being on screen.
@MainActor
final class HeadlessRunner {
    static let shared = HeadlessRunner()

    private let store = ProjectStore.shared
    private lazy var queue = DownloadQueue(store: store)
    private var started = false

    func runIfNeeded() {
        guard !started, LaunchOptions.isHeadlessRun else { return }
        started = true

        if let link = LaunchOptions.linkURL {
            Task { await runLink(link) }
        } else if let path = LaunchOptions.ingestPath {
            Task { await runIngest(path: path) }
        }
    }

    // MARK: - Ingest

    /// Reuses an existing project for the same source so a re-run resumes
    /// rather than starting over.
    private func runIngest(path: String) async {
        let report = DependencyReport.current()
        guard report.allSatisfied else {
            LaunchOptions.report("Missing dependencies — run Setup first.")
            exit(1)
        }

        // Standardized, because `/a//b` and `/a/b` are the same file but not
        // the same string — and matching on the raw string quietly created a
        // second project for the same source instead of resuming the first.
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        let project: VODProject
        if let existing = store.projects.first(where: {
            URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == wanted
        }) {
            LaunchOptions.report("Resuming project \(existing.id)")
            project = existing
        } else {
            do {
                project = try store.create(sourceURL: URL(fileURLWithPath: path))
                LaunchOptions.report("Created project \(project.id) for \(path)")
            } catch {
                LaunchOptions.report("Could not create project: \(error.localizedDescription)")
                exit(1)
            }
        }

        store.selectedProjectID = project.id
        // The session reports its own completion and exits, including any
        // requested exports.
        let session = ProjectSession(project: project, store: store)
        await session.runIngestToCompletion()
    }

    // MARK: - Link

    private func runLink(_ link: String) async {
        LaunchOptions.report("Link: \(link)")
        guard queue.add(link) > 0 else {
            LaunchOptions.report("Not a usable link: \(queue.lastError ?? "unknown")")
            exit(1)
        }

        var lastReport = ""
        while queue.isRunning || queue.items.contains(where: { !$0.status.isFinished }) {
            if let item = queue.items.first {
                var line = "\(item.title) — \(item.detail)"
                if let progress = item.progress {
                    let done = ByteCountFormatter.string(fromByteCount: progress.downloadedBytes,
                                                         countStyle: .file)
                    line = "downloading \(done)"
                    if let fraction = progress.fraction {
                        line += String(format: " (%.0f%%)", fraction * 100)
                    }
                    if let speed = progress.speedLabel { line += " at \(speed)" }
                } else if let detail = queue.ingestDetail {
                    line = detail
                }
                if line != lastReport {
                    lastReport = line
                    LaunchOptions.report(line)
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        guard let item = queue.items.first else { exit(1) }
        switch item.status {
        case .done:
            LaunchOptions.report("Source: \(item.filePath ?? "?")")
            LaunchOptions.report("\(item.title) — \(item.detail)")
            LaunchOptions.report("LINK COMPLETE")
            exit(0)
        case .failed(let message):
            LaunchOptions.report("FAILED: \(message)")
            exit(1)
        default:
            LaunchOptions.report("FAILED: stopped unexpectedly")
            exit(1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HeadlessRunner.shared.runIfNeeded()
        // `--window 1280x800` pins the window to an exact size on launch —
        // for reproducing layout at a given size without hand-resizing.
        if let spec = LaunchOptions.windowSize {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
                let frame = NSRect(x: 40, y: 60, width: spec.width, height: spec.height)
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
