import Foundation

/// The sound-effect library: a Finder folder scanned flat. Files at the top
/// level are untagged; each subfolder is a tag ("stings", "whooshes"). The
/// first nine sounds (alphabetical, pinned-first) map to hotkeys 1–9 in the
/// editor, dropping at the playhead.
enum SFXLibrary {
    struct Sound: Identifiable, Equatable {
        var id: String { path }
        var path: String
        var name: String
        var tag: String

        var url: URL { URL(fileURLWithPath: path) }
    }

    static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aiff", "ogg", "flac"]

    /// One level deep: top-level files plus each subfolder's files under its
    /// name as the tag. Sorted by tag then name, so hotkey order is stable.
    static func scan(root: URL = Paths.sfxRoot) -> [Sound] {
        let fm = FileManager.default
        var sounds: [Sound] = []
        let top = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])) ?? []
        for entry in top.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let inner = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                for file in inner.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where audioExtensions.contains(file.pathExtension.lowercased()) {
                    sounds.append(Sound(path: file.path,
                                        name: file.deletingPathExtension().lastPathComponent,
                                        tag: entry.lastPathComponent))
                }
            } else if audioExtensions.contains(entry.pathExtension.lowercased()) {
                sounds.append(Sound(path: entry.path,
                                    name: entry.deletingPathExtension().lastPathComponent,
                                    tag: ""))
            }
        }
        return sounds
    }

    /// The synthesized starter pack — placeholder sounds built locally with
    /// ffmpeg's generators, so the panel isn't empty on day one and nothing
    /// copyrighted ships. Each entry is (filename, ffmpeg args after -y).
    /// Real packs dropped into the folder will sound better; these are
    /// honest scaffolding.
    static func starterPack() -> [(name: String, arguments: [String])] {
        func lavfi(_ name: String, _ graph: String, seconds: Double) -> (String, [String]) {
            (name, ["-f", "lavfi", "-i", graph,
                    "-t", String(format: "%.2f", seconds),
                    "-ar", "48000", "-ac", "2"])
        }
        return [
            // Filtered noise sweeping down — the classic transition whoosh.
            lavfi("whoosh.wav",
                  "anoisesrc=color=pink:amplitude=0.8,lowpass=f='3000-2200*t/0.5':width_type=h:w=500,afade=t=in:d=0.05,afade=t=out:st=0.3:d=0.2",
                  seconds: 0.5),
            // A low sine drop with a hard attack — the reveal boom.
            lavfi("boom.wav",
                  "sine=frequency=80:beep_factor=0,volume=2.5,atremolo=f=8:d=0.3,lowpass=f=160,afade=t=out:st=0.15:d=0.85",
                  seconds: 1.0),
            // Short high ding for on-screen text lands.
            lavfi("ding.wav",
                  "sine=frequency=1568,volume=0.5,afade=t=out:st=0.05:d=0.75",
                  seconds: 0.8),
            // A quick blip for comic beats.
            lavfi("pop.wav",
                  "sine=frequency='440+660*t/0.12',volume=0.7,afade=t=out:st=0.06:d=0.06",
                  seconds: 0.12),
            // Riser: noise swelling into a cut.
            lavfi("riser.wav",
                  "anoisesrc=color=white:amplitude=0.5,highpass=f=400,afade=t=in:d=1.4,afade=t=out:st=1.4:d=0.1",
                  seconds: 1.5),
        ]
    }
}
