import Foundation

/// App-level roster of client profiles — one JSON file in Application Support,
/// shared by every project.
@MainActor
final class ClientStore: ObservableObject {
    static let shared = ClientStore()

    @Published private(set) var clients: [ClientProfile] = []

    private var fileURL: URL { Paths.appSupport.appendingPathComponent("clients.json") }

    init() {
        Paths.ensureAppDirectories()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ClientProfile].self, from: data) {
            clients = decoded
        }
    }

    func upsert(_ profile: ClientProfile) {
        if let index = clients.firstIndex(where: { $0.id == profile.id }) {
            clients[index] = profile
        } else {
            clients.append(profile)
        }
        persist()
    }

    func delete(_ profile: ClientProfile) {
        clients.removeAll { $0.id == profile.id }
        persist()
    }

    func client(_ id: UUID?) -> ClientProfile? {
        id.flatMap { target in clients.first { $0.id == target } }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(clients).write(to: fileURL, options: .atomic)
    }
}
