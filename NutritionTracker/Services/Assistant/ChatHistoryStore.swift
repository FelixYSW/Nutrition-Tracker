import Foundation

/// One saved assistant conversation: what the user saw, plus the model-facing
/// history needed to carry on from where it left off.
struct SavedConversation: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [AssistantChatMessage]
    var turns: [AssistantTurn]

    /// Last thing the assistant said, for the history list.
    var preview: String? {
        for message in messages.reversed() {
            switch message.kind {
            case .assistant(let text): return text
            case .proposalResolved(let summary, _): return summary
            default: continue
            }
        }
        return nil
    }

    /// The first thing the user asked, trimmed to a short title.
    static func title(for messages: [AssistantChatMessage]) -> String {
        for message in messages {
            guard case .user(let text, let images) = message.kind else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
                return line.count > 50 ? String(line.prefix(50)) + "\u{2026}" : line
            }
            if !images.isEmpty { return images.count == 1 ? "Photo" : "\(images.count) photos" }
        }
        return "New chat"
    }
}

/// Keeps past assistant chats on the device, one JSON file each.
///
/// Files rather than SwiftData so the shipping database schema doesn't change.
/// Chats hold health-adjacent data, so they stay on this iPhone only: never
/// uploaded, excluded from iCloud backup, and removed by "Delete all data"
/// (spec section 39).
final class ChatHistoryStore: @unchecked Sendable {
    static let shared = ChatHistoryStore()

    /// Oldest chats beyond this are removed when a new one is saved.
    static let maximumConversations = 50

    private let directory: URL?
    private let queue = DispatchQueue(label: "ChatHistoryStore")

    /// `directory` is for tests; the app uses Application Support.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = try? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("AssistantChats", isDirectory: true)
        }
        prepareDirectory()
    }

    private func prepareDirectory() {
        guard var directory else { return }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private func fileURL(for id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).json")
    }

    // Default date format (seconds as a number) rather than ISO 8601, which
    // drops fractions of a second: a reopened chat must match what was saved.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: Reading

    /// Every saved chat, most recently updated first. Unreadable files (e.g.
    /// from a future version) are skipped rather than failing the list.
    func all() -> [SavedConversation] {
        queue.sync {
            guard let directory,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil) else { return [] }
            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { url in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? Self.decoder.decode(SavedConversation.self, from: data)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    // MARK: Writing

    func save(_ conversation: SavedConversation) {
        queue.sync {
            guard let url = fileURL(for: conversation.id),
                  let data = try? Self.encoder.encode(conversation) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
        trim()
    }

    func delete(id: UUID) {
        queue.sync {
            guard let url = fileURL(for: id) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func deleteAll() {
        queue.sync {
            guard let directory,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func trim() {
        let conversations = all()
        guard conversations.count > Self.maximumConversations else { return }
        for old in conversations.dropFirst(Self.maximumConversations) {
            delete(id: old.id)
        }
    }
}
