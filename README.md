# spending-tracker

An iOS app that shows credit-card spending as it happens, fed by the transaction-alert
texts Fidelity sends for every card purchase.

**Current stage: 1 — prove the pipe.** The app records the exact string the Shortcut
hands it, plus facts about where that code ran, and shows them on one screen. It parses
nothing and stores no transactions yet.

> **Status (2026-09-21) — Stage 1 complete.** Verified on a real iPhone: a Message
> automation filtered on `Fidelity` reaches `LogTransactionIntent` with the phone
> **locked and screen off**, and the intent runs in the app's **own process**
> (`processName = spending-tracker`). That confirms the iOS 27
> `allowedExecutionTargets = .main` pin holds — the last open question in the design.
> (In the confirming capture, `®:n` was correct: the test string `"Fidelity test locked"`
> contains no registered-trademark sign. On a real alert, `®:n` would mean transcoding
> damage.)
>
> It also validates the automation → *Run Shortcut* → sub-shortcut indirection that
> iOS 26's restricted automation action list forces.
>
> **Stage 2 complete (2026-09-22).** The parser extracts an amount, card, merchant and
> verb from a raw body, and is hardened against an adversarial corpus. See below.
>
> Note the journal rows so far are synthetic: a real Fidelity alert has not yet flowed
> end-to-end, though every stage of the path is now individually proven.

## The parser

`FidelityAlertParser` is a pure function — no store, no UI, no async — so it is fully
testable without the app or the automation. Stage 3 will persist its output; today the
journal screen calls it at display time, so nothing is stored and the journal remains the
only source of truth.

**A rejected parse is better than a wrong number.** Where the input is ambiguous, the
parser discards the match rather than guessing. A discarded alert is *visibly* absent from
the parsed output; a wrong amount is not visible at all. This is why:

- `$2,50` (a decimal comma from any locale-aware hop) is **rejected**, not read as `$250.00`.
  `1,204` is genuinely ambiguous between the US thousands reading and the European decimal
  one, so there is no safe guess. A rejected row simply shows no parsed line.
- An amount above `$1,000,000,000` is rejected, which also makes the integer arithmetic
  provably overflow-free. (`whole * 100` on an absurd amount previously overflowed `Int64`
  and **trapped the process** — an uncatchable crash, not a returned error.)

Other guards, each one a shape that produced a wrong value before it existed:

| Guard | Without it |
|---|---|
| `[0-9]` not `\d` for the card number | ICU's `\d` matches any Unicode digit, so Arabic-Indic digits were captured as the card and could never match the real card |
| Trailer matched loosely, then the descriptor cleaned | An HTML-escaped `&amp;` or a trailer truncated to `Msg&Dat` let the merchant absorb the boilerplate |
| Descriptor may not start with sentence punctuation | An empty descriptor became a phantom row whose merchant *was* the boilerplate |
| Newlines flattened, zero-width characters stripped | `.` cannot cross a newline, so any newline inside an alert made every terminator unreachable and the charge vanished |
| Tempered capture, stopping at the next alert's preamble | An unterminated alert's lazy capture swallowed the *next* alert whole, losing a well-formed purchase |

**Known and accepted**, not fixed:

- An alert **embedded** in another message (a support transcript quoting one, a forward)
  parses identically to a live alert. Unfixable at this layer — the ledger must handle it.
- An **unterminated** alert followed by a good one is lost; the good one survives. Lossy,
  but strictly better than losing both, which is what happened before.
- Non-charge verbs (`refunded`, `declined`) still yield an amount-bearing result, flagged
  as `kind != .charge`. Consumers must filter on `isCharge` rather than assume. Flagging
  beats dropping: a format change should be visible, not silent.

Everything else is ordinary app work.

## Scope

Only **charge** alerts are in scope. The card is configured to alert on charges and those
are the only texts received, so the parser (Stage 2) needs only the `was charged` form.
Declines, refunds, and other alert types are deliberately **not** handled — no review
queues, no exclusion flags, no dedup paths for them.

---

## Setup

### 1. Set your alert threshold (do this first)

In the Fidelity/Elan card portal, set the transaction-alert threshold to the **minimum**
and enable **both** "A transaction has been authorized" and "Debits posted to your
account". If the threshold is, say, $50, every coffee is invisible and the ledger is
silently incomplete in the direction you cannot detect.

### 2. Shortcut

Create a shortcut named **`Log Alert`** with exactly two actions:

```
[Log Transaction Alert]   Message: ← Shortcut Input
[Show Notification]       ← Log Transaction Alert result
```

Wiring `Message` to **Shortcut Input** is the step most likely to go wrong. If the body
arrives empty, the journal will say `rejected: empty input` — that is the tell.

### 3. Automation

Shortcuts → **Automation** → **+** → **Message**:

| Setting | Value |
|---|---|
| Sender | empty |
| Message Contains | `Fidelity` |
| Run Immediately | **on** (not "Run After Confirmation") |
| Action | **Run Shortcut → `Log Alert`** |

Then Shortcuts → Privacy → **Allow Running When Locked** → **ON**. That is a *separate*
toggle from "Run Immediately" and both must be right. Its location has moved between iOS
releases — look for a global Shortcuts privacy setting.

> **Do not swipe this app away in the App Switcher.** iOS will not background-launch a
> force-quit app, so capture silently stops. The symptom is identical to a broken trigger.
> Also launch the app by hand once after every install.

### 4. Testing it

1. Run `Log Alert` manually with a pasted alert body → a row appears.
2. Automation with the phone **unlocked**, texted from a second phone → a row appears.
3. **Phone locked, screen off, in your pocket** → a row appears. ← the real test
4. A real purchase → a row appears with `rx:y`.

iMessage from a second phone and SMS from a shortcode take different paths through the
trigger, so step 3 does not fully prove step 4.

---

## Reading the diagnostic

The notification reports what happened without needing Xcode:

```
ST1 ok|spending-tracker|main:0|chars:231|rx:1|fid:1|grp:0
```

| Field | Meaning |
|---|---|
| `spending-tracker` | The process that ran. **Anything else means the App Intent did not run in the app's own process** — the journal may have gone somewhere the app cannot read. |
| `main:0` | Ran off the main thread, as a background intent should. |
| `chars:231` | Length of the string received. A short count means truncation. |
| `rx:1` | The `®` (U+00AE) survived. **The sharpest test of "did the whole string arrive"** — it is the only non-ASCII character in a real alert, so encoding damage shows up here and nowhere else. |
| `fid:1` | It **mentioned Fidelity** — the pipe is carrying card traffic. `0` means the pipe works but Shortcuts handed it something unrelated. Deliberately recall-only: `1` does not mean "this is a transaction". Telling those apart is the parser's job (Stage 2). |
| `grp:0` | No App Group container. Expected on a free Apple ID; only matters if the process name is wrong. |

The app's first screen repeats these per record and carries a **staleness banner**.

---

## Known constraints

- **Signing expires every 7 days** on a free Apple ID. After that the app will not launch
  and capture stops *silently* — the Shortcut still fires, the intent just never runs.
  Re-sign from Xcode (⌘R) weekly. The staleness banner turns red after 48 hours of no
  captures, which is the only warning you get.
- **"Every transaction the moment it occurs" is not literally achievable.** SMS delivery
  is best-effort, and each purchase generates 2–3 alerts (authorized, posted, plus
  card-not-present/international variants). A statement import will eventually be the
  ledger of record; SMS is the real-time accelerant on top.
- **Texts only.** There is no email redundancy configured, so a silent trigger failure has
  no second path to fall back on.

---

## Development

```sh
# build
xcodebuild -project spending-tracker.xcodeproj -scheme spending-tracker \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ./DerivedData build

# unit tests
xcodebuild -project spending-tracker.xcodeproj -scheme spending-tracker \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath ./DerivedData -only-testing:spending-trackerTests test
```

### Layout

```
spending-tracker/
  Journal/          append-only JSONL journal + runtime diagnostics
  Intents/          LogTransactionIntent — the only App Intent
  ContentView.swift the journal list and staleness banner
```

New `.swift` files are picked up automatically — the project uses
`PBXFileSystemSynchronizedRootGroup`, so no `project.pbxproj` edits are needed.

### Three build settings that change how code must be written

Not Xcode defaults, and they bite:

| Setting | Consequence |
|---|---|
| `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` | Every unannotated type is `@MainActor`. Shared value types must be explicitly `nonisolated` or they cannot be used from an intent. |
| `SWIFT_APPROACHABLE_CONCURRENCY = YES` | Infers *isolated* conformances — a default-isolated struct's `Codable` conformance becomes main-actor isolated. |
| `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` | Every file must explicitly import what it uses. |

Two further traps, both verified against the iOS 27 SDK:

- `JSONEncoder` has **no** `.iso8601WithFractionalSeconds`. Timestamps have one-second
  resolution, so **record order comes from file position, never from the timestamp.**
- `Thread.isMainThread` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` and cannot be read from
  `perform()`'s `async` body — hence `RuntimeFacts`.

Also: a long concatenation of interpolated ternaries blows the type checker
("unable to type-check this expression in reasonable time"). Build such strings as an
array and `joined(separator:)`.
