//
//  JournalStore.swift
//  spending-tracker
//
//  Append-only JSONL. The one thing in Stage 1 that must not lose data.
//

import Foundation

/// Append and read the raw journal.
///
/// JSONL is safe here for a non-obvious reason worth stating: `JSONEncoder` escapes a
/// newline *inside a string value* as the two-character sequence `\` `n`, so an SMS body
/// containing literal newlines can never break line framing. `JournalStoreTests` asserts
/// this against hostile payloads rather than trusting it.
nonisolated enum JournalStore {

    /// Guards in-process writers only — the `.main` execution-target pin means there is
    /// only ever one writer process in Stage 1. Cross-process atomicity would need
    /// `open(2)` with `O_APPEND` and a single `write(2)`; not warranted yet.
    private static let lock = NSLock()

    static func append(_ record: JournalRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        // NOTE: there is no `.iso8601WithFractionalSeconds` on JSONEncoder.DateEncodingStrategy
        // in the iOS 27 SDK (verified: the only cases are deferredToDate, secondsSince1970,
        // millisecondsSince1970, iso8601, formatted, custom). Timestamps therefore have
        // one-second resolution, and record ORDER comes from file position — never from
        // `receivedAt`. `readAll` preserves that order deliberately.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        var line = try encoder.encode(record)
        line.append(0x0A)

        lock.lock()
        defer { lock.unlock() }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        // Flush to disk before returning: this journal is the evidence that a transaction
        // arrived, and the process may be killed the moment `perform()` returns.
        try handle.synchronize()
    }

    /// Returns records in FILE ORDER, which is authoritative — see the note on timestamps above.
    ///
    /// Undecodable lines are dropped rather than thrown on, so a single torn write at the
    /// tail (process killed mid-append) cannot hide everything written before it.
    static func readAll(from url: URL) -> [JournalRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(JournalRecord.self, from: Data($0.utf8)) }
    }
}
