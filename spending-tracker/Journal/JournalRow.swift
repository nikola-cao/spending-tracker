//
//  JournalRow.swift
//  spending-tracker
//
//  One line of the raw journal, drawn wherever it is shown.
//

import Foundation
import SwiftUI

/// One journal line.
///
/// Extracted for the same reason `TxnRow` is: the row is drawn by two callers' worth of
/// context and the body reads better without it inline. It now has callers in two files — the
/// Raw journal screen and the transaction detail — so it lives on its own rather than as a
/// private view inside `ContentView`.
///
/// No accessibility merging — the raw text has to stay its own element, which is how both a
/// person with VoiceOver and the UI test find the line they mean.
struct JournalRow: View {
    let record: JournalRecord

    /// A cap on the body's lines, or nil for all of it.
    ///
    /// The Raw journal always shows everything, because there the line *is* the screen. The
    /// transaction detail passes a cap: an Amex body is a whole email, and a destructive control
    /// below dozens of screenfuls of text is unreachable. That screen offers to expand it.
    var bodyLineLimit: Int? = nil

    /// True when this line was not written by this app, into this app's own container.
    ///
    /// Every line records the process that wrote it and the journal directory it went to, for
    /// exactly this: a write that landed somewhere the app cannot read is the one failure that
    /// loses an alert with no other trace anywhere. Nothing rendered those fields until now,
    /// which made an instrument that could not be read — the answer was in the file, and
    /// unreachable from the phone.
    private var writtenElsewhere: Bool {
        record.processName != RuntimeFacts.processName()
            || record.journalDirectory != JournalLocation.directoryPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // No phase chip: one line per alert now, so it would say the same thing on
                // every row. Older journals still hold an enter/result pair and simply read
                // as two lines with the same body.
                Text(record.receivedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if writtenElsewhere {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.red)
                }
                Spacer()
                Text(record.processName)
                    .font(.caption)
                    .foregroundStyle(writtenElsewhere ? Color.red : Color.secondary)
                Text("\(record.charCount) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.rawText)
                .font(.footnote.monospaced())
                .lineLimit(bodyLineLimit)
        }
        .padding(.vertical, 2)
    }
}
