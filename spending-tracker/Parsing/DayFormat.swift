//
//  DayFormat.swift
//  spending-tracker
//
//  The one way a date is written into, and read out of, the raw journal.
//

import Foundation

/// The `yyyy-MM-dd` format every hand-written journal line uses.
///
/// Shared rather than owned by one parser, because more than one writer now produces these
/// lines and they have to agree. An edit line that spelled a date differently from the manual
/// line it edits would be refused by the reader, and the failure would look like the edit
/// simply not saving.
nonisolated enum DayFormat {

    static let pattern = "yyyy-MM-dd"

    /// `en_US_POSIX` deliberately: the journal is read back on whatever locale the device is
    /// set to, and a formatter that follows the locale would write `2026-09-25` and later
    /// refuse it. Same reason the amount format is built by hand rather than by `FormatStyle`.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }

    /// Noon on the day as written, which is the convention for a date with no time on it.
    ///
    /// Midday rather than midnight so a later timezone shift cannot drag the row onto the day
    /// before — the same reason the Amex parser lands its date there. Returns nil when the text
    /// is not a readable date, which callers must treat as a rejection rather than an absence.
    static func noon(fromDayText text: String) -> Date? {
        guard let day = formatter.date(from: text) else { return nil }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }
}
