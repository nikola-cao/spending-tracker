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
> **Stage 3 complete (2026-09-22).** The journal drains into SwiftData and the app is a
> real spending feed. See below.
>
> **Stage 4 in progress.** Manual entry and the diagnostics surface are done; review-queue
> actions and statement import are not. See below.
>
> **A second source added (2026-09-23).** Amex charges now arrive by email. See below.
>
> Note the journal rows so far are synthetic: a real Fidelity alert has not yet flowed
> end-to-end, though every stage of the path is now individually proven.

## The ledger

The App Intent is deliberately **not** involved. It keeps writing raw text to the journal,
and the app drains that journal into SwiftData when it becomes active. Writing at capture
time buys nothing — the UI only exists while the app is open — and leaving the intent alone
means nothing in Stage 3 can break the one component proven on real hardware.

Two models, and the split is load-bearing:

| | |
|---|---|
| `AlertEvent` | What **arrived**. Verbatim body, never rewritten. Every message, parsed or not. |
| `Txn` | What we **concluded**. Parsed charges and deposits. |

`Txn` contains *only* real movements of money, so the feed query needs no predicate. That is
structural rather than conventional — a forgotten predicate is exactly how an unparsed row
would silently pollute a total, and a wrong total is invisible.

Charges and deposits share the table and are told apart by `isDeposit`. The feed shows both,
because both are things that happened. **The month total counts charges only** — a Zelle you
received is not a negative cost, and folding it in would make a heavy month look cheap because
someone paid you back for rent. A refund is a different thing and is *not* excluded: it is a
negative charge, money the card gave back on spending that did happen.

**Dedup keys on the invocation, not the message.** This matters more than it looks: a
Fidelity body is a pure function of (card, amount, merchant) — no transaction id, no
timestamp — so a monthly `$15.49 at NETFLIX.COM` is *byte-identical* every month. Keyed on
the body, the second month onward is silently discarded with no row and no trace. The key is
`runID#matchIndex` from the journal, so a genuine repeat is recorded while a redelivery of the
same invocation is not.

**One journal line per alert.** Earlier versions wrote an `enter`/`result` pair — `enter` from
the shortest possible code path, `result` only after the whole write had run twice — so that a
lone `enter` localised a failure *between* the two. That question was worth asking while
Stage 1 was proving the pipe; it has not been since, and the pair cost a full second copy of
every body, which with ~60 KB Amex emails was the largest thing in the journal. Journals
written before the change still hold pairs, and the drain still collapses them by `runID`.

A near-identical charge — same card, amount and merchant within 5 minutes — is **flagged,
never merged**. Two identical charges are two real charges; flagging is recoverable, silent
merging is not.

**The store is derived.** It can be rebuilt from the journal, so a corrupt store is
recoverable by deleting it and letting the journal replay. The journal is the only thing
that must never lose a byte. `ledgerSchemaVersion` in the app target makes that automatic:
bump it when a property is renamed or removed and the store is rebuilt on next launch.

**The feed sorts on arrival, not on transaction time.** It is a log of what came in, so the
order must match the order it was received in. Two things break otherwise, and both were
visible on the real phone: every Amex row on a day shares one parsed date (the message has no
time), so same-day rows had *identical* sort keys and new ones landed underneath old ones; and
because Fidelity rows carry genuine arrival timestamps they all floated above every Amex row
regardless of which came in first. `Txn.receivedAt` is therefore its own field and
`Txn.occurredAt` is display-only. The near-duplicate window measures on arrival too — on
`occurredAt` it would call any two same-day Amex charges at one merchant duplicates.

**The month total is keyed on `occurredAt`, not `receivedAt`** — the best-known time of the
purchase, which is the date printed in the Amex email and the alert's arrival for Fidelity.
A charge that arrives late still belongs to the month it was made in.

**Deleting a charge removes its journal line too.** This is not a nicety: the store is
derived, so deleting only the row would have the next drain recreate it from the journal
within seconds. The journal is written *first*, and that order is deliberate — if the journal
edit lands and the store delete fails, the row is still on screen and can simply be deleted
again. The reverse order fails the other way: the row vanishes, then silently reappears, which
looks like a bug in the app rather than a failed write. There is a test for exactly that.

## Adding something by hand

The **+** button opens a form with two tabs, **Charge** and **Deposit**, and they share every
field but one: a deposit has no card. Both take a merchant, an amount and an optional date.

A deposit is a Venmo, a Zelle, a paycheck — money that does not come through a card. It becomes
an ordinary transaction and it also moves the bank balance immediately, which is why the bank
figure is worth reading straight after. Deleting a deposit row gives the bank back what it
took, since the row is the only record that the money ever moved.

### One month at a time

The feed and the Balance figure show the **current calendar month** and nothing else. The list
header names the month, and the total header has always.

**A filter, never a deletion.** Every row stays in the store, so the month rolling over costs
nothing and loses nothing. That is what makes a previous-months view a query rather than a
recovery — the history is already there, all of it, and always was.

The key is `occurredAt`, for the same reason the total uses it: a charge belongs to the month it
was *made* in. A purchase on the 30th that the card only tells you about on the 3rd stays in the
month it was spent.

Nothing is scheduled. The month is computed from `Date()` on every render, so the rollover
happens on the first render after midnight on the 1st — no timer, no background task, and
nothing that can get out of step. (It does mean an app left open across midnight keeps showing
the old month until something re-renders it; switching away and back is enough.)

The **bank balance is untouched** by all of this. It is folded from the whole journal, not from
the rows on screen, so a deposit from a month the list is no longer showing is still money that
moved.

### Remaining

The summary row is three figures: **Balance** (this month's charges), **Bank**, and **Remaining**
— the bank less the spend.

Remaining is derived from the other two rather than being a third number kept alongside them,
so the three cannot drift apart. It moves for both halves: a charge lowers it, money arriving
raises it.

Deposits reach it through the bank and not through the spend, which is the same rule as
everywhere else — a Zelle received is not a negative cost, and counting it as one would make a
heavy month look cheap.

The empty state distinguishes the two cases on purpose. "Nothing in October yet" with a full
store behind it reads very differently from "No transactions yet" — and the first of the month
is exactly when getting that wrong would look like everything had been thrown away.

### The bank balance is derived, not stored

It is **not** a field anywhere. Setting it writes a line to the raw journal, and the balance is
then folded out of that file: the last value set, plus every deposit after it.

```
Bank | 1200.00
```

That is the same bargain everything else here makes, and it was not always kept. The balance
used to live in `UserDefaults`, which meant it survived a rebuild only by accident — the journal
could not restore it, so a schema change would have rebuilt the ledger and left the bank stale
with nothing to explain the difference. Folding it from the journal also removes the bookkeeping
for deletion: removing a deposit's line removes its effect, with no code that adjusts anything.

A balance is an assertion about the world rather than a movement of money, which is why it is a
line of its own and not an enormous deposit. A deposit says "this arrived"; a balance says "this
is what is there", so it wins outright over everything before it.

### Editing a transaction

Tapping a row opens the same form, filled in. Editing writes another line rather than rewriting
the first one:

```
Edit | <runID>#<index> | <amount> | <yyyy-MM-dd> | <cardSuffix> | <merchant>
                the line it supersedes
```

**Appended, never edited in place.** The journal is append-only, and for a captured charge the
text is evidence — overwriting a Fidelity body because the merchant was mistyped would destroy
the only record of what the card actually said. The original stays and this line supersedes it
by naming it.

The name is the **occurrence key** the ledger already dedupes on, which is what makes the whole
thing rebuild-safe with no extra state: replaying the journal builds the row from the original
line, and this line lands on top of it in the same pass. Edits are re-applied in full on every
drain rather than tracked as done, so there is no "already applied" flag to fall out of step
with the store after a rebuild, a deletion, or a crash between the two.

**A date is set whole or cleared whole.** If the date changes, the row's time goes with it: a
Fidelity row's `occurredAt` is its *arrival*, a real time of day, and keeping that while
replacing the day would claim a time nobody ever stated. It becomes noon — the date-with-no-time
convention — and the row reads "Purchased \<date\>". Clearing the date puts it back to arrival,
exactly as omitting one does when adding.

An edit cannot change what a row *is*. There is no tab switch when editing: moving a charge to a
deposit would change whether it touches the bank, and "I mistyped the amount" is not a reason to
reclassify it.

Both amounts are **signed**. A refund is a negative charge; a deposit goes whichever way the
money did. `Money.minorUnits` still refuses a minus for the captured sources, where a negative
charge is a broken parse rather than a refund — only a person typing gets one, through
`Money.signedMinorUnits`.

### The Charge tab

A charge is: merchant, amount, purchase date, and the card's last digits.

**Only the merchant and the amount are required.** The date has a toggle that hides the picker
without changing how a date is chosen when it is on; leaving it off gives the charge no time of
its own, so the ledger falls back to when the entry was made and the row reads "Alerted" rather
than "Purchased". The card field is both a text input and a menu of every suffix captured so
far — typing covers a card never seen before, the menu covers the common case in one tap. A
card that *is* filled in must be four or five ASCII digits, and typing past five simply stops
appearing rather than being accepted and then refused on save.

An empty field means "not given", which is deliberately not the same as a field that is present
but wrong: a blank date is fine, but `23/09/2026` is rejected outright. Treating an unreadable
date as merely absent would quietly turn a typo into a charge dated today.

The form does **not** write a row straight into the store. It composes the fields into a
canonical line and journals it, exactly as a captured alert is journalled:

```
Manual | <charge|deposit> | <amount> | <yyyy-MM-dd> | <cardSuffix> | <merchant>
              required      required     optional       optional       required
```

`ManualEntryParser` reads it back on the next drain. That is more work than writing the row
directly, and it buys the whole point: a hand-entered entry is then an ordinary entry. It is
restored by a rebuild, covered by the retention window, removed from the raw journal when
deleted, and re-readable on any later launch. A row written straight into the store would do
none of those things and would be the one kind of row with its own rules.

A deposit is journalled for exactly that reason, and it is not a technicality: the store is
rebuilt from the journal whenever the schema changes, so a deposit that was never written here
would be gone at the next rebuild with nothing to restore it from.

Lines written before the kind field existed are still read, as charges — the journal is
append-only, and a line it already holds has to keep meaning what it meant when it was written:

```
Manual | <amount> | <yyyy-MM-dd> | <cardSuffix> | <merchant>
```

The two are told apart by the second field, because an amount is never spelled `charge` or
`deposit`.

**The merchant goes last, deliberately.** It is free text a person typed, so it may contain
anything — including the delimiter. Putting it at the end means everything after the fourth
field is the merchant, with nothing to escape or reject.

The amount is written as a canonical decimal built by hand rather than by `FormatStyle`, which
is locale-aware and would produce `1204,99` on a comma-decimal device — a value the parser
correctly rejects, breaking the round trip.

## Diagnostics

Under the **⋯** menu. Answers the two questions no other screen can — *is the automation
still capturing*, and *is anything arriving the parser can't read*. Both failures are
otherwise silent: the Shortcut keeps firing, or the alert is simply absent.

Shows last captured, last manual entry, counts of alerts and charges, the parser version in
force, and the journal's size. The journal can be shared out from here.

## Venmo

> **A third source (2026-10-02).** Venmo payment emails, forwarded by their own automation.

Venmo payments are **deposits**, not charges: positive when money arrived, negative when it
left. So they appear in the feed like anything else and they move the bank balance.

```
Venmo: Sarvesh Gade - Kimchi red
```

The merchant is the person and the note they attached, and the amount is signed by direction.

### What actually arrives is not the HTML

The Shortcut hands over text a Mail extractor has already produced, not markup. That extractor
**drops everything hidden**, which changes the problem in two ways at once:

- The forwarded header is gone, so there is no `venmo@venmo.com` to identify the sender by.
- The decimal point is gone, because Venmo hides it in a `display:none` span.

```text
Patrick Guo paid you
$
28
00
```

### Every one of these emails says it both ways round

In the raw HTML the visible body says what happened to the user — `Sarvesh Gade paid you` — and
a hidden `display:none` preheader says it from the other party's side: `You paid Sarvesh Gade
$28.00`. In a *sent* payment it reads the other way round again: `Patrick guo paid you $386.70`
above a visible `You paid Patrick Guo`.

`HTMLText` does not drop hidden elements — its job is to recover the text in the document, and
this text is in the document. So on the markup route **both phrasings are present**, and
neither can be trusted. A parser keyed on `You paid` would read every payment received as money
sent. That is a sign inversion, and it is the worst failure available here: the row still looks
entirely plausible and the bank moves the wrong way.

The extractor happens to remove the preheader, so the trap does not currently bite — but
nothing may depend on that, and the tests keep the markup bodies with the preheader intact for
exactly this reason.

Direction therefore comes from the lines that appear exactly once and in only one kind of
email: `Money credited to your Venmo account.` for money in, and `Payment Method` together with
`Sent from` for money out. A body with neither is **refused** — a missing row is recoverable
for a week, a wrong sign is a wrong number.

`Sent from` is required alongside `Payment Method` because that phrase on its own is one any
order confirmation can use, and the Amex automation has already shown these filters capture
more than they are meant to.

### The amount arrives in pieces

Venmo renders the figure as sibling elements — `$`, `28`, `.`, `00` — each a `<div>`, so
`HTMLText` puts every one on its own line. On the markup route the point survives, and joining
the pieces reproduces `$28.00`.

On the route that actually runs, the point has been dropped, leaving `$` `28` `00`. Joined
blindly that reads as `$2800` — a hundredfold error stated with total confidence.

So when there is no point, the **cents are taken to be the last element**, which is how the
template is built, and only when it is exactly two digits with a whole-part fragment before it.
`$` `28` `00` is `28.00`; `$` `28` `0` and `$` `28` `000` are refused, because there the shape
does not say where the cents begin and the readings are different amounts.

The run can only begin on a `$` line, and whatever is joined still has to survive the strict
currency parser, which is what makes a permissive fragment test safe.

## Payments

> **A fourth kind (2026-10-03).** Paying a card off. Manual entry only so far — see below.

A payment is its own kind, not a large deposit, because it is the one movement that comes off
**both** figures: **Balance**, because it settles spending that already happened, and **Bank**,
because the money left it.

It is stored as its **effect**, so the amount is negative even though the figure a person types
is what they paid:

```
Manual | payment | -825.77 | 2026-10-03 |  | AMEX PAYMENT
```

That keeps both summaries free of special cases. The bank fold takes every row that affects the
bank, and the spend takes everything that is not a deposit — so a payment reduces both by
simply being summed.

The sign is also why `isMoneyIn` asks the kind before the sign. A refund is green and a payment
is not, and both are negative: the naive rule would have coloured every payment as money
arriving.

**Not done yet: the email.** Amex's "We've received your payment" notification is not parsed.
The samples provided were Gmail *inbox* dumps rather than the email bodies, and the listing
snippet for this email carries no amount at all — so there is no figure to record. Everything
else is in place for it: a parser only has to emit `.payment` with a negative amount and the
rest follows.

## Only real movements of money reach the ledger

A body that resolves to nothing — a merchant's own confirmation email for a purchase Amex
already reported, a statement notice, an OTP — never becomes a ledger row, and nothing in the
app shows it to you.

But it is **not discarded on arrival either**. Anything that is not a charge or a deposit is
held in the raw journal for a week and then purged; charges and deposits are kept forever.

The week is what keeps the recovery path alive. A retained body is re-parsed on every drain,
so a charge that starts being recognised within the window is picked up with no special
handling and nothing to migrate. Past the week it is gone — the accepted cost of not carrying
junk indefinitely. A genuine charge that stops parsing is therefore recoverable for a week,
and silent after that.

The journal is the one thing in this app that must never lose data, so the purge is written
accordingly: it builds the replacement alongside the original and swaps it in with a single
rename, so an interruption leaves the original intact rather than a half-written file. It also
refuses to run at all if the store rejected the write — at that point the journal is the only
copy of anything.

## Still missing

- **Statement import and reconciliation.** The plan's ledger of record, but it needs a real
  statement export first. Building an importer against a guessed CSV format is the same
  mistake the parser nearly made before real messages arrived.
- **Editing a transaction.** Has a design problem worth deciding before building: the store
  is *derived* from the journal, so an edit is not durable — replaying the journal would
  discard it. Either edits get written back to the journal as their own record, or the store
  stops being fully derived and the recovery story changes.

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

## A second source: Amex email alerts

Amex doesn't offer per-purchase SMS — it moved those to email in September 2023 — so Amex
arrives through a second Shortcuts automation with an **Email** trigger. It reuses
everything: same App Intent, same journal, same drain, same ledger. Only the parser is new.

The body is a full HTML document, so `HTMLText` flattens it to line-structured text first.
`AmexAlertParser` then parses **line-wise rather than with one regex**: the merchant, the
amount and the date are three *adjacent lines* in a fixed order, so the structure is the
anchor. The HTML offers nothing else — the amount sits in a bare `<p>` styled by inline CSS,
and the class names are shared with the boilerplate.

**It is envelope-anchored, and that is load-bearing.** Amex's `There was a large purchase on
your Card` must be present before anything else is considered. The reason is concrete: the
Email automation also captures **merchant** confirmation emails, and an Airbnb booking receipt
and a CinemaPlus ticket receipt each carry the *exact amount* of the Amex alert they pair
with. A parser that looked for "a dollar amount in some text" would record every online
purchase **twice**, silently, inflating the total. `theMerchantReceiptsAreRejected` asserts
both are refused.

Amex prints **five** card digits (`Account Ending: 21008`) where Fidelity prints four, so the
field is `cardSuffix` and stores what the source gave rather than truncating — which would
work for today's two cards and collide for someone else's.

Amex also prints a real transaction date and the ledger uses it, where the Fidelity SMS
carries none and falls back to arrival. Rows therefore read **Purchased** or **Alerted**.
Arrival is the weaker signal for email in particular, because Apple Mail fetches Gmail on a
schedule rather than by push.

### Two things about the Amex setup worth knowing

- **The $1 threshold is Amex's floor.** Purchases under $1 alert nothing at all, so the Amex
  side of the ledger is incomplete by design below that. Unlike Fidelity's threshold, this one
  cannot be lowered — which is the standing argument for statement import as Amex's eventual
  ledger of record.
- **The Email automation catches more than Amex.** Its filter is set to
  `AmericanExpress@welcome.americanexpress.com`, yet merchant receipts are being captured too.
  Harmless — the parser refuses them and they are dropped — but the automation is broader
  than configured, and each one is a ~60 KB email being written to the journal and then
  compacted away again on the next refresh.

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

**Last captured** now lives only on the Diagnostics screen. It used to be a banner on the
first screen; it was removed because it was permanently on display for a value that changes
rarely. The signal is not gone — it is under **⋯ → Diagnostics**, alongside last manual entry
and the counts.

---

## Known constraints

- **Signing expires every 7 days** on a free Apple ID. After that the app will not launch
  and capture stops *silently* — the Shortcut still fires, the intent just never runs.
  Re-sign from Xcode (⌘R) weekly. **Nothing on the main screen will tell you this happened**;
  check **⋯ → Diagnostics** for "Last captured", which is now the only place it is visible.
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
  ContentView.swift the charge feed, month total, and swipe-to-delete
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
