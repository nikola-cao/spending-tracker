//
//  CategorizationIdentity.swift
//  spending-tracker
//
//  What a row is categorised by, and keyed on.
//

import Foundation

/// The string a category is about, for a row or for a descriptor the form is holding.
///
/// **One owner, because three places have to agree.** The classifier asks a question keyed by
/// this string, a `MerchantCategory` line stores it, and `applyCategories` resolves rows by it.
/// If any one of them derived it differently, an answer would be written for one key and looked
/// up under another — the rule would exist, be correct, and never apply.
///
/// For almost everything the answer is the descriptor itself: the captured merchant, or the text
/// a person typed. The exception is a person-to-person payment, where the descriptor is
/// `Venmo: <name> - <note>`. There the note is the only part that says anything about *what was
/// bought* — "Dinner", "Panda" — and the name is not a merchant at all. Keying on the whole
/// string would make every payment to one friend a separate shop, and would hand a real person's
/// name to a third-party API to categorise a description that already names the purchase.
///
/// An empty result means there is nothing to categorise by (a Venmo with no note). Callers must
/// treat that as "not askable" rather than falling back to the whole descriptor, or the name
/// would leave the phone for an answer that cannot be guessed anyway.
nonisolated enum CategorizationIdentity {

    static func merchant(for descriptor: String) -> String {
        guard let note = VenmoAlertParser.note(fromMerchant: descriptor) else { return descriptor }
        return note
    }
}
