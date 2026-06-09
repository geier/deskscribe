import Foundation

enum VocabularyEntryKind: String, Codable, CaseIterable {
    case word
    case replacement
}

struct VocabularyEntry: Codable, Equatable {
    var kind: VocabularyEntryKind
    var phrase: String
    var replacement: String?

    var storageValue: String {
        switch kind {
        case .word:
            return phrase
        case .replacement:
            return "\(phrase) -> \(replacement ?? "")"
        }
    }
}

enum VocabularyCodec {
    struct ExportPayload: Codable, Equatable {
        var version: Int
        var entries: [VocabularyEntry]
    }

    static func entries(from storedWords: [String]) -> [VocabularyEntry] {
        storedWords.compactMap { parseLine($0)?.entry }
    }

    static func storedWords(from entries: [VocabularyEntry]) -> [String] {
        AppSettings.normalizedVocabulary(entries.map(\.storageValue))
    }

    static func parseLines(_ text: String) -> (entries: [VocabularyEntry], invalidLines: [String]) {
        var entries: [VocabularyEntry] = []
        var invalidLines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let parsed = parseLine(trimmed) {
                entries.append(parsed.entry)
            } else {
                invalidLines.append(rawLine)
            }
        }
        return (deduplicated(entries), invalidLines)
    }

    static func parseLine(_ line: String) -> (entry: VocabularyEntry, normalized: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let separator: String?
        if trimmed.contains("=>") {
            separator = "=>"
        } else if trimmed.contains("->") {
            separator = "->"
        } else {
            separator = nil
        }

        guard let separator else {
            let entry = VocabularyEntry(kind: .word, phrase: trimmed, replacement: nil)
            return (entry, entry.storageValue)
        }

        let parts = trimmed.components(separatedBy: separator)
        guard parts.count == 2 else { return nil }
        let phrase = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !replacement.isEmpty else { return nil }
        let entry = VocabularyEntry(kind: .replacement, phrase: phrase, replacement: replacement)
        return (entry, entry.storageValue)
    }

    static func exportData(entries: [VocabularyEntry]) throws -> Data {
        let payload = ExportPayload(version: 1, entries: deduplicated(entries))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    static func importEntries(from data: Data) throws -> [VocabularyEntry] {
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(ExportPayload.self, from: data) {
            return deduplicated(payload.entries.filter(isValid))
        }
        let entries = try decoder.decode([VocabularyEntry].self, from: data)
        return deduplicated(entries.filter(isValid))
    }

    static func deduplicated(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var seen = Set<String>()
        var result: [VocabularyEntry] = []
        for entry in entries where isValid(entry) {
            let key = "\(entry.kind.rawValue)|\(entry.phrase.lowercased())|\((entry.replacement ?? "").lowercased())"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(entry)
        }
        return result
    }

    static func isValid(_ entry: VocabularyEntry) -> Bool {
        let phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return false }
        if entry.kind == .replacement {
            return !(entry.replacement ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}
