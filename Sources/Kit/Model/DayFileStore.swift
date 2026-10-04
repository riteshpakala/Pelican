import Foundation

/// A document holding one local day's record.
package protocol DayDocument: Codable, Sendable {
    var day: String { get }
}

/// Keeps one JSON file per local day under Application Support, and forgets days past the
/// retention window. Writes are atomic, so a crash mid-save cannot corrupt a day.
///
/// `PELICAN_LEDGER_DIR` moves the whole directory, for experimenting without touching the
/// real record.
package actor DayFileStore<Document: DayDocument> {

    package static var keepDays: Int { 30 }

    nonisolated package let root: URL
    nonisolated private let folder: String

    nonisolated package static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["PELICAN_LEDGER_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pelican/ledger")
    }

    package init(folder: String, root: URL = DayFileStore.defaultRoot) {
        self.folder = folder
        self.root = root
    }

    nonisolated package func url(day: String) -> URL {
        root.appendingPathComponent(folder).appendingPathComponent("\(day).json")
    }

    nonisolated package static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated package static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Synchronous load, for adopting today's record at startup.
    nonisolated package func loadNow(day: String) -> Document? {
        guard let data = try? Data(contentsOf: url(day: day)) else { return nil }
        return try? Self.decoder.decode(Document.self, from: data)
    }

    package func load(day: String) -> Document? { loadNow(day: day) }

    /// Synchronous save, for quitting.
    @discardableResult
    nonisolated package func saveNow(_ document: Document) -> Bool {
        let destination = url(day: document.day)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(document).write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    package func save(_ document: Document) { saveNow(document) }

    /// Days on disk, newest first.
    package func days() -> [String] {
        let directory = root.appendingPathComponent(folder)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted(by: >)
    }

    /// Delete everything older than the newest `keep` days.
    package func prune(keep: Int = DayFileStore.keepDays) {
        let directory = root.appendingPathComponent(folder)
        for day in days().dropFirst(keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(day).json"))
        }
    }

    /// "yyyy-MM-dd" in the local calendar — the key a day's file is named by.
    nonisolated package static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
