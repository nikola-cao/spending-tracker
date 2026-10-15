//
//  DeepSeekClientTests.swift
//  spending-trackerTests
//
//  What is sent, and what is believed of what comes back.
//
//  Every test here runs against a stubbed transport. The tests execute inside the app binary, so
//  a real request from here would leave the machine on every run of the suite.
//

import Foundation
import Testing
@testable import spending_tracker

struct DeepSeekClientTests {

    private let asked = [
        CategoryRequest(key: "WHOLE FOODS MKT", merchant: "WHOLE FOODS MKT #12"),
        CategoryRequest(key: "CHICK FIL A", merchant: "CHICK-FIL-A"),
    ]

    /// A reply as the API shapes it, wrapped around whatever content is being tested.
    private func reply(_ content: String, finishReason: String = "stop") -> Data {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data("""
            {"id":"x","choices":[{"index":0,"finish_reason":"\(finishReason)",
            "message":{"role":"assistant","content":"\(escaped)"}}]}
            """.utf8)
    }

    private func client(
        status: Int = 200,
        body: Data,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) -> DeepSeekClient {
        DeepSeekClient(apiKey: "test-key") { request in
            onRequest?(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    // MARK: - Reading the reply

    @Test func aPlainObjectIsRead() {
        let labels = DeepSeekClient.labels(
            from: #"{"WHOLE FOODS MKT":"grocery","CHICK FIL A":"dining"}"#, for: asked)

        #expect(labels == ["WHOLE FOODS MKT": "grocery", "CHICK FIL A": "dining"])
    }

    /// JSON mode guarantees the syntax and says nothing about prose around it, so the object has
    /// to be found rather than the whole string decoded.
    @Test func anObjectWrappedInProseOrFencesIsStillRead() {
        for content in [
            "Sure! Here you go:\n{\"CHICK FIL A\":\"dining\"}\nHope that helps.",
            "```json\n{\"CHICK FIL A\":\"dining\"}\n```",
            "\n\n{\"CHICK FIL A\":\"dining\"}",
        ] {
            #expect(DeepSeekClient.labels(from: content, for: asked) == ["CHICK FIL A": "dining"],
                    "\(content)")
        }
    }

    /// The rule the parsers hold, applied to the model: a value outside the vocabulary is
    /// **refused**, not filed under Miscellaneous. A wrong bucket is invisible; a missing one is
    /// not.
    @Test(arguments: ["eating out", "Groceries", "food", "", "dining or grocery"])
    func aLabelOutsideTheVocabularyIsRefused(_ value: String) {
        let labels = DeepSeekClient.labels(from: "{\"CHICK FIL A\":\"\(value)\"}", for: asked)
        #expect(labels.isEmpty, "accepted \(value)")
    }

    @Test func aLabelIsTrimmedAndLowercased() {
        #expect(DeepSeekClient.labels(from: "{\"CHICK FIL A\":\"  Dining \"}", for: asked)
                == ["CHICK FIL A": "dining"])
    }

    /// A reply that invents an id must not be able to write a line — even a well-formed one.
    @Test func anIdNobodyAskedAboutIsIgnored() {
        let labels = DeepSeekClient.labels(
            from: #"{"SOME OTHER SHOP":"retail","CHICK FIL A":"dining"}"#, for: asked)
        #expect(labels == ["CHICK FIL A": "dining"])
    }

    @Test(arguments: ["", "no json here", "{unclosed", "}}{"])
    func rubbishIsReadAsNothing(_ content: String) {
        #expect(DeepSeekClient.labels(from: content, for: asked).isEmpty, "\(content)")
    }

    /// The scan is string-aware. A brace inside a quoted value must not be counted, or the object
    /// would be cut at the wrong place — and the payload is a map of merchant names, where a
    /// stray brace is not far-fetched.
    @Test func aBraceInsideAStringIsNotCounted() throws {
        let content = "Here: {\"NOTE\":\"a { brace\", \"CHICK FIL A\":\"dining\"} done"
        let object = try #require(DeepSeekClient.firstJSONObject(in: content))
        let text = String(decoding: object, as: UTF8.self)

        #expect(text.hasPrefix("{"))
        #expect(text.hasSuffix("}"))
        #expect(DeepSeekClient.labels(from: content, for: asked) == ["CHICK FIL A": "dining"])
    }

    /// **One bad value must not cost the other thirty-nine their answers.** This is why the reply
    /// is not decoded as `[String: String]`: a single `null`, number, array or object anywhere in
    /// it would make that decode throw, and forty merchants would be declined over one of them.
    @Test func oneValueThatIsNotAStringDoesNotDiscardTheBatch() {
        let content = #"{"WHOLE FOODS MKT":null,"CHICK FIL A":"dining","THIRD":42,"FOURTH":{}}"#
        #expect(DeepSeekClient.labels(from: content, for: asked) == ["CHICK FIL A": "dining"])
    }

    /// Prose around the object may hold anything, including characters that would confuse a
    /// scanner that started counting before the object did.
    ///
    /// Three separate tests rather than one parameterized case, because a parameterized failure
    /// names the test and not the argument — and these three fail for completely different
    /// reasons, which is exactly what a name has to tell you apart.
    @Test func aStrayClosingBraceInTheProseDoesNotHideTheObject() {
        let content = "Here } you go: {\"CHICK FIL A\":\"dining\"}"
        #expect(DeepSeekClient.firstJSONObject(in: content) != nil, "no object found")
        #expect(DeepSeekClient.labels(from: content, for: asked) == ["CHICK FIL A": "dining"])
    }

    @Test func anOddQuoteInTheProseDoesNotHideTheObject() {
        let content = "He said \"this is fine: {\"CHICK FIL A\":\"dining\"}"
        #expect(DeepSeekClient.firstJSONObject(in: content) != nil, "no object found")
        #expect(DeepSeekClient.labels(from: content, for: asked) == ["CHICK FIL A": "dining"])
    }

    @Test func bracesBeforeTheObjectDoNotHideIt() {
        // Built by concatenation on purpose: written inline this reads as `}}{{"…`, which is two
        // opening braces and an unbalanced object — so the test would be asserting that a
        // malformed reply parses, and would fail for a reason that has nothing to do with prose.
        let content = "}}" + "{\"CHICK FIL A\":\"dining\"}"
        #expect(DeepSeekClient.firstJSONObject(in: content) != nil, "no object found")
        #expect(DeepSeekClient.labels(from: content, for: asked) == ["CHICK FIL A": "dining"])
    }

    // MARK: - Building the request

    @Test func theRequestAsksForJsonAndSaysWhatTheCategoriesAre() throws {
        let body = try DeepSeekClient.body(for: asked, model: "test-model")
        let text = try #require(String(data: body, encoding: .utf8))

        // The literal word "json" and a worked example are both documented requirements of the
        // JSON mode — without them the mode is not engaged and the reply is prose.
        #expect(text.lowercased().contains("json"))
        #expect(text.contains("Example:"))
        for token in SpendingCategory.all {
            #expect(text.contains(token), "the vocabulary must be stated: \(token)")
        }
    }

    @Test func thinkingIsTurnedOffAndTheAnswerIsBounded() throws {
        let body = try DeepSeekClient.body(for: asked, model: "test-model")
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // On by default at high effort, and billed at the output rate: left alone, the service
        // would spend reasoning tokens deciding what "CHICK-FIL-A" is.
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect(json["temperature"] as? Double == 0)
        #expect(json["stream"] as? Bool == false)
        #expect((json["max_tokens"] as? Int ?? 0) > 0)
        #expect((json["max_tokens"] as? Int ?? .max) < 4_000)
    }

    /// The merchants go as an id and a descriptor, and the id is the normalised key — so nothing
    /// about a purchase, a card or a person is sent, and the answer cannot land on the wrong row.
    @Test func onlyTheKeyAndTheDescriptorAreSent() throws {
        let body = try DeepSeekClient.body(for: asked, model: "test-model")
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(text.contains("WHOLE FOODS MKT"))
        #expect(text.contains("CHICK-FIL-A"), "the descriptor as the row spells it")
    }

    // MARK: - The call

    @Test func aGoodReplyBecomesLabels() async throws {
        let client = self.client(body: reply(#"{"CHICK FIL A":"dining"}"#))
        let labels = try await client.classify(asked)
        #expect(labels == ["CHICK FIL A": "dining"])
    }

    @Test func theKeyTravelsAsABearerToken() async throws {
        // Captured in a box so the concurrent transport can write to it.
        let seen = Box<String?>(nil)
        let client = self.client(body: reply("{}")) { request in
            seen.value = request.value(forHTTPHeaderField: "Authorization")
        }
        _ = try await client.classify(asked)
        #expect(seen.value == "Bearer test-key")
    }

    @Test func anEmptyBatchMakesNoRequest() async throws {
        let client = self.client(body: Data()) { _ in
            Issue.record("an empty batch should not be sent")
        }
        #expect(try await client.classify([]).isEmpty)
    }

    /// The documented failure mode. An empty reply is not an answer about any merchant.
    @Test(arguments: ["", "   "])
    func anEmptyReplyIsTransient(_ content: String) async {
        let client = self.client(body: reply(content))
        await #expect(throws: CategoryClientError.self) { try await client.classify(asked) }
    }

    @Test func aTruncatedReplyIsTransient() async {
        let client = self.client(body: reply(#"{"CHICK"#, finishReason: "length"))
        await #expect(throws: CategoryClientError.self) { try await client.classify(asked) }
    }

    /// A refused key or a request this app built wrongly. The whole run stops on these, and
    /// **nothing is remembered against any merchant** — which is the property that matters: a
    /// typo in the key must not march the entire ledger toward the daily retry ceiling.
    @Test(arguments: [401, 402, 403, 400, 404, 422])
    func aRefusedKeyOrRequestBlocksTheRun(_ status: Int) async {
        let client = self.client(status: status, body: Data(#"{"error":{"message":"no"}}"#.utf8))
        do {
            _ = try await client.classify(asked)
            Issue.record("HTTP \(status) should have blocked the run")
        } catch let error as CategoryClientError {
            guard case .blocked = error else {
                Issue.record("HTTP \(status) should be blocked, not \(error)")
                return
            }
        } catch {
            Issue.record("HTTP \(status) produced an unexpected error: \(error)")
        }
    }

    /// A busy or broken service says nothing about the merchant, so it must pass.
    @Test(arguments: [408, 429, 500, 502, 503])
    func aBusyOrBrokenServiceIsTransient(_ status: Int) async {
        let client = self.client(status: status, body: Data())
        do {
            _ = try await client.classify(asked)
            Issue.record("HTTP \(status) should have failed")
        } catch let error as CategoryClientError {
            guard case .transient = error else {
                Issue.record("HTTP \(status) should be transient, not \(error)")
                return
            }
        } catch {
            Issue.record("HTTP \(status) produced an unexpected error: \(error)")
        }
    }

    /// The transport itself failed. Nothing about the merchant was tested, so nothing about one
    /// may be remembered.
    @Test func aTransportFailureIsTransient() async {
        struct Boom: Error {}
        let client = DeepSeekClient(apiKey: "k") { _ in throw Boom() }
        do {
            _ = try await client.classify(asked)
            Issue.record("a transport failure should not be read as an answer")
        } catch let error as CategoryClientError {
            guard case .transient = error else {
                Issue.record("expected transient, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func aReplyThatIsNotJsonIsTransient() async {
        let client = self.client(body: Data("not json at all".utf8))
        do {
            _ = try await client.classify(asked)
            Issue.record("an unreadable reply should not be read as an answer")
        } catch let error as CategoryClientError {
            guard case .transient = error else {
                Issue.record("expected transient, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

/// A mutable box for a value a concurrent closure needs to write back.
///
/// `@unchecked Sendable` with a lock, rather than an actor: the transport is `@Sendable` and
/// synchronous, so there is nowhere to await.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
