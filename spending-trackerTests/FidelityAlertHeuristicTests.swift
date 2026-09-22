//
//  FidelityAlertHeuristicTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

struct FidelityAlertHeuristicTests {

    /// All five bodies captured from the user's real phone, plus an unseen verb and the
    /// transcoding variants. Recall is the only thing that matters at Stage 1: anything
    /// from this card programme must be journalled, even if we cannot yet parse it.
    @Test(arguments: [
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV. Msg&Data rates may apply. Reply STOP to cancel.",
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $5.30 at DEEPSEERWEA.",
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $31.79 at PICKUP* TRIAL OVER.",
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $36.00 at Georgia Tech Parking S.",
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $73.00 at CENTRAL ROCK MID (ATL).",
        // A verb we have never seen. This is the case that failed when the heuristic
        // matched on the word "charged" — a decline would have been silently dropped.
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was declined $12.00 at AMAZON.COM*MK1A2B3C4.",
        // Carrier transcoding of the registered sign, and no sign at all.
        "Fidelity(R) Credit Card: Your card ending in 7224 was charged $4.00 at CHICK-FIL-A.",
        "Fidelity Credit Card: Your card ending in 7224 was charged $4.00 at CHICK-FIL-A.",
        // Truncated before the brand name, so only the card phrase identifies it.
        "Your card ending in 7224 was charged $17.50 at WHOLE FOODS MKT #12",
    ])
    func cardTrafficIsRecognised(_ body: String) {
        #expect(FidelityAlertHeuristic.mentionsFidelity(body))
    }

    /// Deliberately asserting CURRENT behaviour rather than a wish. A statement notice IS
    /// from Fidelity, so it is correctly `true` here — `fid:1` means "the pipe is carrying
    /// Fidelity traffic", not "this is a transaction". Telling the two apart is Stage 2's
    /// job. If that ever changes, change this expectation deliberately.
    @Test func fidelityNonTransactionsStillCountAsFidelity() {
        #expect(FidelityAlertHeuristic.mentionsFidelity("Fidelity Investments: your statement is ready"))
    }

    @Test func unrelatedTrafficIsRejected() {
        #expect(!FidelityAlertHeuristic.mentionsFidelity("Your Uber code is 1234"))
        #expect(!FidelityAlertHeuristic.mentionsFidelity(""))
        #expect(!FidelityAlertHeuristic.mentionsFidelity("Want to grab lunch?"))
        #expect(!FidelityAlertHeuristic.mentionsFidelity("Your verification code is 90210"))
    }
}
