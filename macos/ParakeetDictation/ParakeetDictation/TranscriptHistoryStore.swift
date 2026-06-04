import Foundation

struct TranscriptHistoryEntry: Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var text: String
    var characterCount: Int
    var wordCount: Int
    var appVariant: String
}

struct UsageStats: Equatable {
    var dictationCount: Int
    var totalCharacters: Int
    var totalWords: Int
    var todayWords: Int
    var weekWords: Int
}

enum TranscriptHistoryStore {
    private static let maxEntries = 500

    static var historyURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskScribe", isDirectory: true)
        return directory.appendingPathComponent("TranscriptHistory.json")
    }

    static func load() -> [TranscriptHistoryEntry] {
        do {
            let data = try Data(contentsOf: historyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([TranscriptHistoryEntry].self, from: data)
        } catch {
            return []
        }
    }

    static func append(text: String, appVariant: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var entries = load()
        entries.insert(
            TranscriptHistoryEntry(
                id: UUID(),
                createdAt: Date(),
                text: trimmed,
                characterCount: trimmed.count,
                wordCount: wordCount(trimmed),
                appVariant: appVariant
            ),
            at: 0
        )
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: historyURL)
    }

    static func save(_ entries: [TranscriptHistoryEntry]) {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: historyURL, options: .atomic)
        } catch {
            DebugLog.shared.error("failed to save transcript history: \(error.localizedDescription)")
        }
    }

    static func stats(for entries: [TranscriptHistoryEntry] = load(), now: Date = Date()) -> UsageStats {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        return UsageStats(
            dictationCount: entries.count,
            totalCharacters: entries.reduce(0) { $0 + $1.characterCount },
            totalWords: entries.reduce(0) { $0 + $1.wordCount },
            todayWords: entries.filter { $0.createdAt >= startOfToday }.reduce(0) { $0 + $1.wordCount },
            weekWords: entries.filter { $0.createdAt >= startOfWeek }.reduce(0) { $0 + $1.wordCount }
        )
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
