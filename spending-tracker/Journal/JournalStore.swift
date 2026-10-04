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

    /// Writes `data` over the journal in a single rename.
    ///
    /// The journal is the one thing in this app that must never lose data, so a rewrite is
    /// never done in place. The replacement is written alongside the original and swapped in
    /// with one rename, so an interruption — a crash, a kill, the app being suspended
    /// mid-write — leaves the original intact rather than a half-written file.
    ///
    /// Private, and the only writer of the file: every rewrite in the app goes through
    /// `remove`, so no caller can open-code a read-modify-write that is not atomic against a
    /// concurrent `append`. The caller holds `lock`.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appending(path: "journal.jsonl.replacing")
        try? FileManager.default.removeItem(at: staging)
        try data.write(to: staging, options: .atomic)

        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
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

    /// Removes every line whose record satisfies `shouldRemove`, and nothing else.
    ///
    /// This exists as a primitive rather than as `readAll` + filter + a write, because that
    /// composition is **not safe**: the lock is released between reading and writing, and
    /// `LogTransactionIntent` appends from the same process (`.main` execution target) while
    /// `perform()` runs off the main actor. An alert arriving in that gap — a real charge —
    /// would be read as absent and then written away by the rewrite. Here the read, the
    /// decision and the rename happen under one lock hold, so a concurrent append either
    /// lands before (and is considered) or after (and survives).
    ///
    /// A line that **fails to decode is carried through untouched** rather than dropped. It
    /// used to be lost by every rewrite, because the file was rebuilt by re-encoding the
    /// records `readAll` had managed to decode. A line the current schema cannot read is
    /// still evidence, and `JournalRecord`'s own note records the day a field was added and
    /// silently made every older line undecodable — exactly when this would have bitten.
    ///
    /// Returns the number of lines removed. Zero means the file was left byte-for-byte
    /// alone, which is what keeps an untouched journal from being rewritten on every
    /// foreground.
    ///
    /// Throws when the journal is present but cannot be read. A caller about to delete the
    /// store rows derived from these lines must not treat "could not read" as "not there":
    /// that would remove the row while the line survived, and the next drain would bring the
    /// row back — the exact failure the journal-first ordering exists to prevent.
    @discardableResult
    static func remove(from url: URL, where shouldRemove: @Sendable (JournalRecord) -> Bool) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // A journal that is not there has nothing to remove, and a fresh install is not a
            // failure. Anything else — permissions, a torn filesystem — is.
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                return 0
            }
            throw JournalStoreError.unreadable
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Split on the BYTE 0x0A and decode each line on its own, rather than decoding the
        // whole file as one UTF-8 string. Decoding the file would make a single invalid byte
        // anywhere — a torn write through the middle of a multi-byte character, say — fail the
        // entire read, so one damaged line would stop every deletion and, through the purge,
        // quietly stop the retention window too. Per line, the damage stays on the line it is
        // on, and that line is carried through as bytes because it is the only copy of
        // whatever it holds.
        var replacement = Data()
        var removed = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let record = String(data: line, encoding: .utf8)
                .flatMap { try? decoder.decode(JournalRecord.self, from: Data($0.utf8)) }
            if let record, shouldRemove(record) {
                removed += 1
                continue
            }
            // Appended as the original bytes, never re-encoded: a line that does not decode
            // has to come out of a rewrite exactly as it went in.
            replacement.append(line)
            replacement.append(0x0A)
        }

        guard removed > 0 else { return 0 }

        try writeAtomically(replacement, to: url)
        return removed
    }
}

/// Why a rewrite was refused.
///
/// Deliberately one case with no payload: the only thing a caller can do about it is decline
/// to delete, and the message is the whole of what a person needs to read.
nonisolated enum JournalStoreError: LocalizedError {
    /// The file is there and could not be read, as distinct from not being there at all.
    case unreadable

    var errorDescription: String? {
        "The raw journal could not be read, so nothing was deleted."
    }
}
