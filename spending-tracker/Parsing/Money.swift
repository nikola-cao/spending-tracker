//
//  Money.swift
//  spending-tracker
//
//  Amount parsing, shared by every alert source.
//

import Foundation

/// Turns a currency string into integer minor units.
///
/// Shared deliberately. Two parsers each carrying their own copy of this is two chances for
/// them to disagree, and a disagreement here is a wrong number — the one kind of error this
/// project treats as worse than a missing row.
nonisolated enum Money {

    /// A card charge above this is not a real transaction. Capping here is also what makes the
    /// integer arithmetic provably overflow-free: the whole part is bounded, so `whole * 100`
    /// cannot exceed `Int.max` and trap the process, which it previously did.
    static let maximumMinor = 100_000_000_000   // $1,000,000,000.00

    /// Strict shape: a plain integer, or comma-grouped in threes, with an optional one- or
    /// two-digit fraction.
    ///
    /// The grouping rule is load-bearing. Stripping commas unconditionally turned `"2,50"` — a
    /// decimal comma from any locale-aware hop — into 25000 minor units, quietly restating a
    /// $2.50 charge as $250.00. Rejecting is the only safe answer, because `"1,204"` is
    /// genuinely ambiguous between the US thousands reading and the European decimal one, so
    /// there is no correct guess available.
    private static let shape = #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]{1,2})?$"#

    static func minorUnits(from rawAmount: String) -> Int? {
        guard rawAmount.range(of: shape, options: .regularExpression) != nil else { return nil }

        let cleaned = rawAmount.replacingOccurrences(of: ",", with: "")
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = Int(parts.first ?? "") else { return nil }

        // Bounded before multiplying, so the arithmetic below cannot overflow and trap.
        guard whole >= 0, whole <= maximumMinor / 100 else { return nil }

        // No decimal part at all ("$36") means zero cents, not an error.
        guard parts.count == 2 else { return whole * 100 }

        let fraction = parts[1]
        guard fraction.count <= 2, let value = Int(fraction) else { return nil }
        // A single digit means tenths, not hundredths: "$1.5" is 150 cents.
        let cents = fraction.count == 1 ? value * 10 : value
        let minor = whole * 100 + cents
        guard minor <= maximumMinor else { return nil }
        return minor
    }
}
