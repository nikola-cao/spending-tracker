//
//  DeepSeekClient.swift
//  spending-tracker
//
//  The classifier, over an HTTP API.
//

import Foundation

/// Asks DeepSeek what a merchant is, in batches.
///
/// **No SDK.** The request is a handful of JSON fields and the reply is one more, over an
/// endpoint that is OpenAI-compatible — so a `Codable` request and `URLSession` are the whole
/// client. Adding a dependency here would put the first third-party code in a project that has
/// none, to save about a hundred lines.
///
/// Three details of this API are load-bearing and are easy to get wrong:
///
/// 1. **Thinking is on by default** at high effort on the current models, and it bills reasoning
///    tokens at the output rate. Left alone, the service would spend them deciding what
///    "CHICK-FIL-A" is. It is turned off explicitly on every request.
/// 2. **The JSON mode enforces syntax, never the schema.** The reply is guaranteed to be valid
///    JSON and is not guaranteed to be *this* JSON, so the vocabulary is checked here, in
///    `labels(from:for:)`, rather than trusted.
/// 3. **The reply can come back empty or truncated.** The docs say so. Empty is a transient
///    failure and is retried; a truncated one is refused rather than half-read.
nonisolated struct DeepSeekClient: CategoryClient {

    /// The cheap, fast tier. The current model ids took over from `deepseek-chat` and
    /// `deepseek-reasoner`, which no longer exist; there is one model family now, with reasoning
    /// as a per-request switch rather than a separate model.
    static let defaultModel = "deepseek-flash"

    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    /// How many merchants travel in one request.
    ///
    /// By prompt rather than by any API affordance — the context window is enormous and the ids
    /// and descriptors are a few words each. It is also why a first run over a long history is a
    /// handful of requests instead of one per shop.
    static let batchLimit = 40

    let apiKey: String
    let model: String
    let transport: Transport

    /// Injected so the encoding and the decoding can be tested against canned bytes, with no
    /// socket and no key. It is also the seam that keeps a live call out of the test run.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        apiKey: String,
        model: String = DeepSeekClient.defaultModel,
        transport: @escaping Transport = DeepSeekClient.liveTransport
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    /// A session of this feature's own, so the timeouts are its own.
    ///
    /// It has to be its own: `timeoutIntervalForResource` defaults to **seven days**, which is
    /// harmless for a request someone is waiting on and not harmless at all here — one request
    /// stalled in a tunnel would sit there for as long as the process lives, and the next
    /// foreground would start a second one beside it.
    ///
    /// `ephemeral` so nothing about these requests is cached on disk. They carry a merchant
    /// descriptor and the key; neither belongs in a URL cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        // The request is retried at the next foreground anyway, so waiting for a network that
        // has not arrived buys nothing and holds the pass open while it does not.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static let liveTransport: Transport = { request in
        try await session.data(for: request)
    }

    // MARK: - The call

    /// Makes one request.
    ///
    /// **The framing runs on the caller's actor; only the wait is off it.** This target builds
    /// with `SWIFT_APPROACHABLE_CONCURRENCY`, under which a `nonisolated async` function inherits
    /// the caller's isolation — so encoding the body and reading the reply both happen on the
    /// main actor, and only the `await` on the transport suspends away from it. That is fine here
    /// (the payload is a few hundred bytes of JSON) and is written down because the obvious
    /// reading of `nonisolated` — that all of it runs elsewhere — is wrong under these settings.
    /// Moving it off would mean `@concurrent` on this method *and* on the protocol requirement.
    func classify(_ requests: [CategoryRequest]) async throws -> [String: String] {
        guard !requests.isEmpty else { return [:] }

        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 20
        urlRequest.httpBody = try Self.body(for: requests, model: model)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch {
            // A transport error is never about the merchant. `URLError` covers no network, a
            // timeout, a refused connection and a lost one.
            throw CategoryClientError.transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CategoryClientError.transient("the reply was not an HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            break

        // About the key or the account. Nothing about any merchant was tested, so nothing about
        // any merchant is remembered — the run stops and the user is told what to fix.
        case 401, 402, 403:
            throw CategoryClientError.blocked(
                Self.serviceMessage(from: data) ?? "the API key was refused")

        // About this request, which is this app's fault and would repeat for every merchant.
        case 400, 404, 422:
            throw CategoryClientError.blocked(
                Self.serviceMessage(from: data) ?? "the request was rejected (HTTP \(http.statusCode))")

        // Busy, or too fast. Both pass.
        case 408, 429:
            throw CategoryClientError.transient("the service is busy (HTTP \(http.statusCode))")

        default:
            // Every 5xx, and anything unforeseen. The service is having a bad time; the merchant
            // is fine, and so is the key.
            throw CategoryClientError.transient("the service returned HTTP \(http.statusCode)")
        }

        guard let reply = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw CategoryClientError.transient("the reply could not be read")
        }

        // Truncated. Refused rather than read for whatever landed before the cut, because a
        // half-finished object is a shape this code would have to guess at.
        if reply.choices.first?.finish_reason == "length" {
            throw CategoryClientError.transient("the reply was cut off before it finished")
        }

        guard let content = reply.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // The docs warn this happens occasionally. Whitespace counts: an empty reply is not
            // an answer about any merchant, so it buys a retry rather than being recorded as one.
            // Left untrimmed it would read as a reply that answered nothing, which is a different
            // claim — and one that would let a broken service look like a working one.
            throw CategoryClientError.transient("the reply carried no content")
        }

        return Self.labels(from: content, for: requests)
    }

    // MARK: - The request

    static func body(for requests: [CategoryRequest], model: String) throws -> Data {
        let request = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: payload(requests)),
            ],
            temperature: 0,
            // Small and bounded. The default output budget runs to thousands of tokens, and this
            // answer is a few dozen even at forty merchants.
            max_tokens: 512,
            response_format: .init(type: "json_object"),
            thinking: .init(type: "disabled"),
            stream: false
        )
        return try JSONEncoder().encode(request)
    }

    /// The merchants as the model reads them: one JSON array of id and descriptor.
    ///
    /// The id is the normalised key, which is also what the reply is read back against — so no
    /// identifier for a transaction, a card or a person is ever sent, and the reply cannot be
    /// mapped onto the wrong row even if two rows share a merchant.
    private static func payload(_ requests: [CategoryRequest]) -> String {
        let items = requests.map { ["id": $0.key, "merchant": $0.merchant] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(items),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    /// The instruction. Three things in it are requirements rather than style.
    ///
    /// 1. The literal word **json**, and 2. a worked example. The API's JSON mode documents both
    ///    as necessary, and without them the mode is not engaged at all and the reply is prose.
    /// 3. The vocabulary, enumerated and closed — because the API enforces JSON *syntax* here and
    ///    nothing more, so the schema is this app's job. `labels(from:for:)` accepts these five
    ///    and treats anything else as no answer.
    ///
    /// The category descriptions exist because the descriptors are often not words: a truncated
    /// issuer string like `DEEPSEERWEA` or `BREEZE*00HS5MV` is what actually arrives, and a list
    /// of bare nouns gives the model nothing to reason with.
    static let systemPrompt = """
        You label transactions with a spending category.

        Reply with a JSON object only, mapping each id you were given to exactly one category:
        {"<id>": "<category>"}

        The category must be exactly one of: dining, grocery, retail, transportation, \
        miscellaneous.

        dining — restaurants, cafes, bars, coffee shops, takeaway and food delivery.
        grocery — supermarkets and food shops.
        retail — shops, online stores, clothing, electronics, household goods.
        transportation — fuel, parking, transit, rideshare, flights, hotels, car hire.
        miscellaneous — anything else: bills, subscriptions, utilities, fees, insurance, income, \
        and anything you cannot tell.

        The names are transaction descriptions. They are often abbreviated or truncated, and a \
        person-to-person payment arrives as a short note instead of a merchant — "Dinner", \
        "Panda", "Kimchi red". Categorise a note by what it names, not by the person it came \
        from; there is no person in what you are given.

        Do your best with what is there. If a description is genuinely ambiguous, answer \
        miscellaneous. Never invent a category. Never explain.

        Example: {"AMAZON": "retail", "CHICK FIL A": "dining", "SHELL OIL": "transportation", \
        "DINNER": "dining", "PANDA": "dining"}
        """

    // MARK: - The reply

    /// Reads the id → label map out of the reply, keeping only what can be trusted.
    ///
    /// The reply is found by scanning for the first balanced `{…}` rather than by decoding the
    /// whole string, because JSON mode guarantees valid syntax and says nothing about prose
    /// around it — a reply wrapped in a sentence, or fenced in backticks, still yields its
    /// answers instead of failing the batch.
    ///
    /// Then every value is checked against the five tokens. **A label outside the vocabulary is
    /// a declined answer, not an answer to file under Miscellaneous.** That is the same rule the
    /// parsers hold — a rejected value beats a fabricated one, because a wrong bucket is
    /// invisible in a way a missing one is not. A reply of "eating out" is the model saying it
    /// did not follow the instructions, and honouring it would put a guess into the figures.
    ///
    /// The mismatch between this and `SpendingCategory.isWellFormed` is deliberate: a *journal
    /// line* may name a category this build has never heard of, because the journal outlives the
    /// code and must stay readable. A *model's* answer may not, because nothing has to stay
    /// readable — it is being written now, and it can simply be refused.
    static func labels(from content: String, for requests: [CategoryRequest]) -> [String: String] {
        guard let object = firstJSONObject(in: content),
              let decoded = try? JSONSerialization.jsonObject(with: object) as? [String: Any]
        else { return [:] }

        let asked = Set(requests.map(\.key))
        var labels: [String: String] = [:]
        for (key, value) in decoded {
            // **Only a string counts as an answer**, and a value of any other type is read as
            // this one merchant being declined.
            //
            // Decoding into `[String: String]` would have been shorter and would have been
            // wrong in a way that is easy to miss: one `null`, number, array or nested object
            // anywhere in the reply makes the whole decode throw, so a single bad value would
            // discard the answers for all forty merchants beside it. That is the exact trade
            // `CategoryClient.classify` promises not to make.
            guard let text = value as? String else { continue }

            let token = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard asked.contains(key), SpendingCategory.isKnown(token) else { continue }
            labels[key] = token
        }
        return labels
    }

    /// The first balanced `{…}` in a string, as UTF-8.
    ///
    /// Balanced rather than "up to the last brace", and string-aware: the payload is a map of
    /// merchant names, and a name containing a brace or a quote is not far-fetched. A scanner
    /// that counted braces inside a string literal would cut the object in the wrong place.
    ///
    /// The two guards that make it survive *prose around* the object are both load-bearing, and
    /// both were missing at first. Quotes are only tracked once the object has been entered, so
    /// an odd quote in the sentence before it cannot flip the state and hide the closing brace.
    /// And a `}` at depth zero is skipped rather than treated as an error, because a stray one
    /// in that sentence would otherwise make a perfectly good object unreachable.
    static func firstJSONObject(in text: String) -> Data? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]

            if escaped { escaped = false; continue }

            if depth > 0 {
                if inString, character == "\\" { escaped = true; continue }
                if character == "\"" { inString.toggle(); continue }
                if inString { continue }
            }

            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start { return Data(text[start...index].utf8) }
            }
        }
        return nil
    }

    /// The service's own complaint, when it sent one, so a refused key can say why.
    ///
    /// Truncated before it is shown. It is a third party's text being put on a screen, and the
    /// only thing this needs from it is a sentence.
    private static func serviceMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let message = envelope.error?.message,
              !message.isEmpty
        else { return nil }
        return String(message.prefix(200))
    }
}

// MARK: - The wire format

/// The chat request, in the wire's spelling.
///
/// The property names are the JSON field names, snake_case and all, rather than camelCase behind
/// a `CodingKeys`. These types exist to be encoded and never to be read by anything but the
/// decoder, and a parallel set of mappings is one more place for a field to be renamed on one
/// side only — which would not fail to compile, and would silently send the wrong request.
///
/// `nonisolated` on every one: this target defaults unannotated types to `@MainActor`, and with
/// inferred isolated conformances an unannotated `Codable` here would get a main-actor-isolated
/// conformance — tying these types to one actor for no reason, and making it impossible to move
/// the request off it later without revisiting all of them.
private nonisolated struct ChatRequest: Encodable {

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    struct Thinking: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let max_tokens: Int
    let response_format: ResponseFormat
    let thinking: Thinking
    let stream: Bool
}

private nonisolated struct ChatResponse: Decodable {

    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message

        /// `length` means the reply was cut off at `max_tokens`, which is a half-written answer
        /// rather than a short one.
        let finish_reason: String?
    }

    let choices: [Choice]
}

/// The service's error shape, for its message only.
private nonisolated struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let message: String?
    }
    let error: Body?
}
