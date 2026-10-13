# spending-tracker

An iOS app that shows credit-card spending as it happens, fed by the transaction-alert
texts Fidelity sends for every card purchase and card payment.

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
> **A Fidelity payment text (2026-10-15).** A payment is now recognised from Fidelity's own
> SMS as well as from Amex's email and by hand, so both cards report their payments. See
> *Payments*.
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
because both are things that happened. **The month total counts what left** — a Zelle you
received is not a negative cost, and folding it in would make a heavy month look cheap because
someone paid you back for rent. A refund is a different thing and is *not* excluded: it is a
negative charge, money the card gave back on spending that did happen. A payment is excluded
too, and it is the one exclusion that is not about direction — see *The summary* below.

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
purchase, which is the date printed in the Amex email and the Fidelity payment text, and the
alert's arrival for the Fidelity charge text. A charge that arrives late still belongs to the
month it was made in.

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

The feed and the **This Month's Spending** figure show the **current calendar month** and nothing
else. The list header names the month, and the total header has always.

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

The **balances are untouched** by all of this. Both are folded from the whole journal, not from
the rows on screen, so a deposit from a month the list is no longer showing is still money that
moved.

And that is the whole of the rollover, which is worth saying because it is the thing most likely
to be looked for and not found. Nothing is carried across a month boundary by hand, because a
position does not *have* a month. November opens on October's card balance plus November's
charges, because that is simply what summing the journal says.

### The summary

Four figures, and they are two different kinds of thing.

**This Month's Spending** is the month alone: charges and refunds, plus deposits that are
negative — money that left the bank by some route that is not a card, a Venmo sent to a person
being the ordinary case.

**Payments do not come off it**, and that exclusion is the point of the figure. A payment settles
spending that belongs to an *earlier* month — most of a statement was spent in the month before
it — so letting one come off here would make a heavy month read as light because the previous
month's bill happened to be paid in this one. It is also why the arithmetic flips the sign of a
deposit and nothing else: a card row's sign already *is* its contribution, while a deposit is
stored signed by the direction the money went.

The other three are **positions**, all read at the same moment, and none of them is scoped to the
month:

| | |
|---|---|
| **Balance** | what is owed on the cards and not yet paid off |
| **Bank** | what is in the bank |
| **Remaining** | the bank less the Balance — what you would have if you cleared the cards |

Remaining is derived from the other two rather than being a third number kept alongside them, so
the three cannot drift apart. It moves for both halves without either being folded into the
other: a charge raises Balance and lowers Remaining, money arriving raises the bank and
Remaining, a deposit leaving the bank lowers Remaining.

A payment lowers **both** Balance and the bank by the same amount, so it leaves Remaining exactly
where it was — which is right, because settling a debt does not change what you have. That
property is the reason a payment is stored negative rather than being its own special case in
the fold.

Deposits reach Remaining through the bank and not through the spend, which is the same rule as
everywhere else — a Zelle received is not a negative cost, and counting it as one would make a
heavy month look cheap.

The empty state distinguishes the two cases on purpose. "Nothing in October yet" with a full
store behind it reads very differently from "No transactions yet" — and the first of the month
is exactly when getting that wrong would look like everything had been thrown away.

### Both balances are derived, not stored

Neither is a field anywhere. Setting one writes a line to the raw journal, and the balance is
then folded out of that file: the last value set, plus every movement after it.

```
Bank | 1200.00
Card | 240.00
```

The bank moves for deposits and payments; the card moves for charges and payments. A charge is
owed on a card and never touches the bank until it is paid, which is why there are two folds
rather than one net figure — and why the predicate is written out as a positive list of kinds in
each case, rather than as "anything that is not a deposit". That shorter form reads as the
obvious thing to write and is **true of an unrecognised verb**, which resolves to no row at all:
a declined alert would have raised the card balance by an amount the feed never showed, and then
dropped it again a week later when the retention window purged the line it came from.

`Card | 240.00` reads as **240.00 owed**. Positive-is-owed is the sign the rows themselves carry
— a charge is stored positive, a payment negative — so a typed balance and the charges it
supersedes cannot disagree about which way round the number goes. A card in credit is a real
state and takes a leading minus, exactly as an overdrawn account does.

It exists for the same reason the bank line does, and it is worth saying plainly: **the app
cannot work out what is owed.** It knows what it has *seen* charged, and this ledger is
incomplete by construction — nothing from before the app was installed, a source that only
alerts above a floor, and alerts that never arrived. What those gaps add up to is not derivable
from anything here. This line is the only place it can be said.

The card balance has no `UserDefaults` history and therefore no adoption branch — the bank's is
below, and it is a cautionary tale rather than a pattern to copy.

That is the same bargain everything else here makes, and it was not always kept. The balance
used to live in `UserDefaults`, which meant it survived a rebuild only by accident — the journal
could not restore it, so a schema change would have rebuilt the ledger and left the bank stale
with nothing to explain the difference. Folding it from the journal also removes the bookkeeping
for deletion: removing a deposit's line removes its effect, with no code that adjusts anything.

A balance is an assertion about the world rather than a movement of money, which is why it is a
line of its own and not an enormous deposit. A deposit says "this arrived"; a balance says "this
is what is there", so it wins outright over everything before it.

The handover from the old `UserDefaults` value happens only when the fold derives **nothing** —
and that is the branch that also clears it. On a device whose journal already derived a balance
when the change landed, the old value was therefore never cleared, and deleting the last line
that derived one would have adopted it: a balance nobody set, written into the journal, showing
a figure from a previous version of the app. The value is now cleared whenever the fold derives
a balance, which is the point at which it stops being adoptable at all.

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
Fidelity *charge* row's `occurredAt` is its *arrival*, a real time of day, and keeping that
while replacing the day would claim a time nobody ever stated. It becomes noon — the
date-with-no-time convention — and the row reads "Purchased \<date\>". Clearing the date puts
it back to arrival, exactly as omitting one does when adding.

An edit cannot change what a row *is*. There is no tab switch when editing: moving a charge to a
deposit would change whether it touches the bank, and "I mistyped the amount" is not a reason to
reclassify it.

Both amounts are **signed**. A refund is a negative charge; a deposit goes whichever way the
money did. `Money.minorUnits` still refuses a minus for the captured sources, where a negative
charge is a broken parse rather than a refund — only a person typing gets one, through
`Money.signedMinorUnits`.

### Categories

Dining, grocery, retail, transportation, miscellaneous. A category is **a journal line, never a
field on the row** — for the same reason a bank balance is one. The store is deleted and replayed
whenever `ledgerSchemaVersion` changes, so a category that lived only on `Txn` would work
perfectly until the first property rename and then be gone, taking both the classifier's answers
and the user's corrections with it, silently.

Two lines, and both are siblings of `Edit` rather than new fields on it. That is not style:
`parseEdit` guards `fields.count == 6` — an *equality*, not a minimum — so widening that line
would make every edit already in the journal fail to parse, and a rejected instruction line is
invisible.

```
Category         | <runID>#<index> | <label> | user
MerchantCategory | <label> | ai|user | <merchant verbatim>
```

The first is about one transaction, the second about a shop. `applyCategories` resolves them on
every drain, in this order:

1. a line naming this transaction — **including one that clears it**, which stops here rather
   than falling through;
2. a rule a person wrote for this merchant;
3. a rule the model wrote for this merchant;
4. nothing.

**Specificity beats recency, and a person beats the model.** So "remember this for every Whole
Foods" cannot rewrite the one row already filed by hand, and an answer arriving from the API
later cannot overwrite a decision already made — which matters because those answers arrive
asynchronously and after the fact.

An empty label is an **explicit clear**, not a missing value. Absent means "no line about this
row, so the rules apply"; empty means "no category, and no rule may give it one". Without the
distinction a single row could never be taken back out of a rule set on purpose.

**Only charges.** A payment is a card being settled and a deposit is money arriving; neither is
spending, so neither is filed — a payment under Dining would make that figure a lie. They are
left unset and show no chip at all, rather than the word "Uncategorized", because they are not
awaiting an answer. The filter matches charges only, `Uncategorized` included.

**The three figures at the top never move when the filter changes.** They read the month, not the
filtered rows: a Balance narrowed to dining sitting above an unfiltered Bank would make
`Remaining` mean nothing. What one category cost is the subtotal in the list's own header, which
is the figure that is honestly about the rows under it.

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

Under the **⋯** menu. Answers the three questions no other screen can — *is the automation
still capturing*, *is anything arriving the parser can't read*, and *has this app's process run
at all*. All three failures are otherwise silent: the Shortcut keeps firing, the alert is
simply absent, or a line is in the journal that nothing can decode.

Shows last captured, last manual entry, the app's recent launches, counts of alerts and charges,
bodies held, empty invocations, the parser version in force, the journal's size and its damaged
lines. The journal can be shared out from here.

### Reading a missing alert

An alert that never appears has several possible causes, and they are otherwise impossible to
tell apart from the phone. The screen — plus the notification the sub-shortcut posts — separates
them:

| What you see | What it was |
|---|---|
| No launch beside the time, and **Last captured** older than the alert | the intent never ran: iOS could not launch the app |
| A launch listed, no new line, and no `ST1 …` notification | the Shortcut failed on the way to the intent |
| A notification reading `ST1 FAIL\|…` | the append threw — the text after it says which call failed |
| The line is there and **Held, not a movement** went up | captured, and the parser read nothing in it |
| A line under **N damaged** | captured, and the line it went into cannot be decoded |

**The notification is the only writer-side evidence there is.** The sub-shortcut's
`Show Notification` posts the intent's own result —
`ST1 ok|spending-tracker|main:0|chars:231|rx:1|fid:1|grp:0` — and its *absence* is itself a
finding, because `perform()` writes the journal line **before** it returns anything at all. A
missing line together with a missing string means the intent never ran; a line that is there
means it did, and the loss is on the read side. The fields are described under **Reading the
diagnostic**.

### The app has to run for anything to be captured

`LogTransactionIntent` is pinned to the app's own process (`allowedExecutionTargets = [.main]`)
and there is deliberately no extension target, so **the only way an alert can reach the journal
is for iOS to launch spending-tracker**. When iOS will not — an app force-quit in the App
Switcher, an install never opened by hand, a lapsed free-Apple-ID profile — the Shortcut still
fires and nothing is written at all.

That is precisely the failure no other screen could show, because *Last captured* cannot tell it
apart from a quiet week. So every launch stamps a small ring in `UserDefaults`, and Diagnostics
lists the recent ones. A background launch servicing an alert is recorded exactly like one made
by hand, so **an alert that went missing in a window with no launch beside it means the intent
never got the chance to run.**

It is in `UserDefaults` rather than the journal, and that is the one exception to the rule that
everything the app knows lives in the file. The journal is the record of what *arrived* — the
money, the evidence, the thing a rebuild restores. This records the app's own process: nothing
is derived from it, no figure depends on it, and a line per foreground would put the app's own
noise into the one file that has to stay readable as a record of what the sources sent.

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

> **A fourth kind (2026-10-03).** Paying a card off, from Amex's payment confirmation, from
> Fidelity's payment text, or by hand.

A payment is its own kind, not a large deposit, because it is the one movement that touches
**both** balances: **Balance**, because it settles a debt that was owed, and **Bank**, because
the money left it. It is also the one movement that must *not* touch the month — see
*The summary*.

It is stored as its **effect**, so the amount is negative even though the figure a person types
is what they paid:

```
Manual | payment | -825.77 | 2026-10-03 |  | AMEX PAYMENT
```

That keeps the arithmetic free of special cases. A payment is the one movement that touches both
balances — money out of the bank, and the same amount off what is owed — so it is summed into
each by the fold that folds it, with no branch anywhere that has to know it is a payment.

It is also the whole reason "This Month's Spending" and Balance are two figures rather than one.
A payment comes off Balance, because it settles a debt, and does not come off the month, because
the debt it settled was not this month's.

In the feed a payment is **red**, where money arriving is green and everything else is ordinary.
The payment arm is checked first, and is not a special case of the other two: `isMoneyIn` asks
the kind before the sign precisely so a payment is not green, and a payment's amount is negative
like a refund's — so a rule written the other way round would have to say "negative, but not
*that* kind of negative", and would get it wrong the moment a fourth kind appeared.

### Reading the email

Amex's confirmation carries the figure under a label, not in a sentence:

```text
Payment amount:
$1,044.97
Processed on:
Sep 30, 2026
```

Both are read from the line *after* their label rather than by shape, and that matters: the
same email opens with a date of its own — `Thanks for your payment received on Sep 30, 2026` —
so anything scanning for a date would as happily take that one. There is a test where the two
dates differ.

Two things must both be present — Amex's sentence `We received your payment` and the
`Payment amount:` label — so a template change to either refuses rather than guesses.

**The purchase alert is the reason for that care.** It arrives from the same sender, carries
the same `Account Ending:` line and a dollar figure of its own, and is a completely different
transaction. The registry runs the large-purchase parser first, so an alert can never be read
as a payment, and there is a test for it.

A payment may name a card, unlike a deposit. The Payment tab offers no card field, so a
hand-typed one writes none, but a payment read from the email or from the Fidelity payment
text knows which card it settled — and a line that refused the card would erase that the first
time the row was edited.

### Reading the text

Fidelity's payment text carries the figure in a sentence instead, with no labels at all:

```text
Fidelity® Credit Card: A payment of $316.29 has been posted to your account ending in
7224 on 10/13/2026. Msg&Data rates may apply. Reply STOP to cancel.
```

Every phrase between the figures is literal. There is no free-form descriptor to capture
here, unlike the charge text, so the sentence is simply spelled out and a template change
refuses rather than guesses. The amount is anchored between `A payment of` and `has been
posted to your account ending in`, and the `Fidelity® Credit Card:` preamble is required
alongside it: `account ending in` is ordinary banking English that any issuer may print, so
on its own it is not evidence.

**The charge text is the reason for that care, the way the Amex purchase alert is for the
email.** It arrives from the same sender under the same preamble and carries a figure of its
own, so the sentence is the only thing separating the two — and a body both parsers read
would be one movement of money recorded twice. The registry runs the charge parser first, and
both refusals are asserted rather than argued.

Two things differ from the Amex email:

- **The date is real.** The charge text carries no timestamp, so its rows read `Alerted`; a
  payment text prints the posting date, so its rows read `Purchased`, like Amex's. It is read
  strictly — `13/10/2026` and `02/30/2026` are refused rather than rolled forward into a
  plausible-looking wrong day — and a refused or absent date costs the row its date, not the
  row.
- **The row is named `Fidelity payment`**, where the Amex one is `Amex payment`. In the feed
  a payment shows `Payment` in place of a card bullet, so the merchant is also what tells the
  two apart.

Nothing else had to change for a second payment source. Both balances fold on the *kind* —
`affectsBank` and `affectsCard` — so a payment settles the card and moves the bank wherever
it came from, and the month's total excludes any of them.

**Known and accepted.** The registry stops at the first parser that recognises anything, and
that is deliberate — it is what stops two sources reading one body and counting it twice. Its
order is therefore a precedence: charges first, then payments, then the rest. Nothing in the
capture path can tell the difference, because each automation hands over one body, so this only
bites when two messages are pasted into one entry — the earliest parser's alert is recorded and
the rest of the body is not. Charges come first because a purchase is the ledger's primary
record: losing one takes money out of the month as well as off the card, where losing a payment
leaves a balance that is merely too high. The body stays in the journal either way, so the text
of the dropped alert is still there to be re-read. Having the registry merge what several
parsers find is the real fix if the paste case ever matters, and it belongs in the registry
rather than in any one parser.

## Only real movements of money reach the ledger

A body that resolves to nothing — a merchant's own confirmation email for a purchase Amex
already reported, a statement notice, an OTP — never becomes a ledger row, and nothing in the
app shows it to you.

But it is **not discarded on arrival either**. Anything that is not a charge or a deposit is
held in the raw journal for a week and then purged; charges, deposits and payments are kept
forever.

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

### Deleting from the raw journal

The feed can delete a transaction, and doing so removes its journal line too: the store is
derived, so a row whose line survived would simply come back on the next drain.

That left a gap. A body that resolved to nothing has no row, so there was nothing to swipe and
no way to remove it — a merchant's confirmation for a purchase Amex already reported, an OTP, a
statement notice, all of them simply sat there until the week ran out. **⋯ → Raw journal** now
deletes them directly.

Swipe a line and it asks first, because this is the app's only copy of what arrived and the
deletion cannot be undone. What the confirmation says depends on what the line turned out to
be, and the row count in it is read from the **store** rather than by re-parsing the text: the
two can disagree, and a copy that promised "nothing in the ledger changes" while a row
disappeared would be wrong in exactly the place the user is being asked to trust it.

| The line | What deleting it does |
|---|---|
| A charge, a deposit, or a payment | Removes the transaction it recorded, and the line. A charge or a payment also restates the Balance figure, and a deposit or a payment the Bank figure, because both are folded from the journal. A payment moves both. |
| One message carrying two alerts | Removes both transactions. They share the line, so there is no way to remove one and keep the other. |
| An `enter`/`result` pair from an older journal | Removes both halves. They share a `runID`, and leaving one would rebuild the row on the next drain. |
| A `Bank` line | The Bank figure is restated from the balance and deposits or payments still in the journal. |
| A `Card` line | The Balance figure is restated from the charges and payments still in the journal. |
| An `Edit` line | The row it changed reverts. An edit names a row rather than being one, so the row is re-derived from the original line and every edit still standing is replayed onto it. |
| A body that recorded nothing | Just the line. Nothing in the ledger changes — and this is where the week-long recovery window is given up early. Unless the store still holds a row for it, which happens when a body an earlier parser recorded no longer reads as a movement — then that row goes too, and the confirmation says so. |

The journal is written **first**, with one exception: the `Edit` line, and the reason is worth
stating. An edit names a row rather than being one, so its store half is not a removal at all —
the row is dropped so the drain rebuilds it from the original line. That makes a failure
self-healing in that direction and only that one: if the save fails then nothing has happened
and the line is still there; if the save lands and the journal write then fails, the surviving
edit line rebuilds the row exactly as it was. The other order would leave the store holding the
edited values with no edit left in the journal to explain them, permanently, because `ingest`
skips a row it already knows and `applyEdits` has nothing left to apply.

Everywhere else the journal goes first. If that write fails then nothing has happened and the
delete can simply be retried; if it lands and the store refuses the save, the row is still on
screen and the feed can finish the job. The reverse order fails the other way — a row that
vanishes and then silently returns on the next drain, which reads as the app undoing a delete
rather than as a failed write.

#### A line that cannot be read is shown, not dropped

`JournalStore.read` returns the records **and** the lines it could not decode. It did not
always, and the difference is the whole of this subsection: a line that failed to decode was
dropped, which made *"a line arrived and cannot be read"* indistinguishable from *"no line ever
arrived"* — on the Raw journal screen, in the drain, and in Diagnostics, because all three read
through the same function. The store is derived from this file, so that difference is a
transaction that exists or one that does not, and nothing else in the app can tell you which.

Two things produce one: a write interrupted by a kill (the process servicing an alert in the
background can be suspended the moment `perform()` returns), and a record shape from another
version of the build. Both leave bytes in the file that nothing can interpret.

The Raw journal lists them under **N damaged**, showing the bytes they hold, with a swipe to
remove one — a deletion with only a journal half, since nothing was ever derived from a line
nothing could read. A rule over *records* can never remove one, deliberately: the retention
purge runs on every foreground and a damaged line has no readable `receivedAt` to age by, so a
purge that swept them up would delete evidence it exists to preserve.

The read is also decoded **per line**, where it used to be decoded as one UTF-8 string. That
mattered more than it looks: a single invalid byte anywhere made the whole file unreadable, so
one torn write could show an empty journal on every screen while the store still held rows
derived from it a moment earlier.

#### The append is `O_APPEND`, and it frames the file first

Two properties the journal did not have.

`FileHandle(forWritingTo:)` opens **without** `O_APPEND`, so an append was two steps — position
the offset, then write — and two writers that interleave those steps lose one line outright. The
survivor is perfectly valid, so nothing anywhere records that the other arrived. That cannot
happen today, because the intent is pinned to the app's own process and one lock serializes its
writers — but that pin is the one assumption this design rests on that nobody has published
field data for, and `open(2)` with `O_APPEND` removes the need to be right about it. Measured
rather than assumed: a two-process repro of the seek-then-write sequence lost half the lines.

The second is framing. A record is written with its newline **last**, so an append killed
part-way leaves a line with no terminator — and the next append would run straight onto the end
of it, fusing two records into one undecodable line. That would take the *following* alert down
with the damaged one, through no fault of its own, leaving nothing to say it ever arrived. So
the append writes a newline first when the file does not already end in one: one byte in the
rare case, and the difference between losing one alert and losing two.

#### Removing a line is one atomic step

`JournalStore.remove` reads, decides and rewrites the file under a **single** lock hold. It is
the only thing in the app that rewrites the journal.

It has to be one step. `LogTransactionIntent` runs in the app's own process
(`allowedExecutionTargets = [.main]`) and its `perform()` runs off the main actor, so an alert
can be appended *while* a screen is deleting a line. Composing the removal from a read, a filter
and a write takes the lock three separate times, and an alert appended in either gap is read as
absent and then written away by the rename. That alert can be a real charge, and because the
ledger is derived from this file, losing it loses the charge everywhere — no row, no warning,
nothing to recover from. The retention purge had the same race with a much wider window (it
decided from the records the drain had read at its start, a whole ingest and a save earlier),
and now goes through the same primitive.

A rewrite also **carries undecodable lines through untouched**. The file used to be rebuilt by
re-encoding the records the current schema could decode, so any line it could not read was
silently destroyed by any rewrite. `JournalRecord`'s own note records the day adding a field
made every existing line undecodable — which is exactly when that would have bitten, and there
would have been nothing left to notice it by.

## Still missing

- **Statement import and reconciliation.** The plan's ledger of record, but it needs a real
  statement export first. Building an importer against a guessed CSV format is the same
  mistake the parser nearly made before real messages arrived.
- **Classifying a merchant automatically.** The design is settled — a lazy pass over merchants
  with no category, calling DeepSeek, batched and retried at the next foreground — but the
  pass itself is not built. Everything it needs is: the lines, the precedence and the fold are
  in place and tested, so the classifier is a producer of `MerchantCategory` lines and nothing
  else. The feature is fully usable without it, which is the point of building it this way
  round.

## The parser

`FidelityAlertParser` and `FidelityPaymentParser` are pure functions — no store, no UI, no
async — so they are fully testable without the app or the automation. The drain persists
their output into SwiftData, and the journal screen re-parses the same text at display time,
so the journal remains the only source of truth.

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

Amex also prints a real transaction date and the ledger uses it, where the Fidelity **charge**
text carries none and falls back to arrival. Rows therefore read **Purchased** or **Alerted**.
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

Two Fidelity texts are in scope — the charge (`was charged`) and the payment (`A payment of
… has been posted to your account ending in`) — and nothing else is. Declines, refunds,
authorizations, and other alert types are deliberately **not** handled: no review queues, no
exclusion flags, no dedup paths for them. A posted **debit** alert is refused by name for
exactly that reason, since only the literal `A payment of` is read as a payment.

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
rarely. The signal is not gone — it is under **⋯ → Diagnostics**, alongside last manual entry,
the app's recent launches, and the counts.

Two kinds of line are excluded from it, for the same reason: the figure answers *"is the
automation still capturing"*, and neither a hand-typed entry nor an **empty invocation** is a
capture. An empty one means the Shortcut ran and handed over nothing — a broken Message wiring,
not a quiet day — and counting it would hold the number looking fresh while the ledger stopped
growing. The count of them is on the screen beside it, where it says what happened.

---

## Known constraints

- **Signing expires every 7 days** on a free Apple ID. After that the app will not launch
  and capture stops *silently* — the Shortcut still fires, the intent just never runs.
  Re-sign from Xcode (⌘R) weekly. **Nothing on the main screen will tell you this happened**;
  check **⋯ → Diagnostics**, where the app's recent launches say whether the process has been
  running at all — which is the sharper signal, since "Last captured" cannot tell a stopped
  capture from a quiet week. Diagnostics also says so out loud once the app has not run for six
  days, ahead of the seven-day wall.
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

# UI tests — a separate run, and not optional
xcodebuild -project spending-tracker.xcodeproj -scheme spending-tracker \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath ./DerivedData -only-testing:spending-trackerUITests test
```

### Layout

```
spending-tracker/
  Journal/          append-only JSONL journal, runtime diagnostics, launch log
  Intents/          LogTransactionIntent — the only App Intent
  ContentView.swift the charge feed, the summary figures, and swipe-to-delete
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
