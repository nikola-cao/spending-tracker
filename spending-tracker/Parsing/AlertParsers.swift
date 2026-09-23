//
//  AlertParsers.swift
//  spending-tracker
//
//  One entry point over every alert source.
//

import Foundation

/// Dispatches a raw body to whichever parser recognises it.
///
/// There is one parser per source, and each is anchored on that source's own envelope — the
/// Fidelity parser on `Fidelity® Credit Card:`, the Amex parser on `There was a large purchase
/// on your Card`. Those anchors are disjoint, so a body can only be claimed by the source it
/// actually came from.
///
/// First match wins rather than merging results. A body belongs to one source, and running
/// every parser over every body would be an invitation for two of them to each find something
/// in the same text — which, in a ledger, means the same purchase counted twice.
nonisolated enum AlertParsers {

    /// Bumped whenever ANY parser changes, so the drain re-derives history that an older
    /// version read. Combining the individual versions keeps this honest without a second
    /// thing to remember to update.
    static var version: Int { FidelityAlertParser.version * 100 + AmexAlertParser.version }

    /// Every charge recognised in one body.
    ///
    /// HTML is flattened first, unconditionally. Amex alerts arrive as a full HTML document,
    /// and the Shortcut that captures them hands over markup rather than prose; SMS bodies
    /// have no tags and pass through unchanged, so the same call is correct for both.
    static func parseAll(_ raw: String) -> [ParsedAlert] {
        let text = HTMLText.extract(from: raw)

        let fidelity = FidelityAlertParser.parseAll(text)
        if !fidelity.isEmpty { return fidelity }

        return AmexAlertParser.parseAll(text)
    }

    /// The first recognised charge, if any.
    static func parseFirst(_ raw: String) -> ParsedAlert? { parseAll(raw).first }
}
