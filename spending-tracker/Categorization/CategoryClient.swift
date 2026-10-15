//
//  CategoryClient.swift
//  spending-tracker
//
//  What the classifier is asked, and what it may answer.
//

import Foundation

/// One merchant waiting for an answer.
nonisolated struct CategoryRequest: Sendable, Equatable {

    /// The normalised key — what the answer is matched back on, and the id the request is keyed
    /// by.
    ///
    /// The key rather than anything belonging to a transaction, deliberately. The question is
    /// about a *merchant*, so the same question has the same name every time it is asked, and
    /// the id carries nothing about the purchase, the card or the person.
    ///
    /// It also means two spellings of one shop are one request. See `MerchantKey`.
    let key: String

    /// The descriptor exactly as the row spells it — the only thing the model actually reads.
    let merchant: String
}

/// Why an attempt produced no answers.
///
/// Two cases, and telling them apart is the whole of the retry policy. A **transient** failure
/// says nothing about the merchant, so it may not be held against one. A **blocked** failure says
/// nothing about the merchant either — it is about the key or the request — so it must not be
/// held against every merchant at once, which is what a run that kept retrying would do.
nonisolated enum CategoryClientError: Error, Equatable {

    /// The call did not complete: no network, a timeout, a refused connection, a rate limit, a
    /// server fault, or a reply that could not be read. Every one of these is about the *call*,
    /// so the merchant stays in the backlog and is asked about again later.
    case transient(String)

    /// The service answered, and the answer was about the request rather than the merchants: a
    /// refused or lapsed key, no credit, or a request this app built wrongly.
    ///
    /// Retrying cannot fix any of these and every merchant would fail identically, so a run that
    /// hits one stops rather than grinding the whole backlog through it — and **no merchant's
    /// attempt count moves**, because nothing about them was tested.
    case blocked(String)
}

/// Classifies merchants into categories.
///
/// A protocol rather than a concrete type for two reasons, and the second is not obvious. The
/// first is ordinary: the pass has to be testable without a socket. The second is that the tests
/// for this app run **inside the app binary** (`TEST_HOST`), where a live call would leave the
/// machine on every run — so the seam is not a nicety here, it is what keeps the suite honest.
nonisolated protocol CategoryClient: Sendable {

    /// One batch. Returns a label per key it could answer for.
    ///
    /// A key **absent** from the result is a declined answer rather than a failure: the reply
    /// arrived and this merchant could not be read out of it. That is deliberately not an error,
    /// because one unreadable merchant must not throw away the answers that came back beside it —
    /// forty merchants share a reply, and losing thirty-nine good answers to one bad word would
    /// be the worst trade available.
    func classify(_ requests: [CategoryRequest]) async throws -> [String: String]
}
