//
//  MerchantKeyTests.swift
//  spending-trackerTests
//
//  The key a category is remembered under. Every spelling in here is a real descriptor from
//  `AlertCorpus` — the point of the function is these exact strings, not invented ones.
//

import Foundation
import Testing
@testable import spending_tracker

struct MerchantKeyTests {

    // MARK: - The cases that motivated the function

    /// One supermarket, three descriptors. Keyed on the raw string these are three merchants,
    /// so the AI would be asked three times and a hand-set rule would cover one spelling.
    @Test func oneStoreWithThreeSpellingsHasOneKey() {
        let keys = ["WHOLE FOODS MKT", "WHOLE FOODS MKT #12", "WHOLE FOODS MKT #1234"]
            .map(MerchantKey.normalize)

        #expect(Set(keys).count == 1, "\(keys)")
        #expect(keys.first == "WHOLE FOODS MKT")
    }

    /// The pair that differ by one space. This is the case a store-code rule alone misses.
    @Test func atrailingSpaceBeforeTheStoreCodeDoesNotSplitTheKey() {
        #expect(MerchantKey.normalize("BREEZE*00HS5MV") == MerchantKey.normalize("BREEZE *00HS5MV"))
        #expect(MerchantKey.normalize("BREEZE*00HS5MV") == "BREEZE")
    }

    /// Amex sends the clean name, Fidelity the issuer's domain plus a code. Both are Amazon.
    @Test func anAmexNameAndAFidelityDescriptorAgree() {
        let keys = ["AMAZON", "AMAZON.COM*MK1A2B3C4", "AT&T*WIRELESS PMT"]
            .map(MerchantKey.normalize)

        #expect(keys[0] == "AMAZON")
        #expect(keys[1] == "AMAZON")
        #expect(keys[2] == "AT&T", "& is part of a name and must survive")
    }

    // MARK: - The safe direction

    /// Distinct merchants must stay distinct. A false merge gives two shops one category and is
    /// invisible; a miss costs one API call.
    @Test func differentMerchantsKeepDifferentKeys() {
        let keys = ["PUBLIX", "WALMART", "CHICK-FIL-A", "DEEPSEERWEA",
                    "AIRBNB US SHORT TERM STAY", "NETFLIX.COM"]
            .map(MerchantKey.normalize)

        #expect(Set(keys).count == keys.count, "\(keys)")
    }

    /// A processor prefix is not the merchant. Collapsing to `SQ` would give every Square
    /// reader in the country one shared category, so a short stem falls back to the whole string.
    @Test func aProcessorPrefixIsNotTreatedAsTheMerchant() {
        let coffee = MerchantKey.normalize("SQ *COFFEE SHOP")
        let bakery = MerchantKey.normalize("SQ *BAKERY")

        #expect(coffee != bakery, "two Square merchants were merged")
        #expect(coffee.contains("COFFEE"))
    }

    /// A digit that is part of the name is not a store number.
    @Test func aSingleDigitSurvives() {
        #expect(MerchantKey.normalize("7 ELEVEN") == "7 ELEVEN")
        #expect(MerchantKey.normalize("76") == "76", "a name cannot reduce to nothing")
    }

    // MARK: - Edges

    @Test(arguments: ["", "   ", "\n"])
    func blankMerchantsHaveNoKey(_ merchant: String) {
        #expect(MerchantKey.normalize(merchant).isEmpty)
    }

    /// Never empty for a merchant that had anything in it. An empty key would let one
    /// unreadable merchant collide with every other one.
    @Test(arguments: ["1234", "#12", "***", "12 34"])
    func aDescriptorThatIsOnlyNumbersStillYieldsAKey(_ merchant: String) {
        #expect(!MerchantKey.normalize(merchant).isEmpty, "\(merchant) produced no key")
    }

    /// The key is what the model is shown and what a rule is matched on, so it has to be stable
    /// across repeats rather than merely equal for these inputs.
    @Test func theKeyIsIdempotent() {
        for merchant in ["BREEZE*00HS5MV", "WHOLE FOODS MKT #1234", "NETFLIX.COM"] {
            let once = MerchantKey.normalize(merchant)
            #expect(MerchantKey.normalize(once) == once, "\(merchant)")
        }
    }
}
