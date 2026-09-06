import Foundation

struct ExternalTool: Identifiable, Equatable {
    let id: String
    let displayName: String
    let url: URL?
    let versionLine: String?
    let installHint: String

    var isAvailable: Bool { url != nil }
}

struct WhisperModel: Identifiable, Equatable {
    let id: String          // file name, e.g. ggml-large-v3-turbo.bin
    let url: URL
    let sizeBytes: Int64

    var displayName: String {
        id.replacingOccurrences(of: "ggml-", with: "")
            .replacingOccurrences(of: ".bin", with: "")
    }

    /// whisper-cli's `-dtw` flag needs the model's alias, not its path, to load
    /// the right alignment heads for token-level timestamps.
    var dtwAlias: String? {
        let name = displayName.lowercased()
        let known = ["large.v3.turbo": "large-v3-turbo", "large.v3": "large-v3",
                     "large.v2": "large-v2", "large.v1": "large-v1",
                     "medium.en": "medium.en", "medium": "medium",
                     "small.en": "small.en", "small": "small",
                     "base.en": "base.en", "base": "base",
                     "tiny.en": "tiny.en", "tiny": "tiny"]
        // Longest match first so "large-v3-turbo" doesn't match "large-v3".
        for (alias, fragment) in known.sorted(by: { $0.value.count > $1.value.count }) {
            if name.contains(fragment) { return alias }
        }
        return nil
    }
}

/// Finds the CLI tools the pipeline depends on.
///
/// This matters more than it looks: an app launched from Finder inherits a bare
/// `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so Homebrew tools are invisible to
/// a plain `which`. Everything is resolved by absolute path instead.
enum ToolLocator {
    /// `ffmpeg-full` is keg-only, so it never lands in `/opt/homebrew/bin` —
    /// but it's the build that actually carries libass, and Homebrew's plain
    /// `ffmpeg` bottle does not. Caption burn-in needs it, so it goes first.
    static let searchPaths = [
        "/opt/homebrew/opt/ffmpeg-full/bin",
        "/usr/local/opt/ffmpeg-full/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
    ]

    private static func overrideKey(_ name: String) -> String { "toolPath.\(name)" }

    static func overridePath(for name: String) -> String? {
        UserDefaults.standard.string(forKey: overrideKey(name))
    }

    static func setOverridePath(_ path: String?, for name: String) {
        if let path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: overrideKey(name))
        } else {
            UserDefaults.standard.removeObject(forKey: overrideKey(name))
        }
    }

    static func locate(_ name: String) -> URL? {
        if let override = overridePath(for: name) {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        for dir in searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func tool(_ name: String, displayName: String, hint: String) async -> ExternalTool {
        guard let url = locate(name) else {
            return ExternalTool(id: name, displayName: displayName, url: nil,
                                versionLine: nil, installHint: hint)
        }
        let version = await firstVersionLine(of: url, name: name)
        return ExternalTool(id: name, displayName: displayName, url: url,
                            versionLine: version, installHint: hint)
    }

    private static func firstVersionLine(of url: URL, name: String) async -> String? {
        let args = name.hasPrefix("whisper") ? ["--version"] : ["-version"]
        guard let result = try? await Shell.run(url, arguments: args) else { return nil }
        let combined = result.stdout.isEmpty ? result.stderr : result.stdout
        // whisper-cli dumps a wall of Metal backend logging before the version.
        let line = combined
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.lowercased().contains("version") || $0.lowercased().hasPrefix("ffmpeg") || $0.lowercased().hasPrefix("ffprobe") })
        return line?.trimmingCharacters(in: .whitespaces)
    }

    static func installedModels() -> [WhisperModel] {
        Paths.ensureAppDirectories()
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: Paths.modelsRoot,
                                                    includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents
            .filter { $0.pathExtension == "bin" && $0.lastPathComponent.hasPrefix("ggml-") }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return WhisperModel(id: url.lastPathComponent, url: url, sizeBytes: Int64(size))
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Prefers turbo (fast, near-large accuracy), then the largest model present.
    static func preferredModel(accurate: Bool = false) -> WhisperModel? {
        let models = installedModels()
        // Max accuracy prefers the full large-v3 — measurably lower word error
        // than turbo on fast, slangy speech, at ~3–4× the transcription time.
        if accurate,
           let full = models.first(where: { $0.id.contains("large-v3") && !$0.id.contains("turbo") }) {
            return full
        }
        return models.first(where: { $0.id.contains("large-v3-turbo") }) ?? models.first
    }

    /// Whether the full-accuracy model is installed at all.
    static var hasAccurateModel: Bool {
        installedModels().contains { $0.id.contains("large-v3") && !$0.id.contains("turbo") }
    }

    /// Whether the located ffmpeg can burn in styled captions. Homebrew's slim
    /// `ffmpeg` bottle ships without libass, and the failure would otherwise
    /// only surface at export time as an opaque filter error.
    private static var cachedFilterSupport: Set<String>?

    static func ffmpegFilters() async -> Set<String> {
        if let cachedFilterSupport { return cachedFilterSupport }
        guard let ffmpeg = locate("ffmpeg"),
              let result = try? await Shell.run(ffmpeg, arguments: ["-hide_banner", "-filters"]) else {
            return []
        }
        var found: Set<String> = []
        for line in result.stdout.split(separator: "\n") {
            // Format: " ... name    V->V   description"
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2 { found.insert(String(fields[1])) }
        }
        cachedFilterSupport = found
        return found
    }

    static func invalidateCapabilityCache() { cachedFilterSupport = nil }

    /// macOS gates Desktop/Documents/Downloads behind TCC even for unsandboxed
    /// apps. Reading the TCC database is the standard probe for Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let tcc = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        return FileManager.default.isReadableFile(atPath: tcc.path)
    }

    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}
