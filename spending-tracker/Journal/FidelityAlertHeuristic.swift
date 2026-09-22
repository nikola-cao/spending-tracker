//
//  FidelityAlertHeuristic.swift
//  spending-tracker
//
//  Stage 2's seam. Replaced wholesale once the real parser lands.
//

import Foundation

/// A deliberately crude "did this come from Fidelity at all".
///
/// This is pure RECALL, and the name is chosen to say so. It answers "is Shortcuts handing
/// me Fidelity traffic, or something unrelated?" — it does NOT try to answer "is this a
/// transaction?". The real parser (Stage 2) owns that question, and owns precision.
///
/// The implementation is a single `||` rather than a match on a known verb because a verb
/// match is exactly the trap this file fell into first. Requiring "charged" silently
/// rejected every *decline* alert ("was declined"), and would reject every future verb not
/// yet seen — which is the worst possible failure here, because a dropped decline is
/// invisible. A test caught it; the shape of the fix is to stop enumerating verbs at all.
nonisolated enum FidelityAlertHeuristic {

    /// True if the text plausibly originates from this card programme.
    ///
    /// `"card ending in"` is included alongside the brand name so that a message truncated
    /// before the word "Fidelity" still registers as ours rather than as unrelated noise.
    static func mentionsFidelity(_ raw: String) -> Bool {
        let folded = raw.lowercased()
        return folded.contains("fidelity") || folded.contains("card ending in")
    }
}
