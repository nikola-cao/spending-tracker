//
//  JournalStore.swift
//  spending-tracker
//
//  Append-only JSONL. The one thing in Stage 1 that must not lose data.
//

import Darwin
import Foundation

/// One line of the file, whether or not the current schema can read it.
///
/// A rewrite decides line by line, and it has to be able to decide about a line it cannot
/// decode too — otherwise a torn line is permanent junk that every rewrite faithfully preserves
/// and no screen can ever clear.
nonisolated enum JournalLine: Sendable, Equatable {
    case record(JournalRecord)

    /// A line the current schema cannot read, exactly as it sits in the file — without its
    /// trailing newline. Bytes rather than a string because it need not be valid UTF-8, and
    /// because a line that does not decode has to come back out of a rewrite as it went in.
    case damaged(Data)
}

/// Everything one pass over the journal produced.
///
/// `damaged` exists because the alternative is what this file used to do: drop a line that does
/// not decode and return the rest. That made **"a line was written and cannot be read"** and
/// **"no line was ever written"** look identical on every screen the app has — the Raw journal
/// reads through here, the drain reads through here, and the store is derived from this file, so
/// the difference is a transaction that exists or does not. It is the one distinction this app
/// cannot afford to lose silently.
nonisolated struct JournalRead: Sendable {
    var records: [JournalRecord] = []
    var damaged: [Data] = []

    var damagedByteCount: Int { damaged.reduce(0) { $0 + $1.count } }

    /// True only when there is nothing at all in the file. Deliberately not `records.isEmpty`:
    /// a file holding one damaged line and no records is not an empty journal, and reading it
    /// as one is exactly the mistake this type was introduced to stop.
    var isEmpty: Bool { records.isEmpty && damaged.isEmpty }
}

extension JournalRead {

    /// The plain-text projection the Diagnostics screen shares out.
    ///
    /// Every field a line records goes in, not just the body. `processName`, `journalDirectory`
    /// and `appGroupAvailable` exist to answer *"did this run in the app's own process, and
    /// did it write into the app's own container"* — and until they were exported, that
    /// question could not be answered from a phone at all: the evidence was in the file, and
    /// the export carried none of it. An instrument nobody can read is not an instrument.
    ///
    /// A damaged line is exported too, marked, with the bytes it actually holds — truncated,
    /// because a torn write of a 60 KB Amex email is mostly an email.
    nonisolated var exportText: String {
        var lines: [String] = []

        for record in records {
            lines.append([
                record.receivedAt.formatted(.iso8601),
                record.processName,
                "main:\(record.isMainThread ? 1 : 0)",
                "grp:\(record.appGroupAvailable ? 1 : 0)",
                record.journalDirectory,
                record.note,
                record.rawText,
            ].joined(separator: "\t"))
        }

        for damaged in damaged {
            lines.append([
                "[damaged]",
                "\(damaged.count) bytes",
                String(decoding: damaged.prefix(400), as: UTF8.self),
            ].joined(separator: "\t"))
        }

        return lines.joined(separator: "\n")
    }
}

/// Append and read the raw journal.
///
/// JSONL is safe here for a non-obvious reason worth stating: `JSONEncoder` escapes a
/// newline *inside a string value* as the two-character sequence `\` `n`, so an SMS body
/// containing literal newlines can never break line framing. `JournalStoreTests` asserts
/// this against hostile payloads rather than trusting it.
nonisolated enum JournalStore {

    /// Guards in-process writers only. Cross-process atomicity is handled by the `O_APPEND`
    /// append below rather than by this lock — see `append`. The `.main` execution-target pin
    /// means there should only ever be one writer process, but that pin is the one assumption
    /// in this design nobody has published field data for, so the file no longer depends on it.
    private static let lock = NSLock()

    /// Appends one record as one line.
    ///
    /// Written with `open(2)` and `O_APPEND` rather than with `FileHandle` + `seekToEnd`, and the
    /// difference is not style. `FileHandle(forWritingTo:)` opens **without** `O_APPEND`, so the
    /// append is two steps — position the offset, then write — and two writers that interleave
    /// those steps lose one line outright: the survivor is perfectly valid, so the loss leaves no
    /// trace anywhere. That cannot happen in this app *today*, because `LogTransactionIntent` is
    /// pinned to the app's own process and the lock above serializes its writers — but the pin is
    /// the one assumption in this design that nobody has published field data for, and this
    /// removes the need to be right about it. Measured rather than assumed: a two-process repro
    /// of the seek-to-end-then-write sequence lost half the lines.
    ///
    /// A trailing newline is written first when the file does not already end in one — see the
    /// comment below, which is the other half of a torn write's damage.
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

        // `O_RDWR`, not `O_WRONLY`: the framing check below reads the file's last byte, and a
        // `pread` on a write-only descriptor fails with `EBADF` — which the check would read as
        // "not terminated" and answer by writing a stray newline before every single record.
        // `O_APPEND` is what makes the append atomic, and it applies to writes either way.
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { throw JournalStoreError.systemCall("open") }
        defer { close(fd) }

        // A torn write leaves a line with no terminator, and an append that runs straight onto
        // it fuses two records into one unreadable line — so the alert *after* a torn one would
        // be lost with it, and nobody could tell either of them had ever arrived. Framing the
        // tail first costs one byte in the rare case and turns a two-alert loss into a one-alert
        // loss. See `endsWithNewline`.
        if !endsWithNewline(fd) {
            try writeAll(fd, Data([0x0A]))
        }
        try writeAll(fd, line)

        // Flush to disk before returning: this journal is the evidence that a transaction
        // arrived, and the process may be killed the moment `perform()` returns.
        guard fsync(fd) == 0 else { throw JournalStoreError.systemCall("fsync") }
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

    /// Everything the file holds: the records in FILE ORDER, and — separately — the lines that
    /// could not be read back.
    ///
    /// File order is authoritative — see the note on timestamps above.
    ///
    /// Decoded a line at a time from the raw bytes, for two reasons that both bite in practice:
    ///
    ///  - The file used to be decoded as **one** UTF-8 string, so a single invalid byte anywhere
    ///    returned nothing at all. One torn write could blank the entire journal on every screen
    ///    at once — the Raw journal would read "0 lines" while the feed still showed rows derived
    ///    from a moment earlier. Per line, the damage stays on the line it is on.
    ///  - A line that does not decode is reported rather than dropped, which is the difference
    ///    between "this arrived and we cannot read it" and "this never arrived". See `JournalRead`.
    static func read(from url: URL) -> JournalRead {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: url) else { return JournalRead() }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var result = JournalRead()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let bytes = Data(line)
            if let record = String(data: bytes, encoding: .utf8)
                .flatMap({ try? decoder.decode(JournalRecord.self, from: Data($0.utf8)) }) {
                result.records.append(record)
            } else {
                result.damaged.append(bytes)
            }
        }
        return result
    }

    /// Just the records.
    ///
    /// Kept because most callers want nothing else, but anything reporting on the health of
    /// capture should use `read(from:)`: this one cannot say that a line exists and is
    /// unreadable, which is the failure the type above exists for.
    static func readAll(from url: URL) -> [JournalRecord] { read(from: url).records }

    /// Removes every line whose **record** the decision accepts, and nothing else.
    ///
    /// This exists as a primitive rather than as a read + filter + a write, because that
    /// composition is **not safe**: the lock is released between reading and writing, and
    /// `LogTransactionIntent` appends while `perform()` runs off the main actor. An alert
    /// arriving in that gap — a real charge — would be read as absent and then written away by
    /// the rewrite. Here the read, the decision and the rename happen under one lock hold, so a
    /// concurrent append either lands before (and is considered) or after (and survives).
    ///
    /// A line that **fails to decode is carried through untouched** rather than dropped. It used
    /// to be lost by every rewrite, because the file was rebuilt by re-encoding the records
    /// `readAll` had managed to decode. A line the current schema cannot read is still evidence,
    /// and `JournalRecord`'s own note records the day a field was added and silently made every
    /// older line undecodable — exactly when this would have bitten.
    ///
    /// It cannot remove a damaged line, and that is deliberate rather than incidental: every
    /// caller here is deciding about rows the ledger derived, and nothing was ever derived from a
    /// line nothing could read. The retention purge is the one that matters — it runs on every
    /// foreground, and a version of it that swept damaged lines up would delete evidence it
    /// exists to preserve, because a damaged line has no readable `receivedAt` to age it either.
    /// `removeDamaged` is the separate door for the user-driven case.
    ///
    /// Returns the number of lines removed. Zero means the file was left byte-for-byte alone,
    /// which is what keeps an untouched journal from being rewritten on every foreground.
    ///
    /// Throws when the journal is present but cannot be read. A caller about to delete the
    /// store rows derived from these lines must not treat "could not read" as "not there":
    /// that would remove the row while the line survived, and the next drain would bring the
    /// row back — the exact failure the journal-first ordering exists to prevent.
    @discardableResult
    static func remove(
        from url: URL,
        where shouldRemove: @Sendable (JournalRecord) -> Bool
    ) throws -> Int {
        try rewrite(from: url) { line in
            guard case .record(let record) = line else { return false }
            return shouldRemove(record)
        }
    }

    /// Removes damaged lines — the ones no version of this app can read — chosen by the bytes
    /// they hold.
    ///
    /// A separate door rather than another `remove` overload, and the reason is not taste: two
    /// overloads differing only in what the closure takes are ambiguous at every trailing-closure
    /// call site, which turns a clear API into a compile error wherever it is used.
    ///
    /// Addressed by **bytes** rather than by position, for the same reason everything else here is
    /// addressed by identity: a rewrite renumbers every line in the file, so an index is a name
    /// that changes under the thing it names. Two damaged lines holding identical bytes are
    /// identical evidence, so removing both is the honest reading of "remove this line".
    @discardableResult
    static func removeDamaged(
        from url: URL,
        where shouldRemove: @Sendable (Data) -> Bool
    ) throws -> Int {
        try rewrite(from: url) { line in
            guard case .damaged(let bytes) = line else { return false }
            return shouldRemove(bytes)
        }
    }

    /// The one implementation of a rewrite, deciding line by line.
    ///
    /// The caller holds `lock`. Split from the two doors above so that the shape of the file —
    /// read, decide, rename under a single hold — exists once, and neither door can drift into
    /// open-coding a read-modify-write that is not atomic against a concurrent `append`.
    private static func rewrite(
        from url: URL,
        deciding shouldRemove: @Sendable (JournalLine) -> Bool
    ) throws -> Int {
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
            let bytes = Data(line)
            let record = String(data: bytes, encoding: .utf8)
                .flatMap { try? decoder.decode(JournalRecord.self, from: Data($0.utf8)) }

            if shouldRemove(record.map(JournalLine.record) ?? .damaged(bytes)) {
                removed += 1
                continue
            }
            // Appended as the original bytes, never re-encoded: a line that does not decode
            // has to come out of a rewrite exactly as it went in.
            replacement.append(bytes)
            replacement.append(0x0A)
        }

        guard removed > 0 else { return 0 }

        try writeAtomically(replacement, to: url)
        return removed
    }

    // MARK: - Writing

    /// Whether the file's last byte is the newline that frames a line.
    ///
    /// An absent, empty or unreadable tail counts as terminated: there is nothing there to fuse
    /// onto, and a guard that refused to write in the case it cannot inspect would turn a
    /// damaged file into a journal that stops accepting alerts altogether.
    private static func endsWithNewline(_ fd: Int32) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return true }

        var last: UInt8 = 0
        // `pread`, not `read`: the descriptor is `O_APPEND`, and this must not disturb the
        // offset the write below is about to use.
        let bytesRead = pread(fd, &last, 1, off_t(info.st_size - 1))
        return bytesRead == 1 && last == 0x0A
    }

    /// One `write(2)` for the whole record, which is what a regular file takes in the ordinary
    /// case. The loop is for the cases it does not — a signal, a short write — and it is the
    /// honest shape rather than a claim about atomicity: with `O_APPEND` each call lands at the
    /// end of the file, so the record stays whole in the ordinary case and is completed rather
    /// than truncated in the others.
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }

            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw JournalStoreError.systemCall("write")
                }
                offset += written
            }
        }
    }
}

/// Why a rewrite or an append was refused.
nonisolated enum JournalStoreError: LocalizedError, Equatable {
    /// The file is there and could not be read, as distinct from not being there at all.
    case unreadable

    /// The append could not be completed. Carries the system's own words, because an `errno` is
    /// the whole of the difference between "the disk is full", "the container is protected while
    /// the device is locked" and "the file is not there" — and this string is what reaches the
    /// phone, through the intent's result, when capture fails.
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The raw journal could not be read, so nothing was deleted."
        case .unwritable(let reason):
            "The raw journal could not be written: \(reason)"
        }
    }

    static func systemCall(_ name: String) -> JournalStoreError {
        .unwritable("\(name) failed: \(String(cString: strerror(errno)))")
    }
}
