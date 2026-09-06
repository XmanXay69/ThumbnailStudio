import Foundation

/// Local inference over Ollama's HTTP interface at 127.0.0.1. Nothing leaves
/// the machine, there is no key and no per-run cost — the constraint is time.
struct OllamaClient {
    static let endpoint = URL(string: "http://127.0.0.1:11434")!

    /// Models this app knows how to gate by memory: the 14B is noticeably
    /// better at classification but wants ~10 GB for weights alone.
    static let preferredModels: [(name: String, minimumRAMGB: Int)] = [
        ("qwen2.5:14b", 24),
        ("llama3.1:8b", 12),
    ]

    /// The request body for one chunk analysis. Ollama's `format` parameter
    /// constrains decoding to the schema — small local models drift into
    /// prose and markdown fences without it.
    static func chatBody(model: String, system: String, user: String,
                         schema: [String: Any]) -> [String: Any] {
        [
            "model": model,
            "stream": false,
            "format": schema,
            "options": [
                "temperature": 0.3,
                "num_ctx": 8192,
            ],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
    }

    /// Whether the server answers, and which models are pulled.
    static func installedModels() async -> [String]? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// The binary, wherever Homebrew or the app bundle put it.
    static func binary() -> URL? {
        for path in ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                     "/Applications/Ollama.app/Contents/Resources/ollama"] {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Server not answering but the binary exists → start it ourselves,
    /// detached, and give it a moment. No login items, no services.
    static func ensureServer() async -> Bool {
        if await installedModels() != nil { return true }
        guard let binary = binary() else { return false }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await installedModels() != nil { return true }
        }
        return false
    }

    /// The best pulled model this machine can hold: 14B needs real headroom,
    /// 8B runs comfortably in 16 GB alongside the app.
    static func chooseModel(installed: [String], ramBytes: UInt64) -> String? {
        let ramGB = Int(ramBytes / 1_073_741_824)
        if let picked = UserDefaults.standard.string(forKey: "ollamaModel"),
           installed.contains(picked) {
            return picked
        }
        for (name, minimum) in preferredModels where ramGB >= minimum {
            if let match = installed.first(where: { $0 == name || $0.hasPrefix(name + "-") }) {
                return match
            }
        }
        // Anything pulled beats nothing — the user may have their own pick.
        return installed.first
    }

    /// One chunk through the model. Long timeout: an 8B on Apple Silicon
    /// takes 20–60s per chunk and that's normal, not a hang.
    func analyze(model: String, system: String, user: String,
                 schema: [String: Any]) async throws -> String {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.chatBody(model: model, system: system, user: user, schema: schema))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CoherenceError.malformed("Ollama returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CoherenceError.malformed("Ollama response had no message content")
        }
        return content
    }
}
