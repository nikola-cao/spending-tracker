//
//  AlertParsers.swift
//  spending-tracker
//
//  One entry point over every alert source.
//

import Foundation

/// Dispatches a raw body to whichever parser recognises it.
///
/// There is one parser per alert shape — a source may have more than one, and both Fidelity and
/// Amex do — and each is anchored on that shape's own envelope: the Fidelity charge parser on
/// `Fidelity® Credit Card:` followed by `Your card ending in … was charged`, the Fidelity
/// payment parser on `A payment of … has been posted to your account ending in`, the Amex
/// parser on `There was a large purchase on your Card`. Those anchors are disjoint, so a body
/// can only be claimed by the shape it actually is — and where two share a sender, the sentence
/// is what separates them, not the sender.
///
/// First match wins rather than merging results. A body belongs to one source, and running
/// every parser over every body would be an invitation for two of them to each find something
/// in the same text — which, in a ledger, means the same purchase counted twice.
nonisolated enum AlertParsers {

    /// Reflects every parser's version, so it moves whenever any of them changes. Each
    /// occupies one decimal digit — keep them under ten.
    static var version: Int {
        FidelityAlertParser.version * 100_000
            + FidelityPaymentParser.version * 10_000
            + AmexAlertParser.version * 1_000
            + AmexPaymentParser.version * 100
            + VenmoAlertParser.version * 10
            + ManualEntryParser.version
    }

    /// Every charge recognised in one body.
    ///
    /// HTML is flattened first, unconditionally. Amex alerts arrive as a full HTML document,
    /// and the Shortcut that captures them hands over markup rather than prose; SMS bodies
    /// have no tags and pass through unchanged, so the same call is correct for both.
    ///
    /// The sources have disjoint anchors — `Fidelity® Credit Card:` followed by the charge
    /// sentence or the payment one, `There was a large purchase on your Card`, `venmo@venmo.com`,
    /// and the `Manual |` line a typed entry is stored as — so a body can only be claimed by the
    /// source it actually came from.
    static func parseAll(_ raw: String) -> [ParsedAlert] {
        let text = HTMLText.extract(from: raw)

        // The order below is a **precedence**, and it reads charges first, then payments, then
        // everything else. It only ever decides anything for a body carrying more than one alert
        // — two texts pasted in as one entry — because first match wins and the rest of the body
        // goes with it. Charges come first because a purchase is the ledger's primary record:
        // losing one takes money out of the month as well as off the card, where losing a payment
        // leaves a balance that is merely too high. `AlertParsersTests` pins that ordering.
        let fidelity = FidelityAlertParser.parseAll(text)
        if !fidelity.isEmpty { return fidelity }

        // The Amex purchase alert next, and for the reason its own parser gives: it arrives with
        // an account line and a dollar figure of its own, and must never be read as a payment.
        let amex = AmexAlertParser.parseAll(text)
        if !amex.isEmpty { return amex }

        // Both payment parsers sit after both charge parsers for the precedence above, which is
        // the only reason the Fidelity payment is not beside the Fidelity charge it shares a
        // sender with. The two Fidelity sentences never match the same text, so nothing else
        // depends on the gap.
        let fidelityPayment = FidelityPaymentParser.parseAll(text)
        if !fidelityPayment.isEmpty { return fidelityPayment }

        let payment = AmexPaymentParser.parseAll(text)
        if !payment.isEmpty { return payment }

        // A Venmo email and a `Manual |` line are written alone — one per body, by their own
        // automation or by the app itself — so their position decides nothing, and they stay
        // last rather than being reordered to look tidy.
        let venmo = VenmoAlertParser.parseAll(text)
        if !venmo.isEmpty { return venmo }

        return ManualEntryParser.parseAll(text)
    }

    /// The first recognised charge, if any.
    static func parseFirst(_ raw: String) -> ParsedAlert? { parseAll(raw).first }
}
