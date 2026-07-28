# Tokenomics — where a Claude Code session's tokens and context go

The long-form companion to the tokenomics plugin. It explains the mechanism the plugin
measures: why a session's token counts grow the way they do, which events are heavy, and
what actually changes them.

**Is any of this money?** Depends how you're authenticated:

- **Subscription (Pro / Max / Team / Enterprise)** — no. Usage is included in the plan. What
  these tokens actually spend is your **rate-limit budget**, which is what decides whether
  you hit a cap mid-afternoon. Read every figure below as *headroom*.
- **API key (Console billing)** — yes, at Anthropic's published per-token rates. The rate
  card in §2 is not an analogy for you; it is the shape of your invoice.

The mechanism is identical either way, and so is every piece of advice here. Only the unit
of pain changes. To keep the arithmetic legible this document needs *a* unit, so it borrows
one:

> **₹1 ≡ the weight of 1000 fresh input tokens.**
> Every other class is a multiple of that. It is a *relative weight*, not a claim about your
> account. If ₹ is distracting, read it as "cost units" — or, on a subscription, as
> "percent of the limit you'll hit today".

The worked figures throughout come from one real session measured with this plugin
(5.5M tokens, 56 API calls, 8 turns, one model switch and one `/compact`). They are an
illustration of the mechanism, not a benchmark — your ratios will differ, the structure
will not.

---

## 1. The mental model

**The model has no memory.** It is a brilliant consultant with total amnesia between calls.

So every single time it is asked anything, the *entire conversation so far* must be handed
over again — your messages, its replies, every file it read, every command output. That
re-handing is the product. It is not overhead around the work; it **is** the work being
paid for.

The useful physical picture: **the conversation is a stack of paper.**

- New material goes on **top** of the stack.
- Pages already photocopied are re-read **cheaply**.
- Fresh photocopies are **expensive**.
- The catch that governs everything: photocopies are only valid if the stack is **unchanged
  from the bottom up**. Slip one page into the middle and every page above it must be
  re-photocopied.

---

## 2. The weight card

Real API rates, expressed as multiples of the fresh-input rate:

| What happens | Rate | Per 1000 tokens |
|---|---|---|
| Fresh input (uncached words) | 1× | ₹1.00 |
| **Cache read** (re-reading filed pages) | **0.1×** | **₹0.10** |
| **Cache write, 5-minute TTL** | 1.25× | ₹1.25 |
| **Cache write, 1-hour TTL** | **2×** | **₹2.00** |
| Output (what the model writes) | 5× | ₹5.00 |

A 20× spread between the cheapest and dearest class means **token counts and weighted cost
are two different questions.** Here is the same session answered both ways:

**By volume** — what a naive total shows you:

| Class | Tokens | Share |
|---|---|---|
| cache read | 4,961,159 | **91.0%** |
| cache write | 422,430 | 7.7% |
| output | 70,987 | 1.3% |
| fresh input | 103 | <0.01% |
| **total** | **5,454,679** | |

**By weight** — the same tokens through the rate card:

| Class | Tokens × rate | Weight | Share |
|---|---|---|---|
| **cache write** | 422,430 × 2 | **₹845** | **49.8%** |
| cache read | 4,961,159 × 0.1 | ₹496 | 29.3% |
| output | 70,987 × 5 | ₹355 | 20.9% |
| fresh input | 103 × 1 | ₹0.10 | <0.01% |
| **total** | | **₹1,696** | |

Three consequences, all of which are easy to get backwards:

1. **Cache read is 91% of the tokens and 29% of the weight.** It is the number that makes
   session totals look alarming, and it is the *least* of your problems. Rent, not the bill.
2. **Cache write is 7.7% of the tokens and half the weight.** Writes are what a session
   actually spends on. Everything in §5 is about when they happen and why.
3. **Output is ~1% of the tokens but ~21% of the weight.** Not the main event, not
   negligible either.

The single sentence: **watch the write column.**

### This split is not a constant — measure yours

The 91%-of-tokens → 29%-of-weight collapse for cache read is structural and shows up
everywhere. How the *rest* divides is not. It depends on what kind of session you ran:

| Session shape | What dominates the weight |
|---|---|
| **Rebuild-heavy** — many short messages, a model switch, idle gaps | cache write, often ~half |
| **Output-heavy** — long generated answers, few turn boundaries | output, which can outweigh cache read |

A session spent writing this document, for instance, measured **96% / 3% / 1%** by volume
and **44% / 25% / 31%** by weight — output-dominated, because it produced a lot of text
across only a handful of turns. Same mechanism, different shape.

So "be brief" is worth something in a generation-heavy session and close to noise in a
rebuild-heavy one. `/tokenomics` tells you which one you are in; a rule of thumb does not.

---

## 3. The four token classes

Every API call reports these under `.message.usage` in the transcript JSONL:

| Field | Plain English |
|---|---|
| `input_tokens` | Words spoken fresh, uncached. Usually almost nothing. |
| `cache_read_input_tokens` | The stack, re-read at 0.1×. Big number, light weight. |
| `cache_creation_input_tokens` | Pages being photocopied into the cache at 1.25×/2×. |
| `output_tokens` | What the model actually wrote. |
| `cache_creation.ephemeral_1h / _5m` | Which TTL drawer the photocopy went into. |

`fresh input + cache read + cache write` for a call is that call's **context size** — which
is exactly how Claude Code computes the context-window percentage it shows you.

---

## 4. The rules that produce every cost in a session

### Rule 1 — rent

Every API call re-reads the whole stack. That is a standing charge, paid whether or not
anything interesting happened:

```
rent per call = context size × ₹0.10 / 1000
```

At 108k context that is **₹10.80 per call**. Note *call*, not *message* — a single question
from you can trigger 10+ calls as the model runs tools, and each one pays rent.

### Rule 2 — the byte-identical prefix rule

A cache hit requires the stack to be **byte-identical from the bottom up**. Append to the
top: cheap forever. Change anything in the middle: everything above it is void.

### Rule 3 — breakpoints (the bookmarks)

The system doesn't cache "whatever it feels like." It plants a small number of explicit
save-point markers (`cache_control`, max 4 per request) meaning *"everything below me is
filed."* On each call, the discount applies up to the **deepest bookmark whose contents
still match byte-for-byte**. Everything above that bookmark is re-photocopied at 2×.

### Rule 4 — turn boundaries are where the stack gets disturbed

A **turn** = your message → all the model's tool round-trips → its final reply
(`stop_reason: end_turn`). One turn is many API calls.

- **Inside a turn**, the conversation only grows at the top. Caching is perfect.
- **At the seam between turns**, content in the middle changes. Bookmarks break.

In the worked session, `stop_reason` split **8 × end_turn** against **48 × tool_use** — 8
conversation turns, 56 API calls. Six times more calls than turns, and the cheap ones were
the model working.

> **The headline rule: the model working is cheap. You talking is expensive.**

---

## 5. Cache rebuilds — the expensive event

A **rebuild** has an unmistakable signature in the data: `cache_read` collapses, and
`cache_creation` spikes. Four distinct causes, all of them visible in a single session:

| Cause | read before → after | write |
|---|---|---|
| **Model switch** mid-session | 75,792 → 29,910 | 35,977 |
| **Idle gap** (~50 min, TTL expiry) | 65,887 → 29,923 | 40,551 |
| **`/compact`** | 107,585 → 35,481 | 36,828 |
| **Turn boundary** | 111,991 → 35,481 | 77,692 |
| **Turn boundary** | 129,934 → 35,481 | 95,537 |

Switching models mid-session, or walking away past the cache TTL, costs a full 2×-weighted
re-file of the context. Same tokens, 20× the rate, purely from timing.

### The arithmetic that proves what a rebuild really is

A rebuild is not "writing the rest." It is **rebuilding the entire stack from the surviving
bookmark upward**. The sums land exactly on the next call's read:

```
turn-boundary rebuild A:  35,481 (bookmark) + 77,692 (rebuild) = 113,173  → next read = 113,173 ✓
turn-boundary rebuild B:  35,481 (bookmark) + 95,537 (rebuild) = 131,018  → next read = 131,018 ✓
```

Not approximately. Exactly. Nothing is discarded — the whole stack is re-photocopied and
handed back complete.

### Why the fallback lands on the *same* number every time

`35,481` both times. That is the compact summary's bookmark — the deepest bookmark that
never breaks, because nothing below it ever changes again. After a compact, the summary
becomes the session's permanent floor.

**Why can't a bookmark nearer the top survive?** Something mid-stack changes at every turn
boundary. *Inference, not proven:* the prime suspect is **thinking blocks** — they are
present in the stack while a turn is running and dropped once it completes. A page removed
from the middle voids everything above it, so the fallback goes to the last bookmark that
predates any thinking. The transcript shows the blocks; it does not show the request bytes,
so this remains a hypothesis rather than a measurement.

### The one-line cost of talking

```
each message you send ≈ (current context − bookmark floor) × ₹2 / 1000
```

For rebuild B that was 95,537 × ₹2/1000 = **₹191**, to ask one question. And it *grows* as
the session grows.

---

## 6. What `/compact` actually does, in numbers

**Before.** Stack = 107,585 tokens. Rent = **₹10.76 per call**. Nothing is wrong; that's
just the standing charge for carrying history.

**The compact.** Threw out the 107.6k history, replaced it with a 35.5k summary,
bookmarked it.

| | |
|---|---|
| one-off cost | 36,828 tokens × ₹2/1000 = **₹73.66** |
| rent before | 107,585 × ₹0.10/1000 = **₹10.76 per call** |
| rent after | 35,481 × ₹0.10/1000 = **₹3.55 per call** |
| saving | **₹7.21 per call, forever** |
| **break-even** | 73.66 ÷ 7.21 ≈ **10 calls** |

26+ calls followed, so it cleared break-even comfortably. Note the shape of that
calculation: a compact is an **investment with a payback period**, and the payback is
counted in *calls*, not minutes. Compacting immediately before you stop working is pure
loss.

**Where compact does NOT help**

- It refunds nothing already spent. The cumulative total only ever grows.
- It cannot stop new work from re-inflating the stack. Twenty calls after the compact,
  context was **131,018 — 22% above the pre-compact peak.** Compact deletes the past; it
  does nothing about the future. Check whether context has already climbed back above its
  pre-compact level before reaching for another one.

### Does a 2× rebuild after a compact nullify the compact?

**No — the rebuild is cheaper *because* of the compact.** A rebuild re-inks whatever
currently exists, and permanently less exists:

| | with compact (measured) | without compact (counterfactual) |
|---|---|---|
| stack being re-filed | summary 35k + tail | history 108k + same tail |
| rebuild B re-file @ 2× | **95,537 = ₹191** | ~167,600 ≈ ₹335 |
| every read since | **−72,104/call, forever** | full freight |

> **A rebuild changes the *rate* you pay for context (0.1× → 2×, once).
> A compact changes the *amount* of context (forever).**

Both turn-boundary rebuilds landed after the compact, each roughly ₹145 cheaper than the
same event would have been without it — together about **4× the compact's own cost**,
recovered purely as accident insurance. (The right-hand column is an estimate, not a
measurement: it assumes the un-compacted history would have sat above the same floor.)

The one genuinely wasted spend in that session: the compact's own 36.8k summary write was
itself re-filed 8 calls later by an unrelated rebuild. Unlucky sequencing, small money.

### `/clear` vs `/compact`

`/compact` has a **floor**: the summary, plus the system prompt, tool definitions and
CLAUDE.md that sit under it. Repeated compaction produces a sawtooth that never returns to
where the session began — on a long session that floor can settle in the low hundreds of
thousands of tokens, while a fresh session starts at a small fraction of that.

`/clear` starts a new transcript at that base prefix. It is also cheaper than it looks: the
system prompt, tool definitions and CLAUDE.md prefix stay cached across sessions, so
re-warming costs little.

**Compact preserves continuity; clear preserves context.** Between two genuinely unrelated
pieces of work, clear is the better instrument by a wide margin.

---

## 7. Tool output is a recurring cost, not a one-off

Every byte a tool returns lands in the stack and is re-read on **every remaining call**.

```
true weight of a tool output = its size × the number of calls left in the session
```

A 33k-token log read with 1000 calls still to come is **33M cache-read tokens** before the
session ends — ₹3,300 at 0.1×, from one `cat`. The same read on the last call costs 33k.
Position in the session matters as much as size.

**Practical**: grep for the verdict line, don't `cat` the log. Read line ranges, not whole
files. Push heavy reading into subagents — they start with a fresh, empty stack, and their
findings come back as a summary rather than as the raw pages.

---

## 8. The measurement trap: the transcript double-writes

The transcript **re-writes the same assistant API message several times while it streams**,
so one `message.id` appears on multiple lines, each carrying a `usage` block.

Count usage-bearing records and you get roughly **twice** the number of actual API calls,
and roughly twice every token total. Relative rankings between sessions survive it;
absolute numbers do not. This is the single most common way a hand-rolled token counter
goes wrong.

**The fix — keep only the last record per `message.id`:**

```jq
[ .[] | select(.message.usage != null) ] | group_by(.message.id) | map(.[-1])
```

Both tools in this plugin do this. The status line does it incrementally, subtracting a
message's previous contribution when a newer version of the same id arrives.

---

## 9. The plugin

| Surface | What it does |
|---|---|
| `/tokenomics` | measure a session, summarise it, or render an HTML report |
| `/tokenomics:statusline` | check or set up the status line |
| `scripts/tokenomics.sh` | the measure + render tool |
| `statusline/statusline.sh` | live per-call and per-session counts, a context bar, and the compact nudge — terminal only |
| `hooks/compact-nudge.sh` | the cost half of that nudge as a `Stop` hook, so it also reaches the desktop app |
| `skills/tokenomics/SKILL.md` | the model reaches for this mental model unprompted |

The nudge splits along the same line this document does. **Cost** — context ≥150k, any
window — is the rent argument from §4 and §6: what a compact would take off every later
call. **Capacity** — ≥70% of the window — is the separate question of room running out,
and it is the only place this plugin mentions long context making earlier detail easier to
lose. The status line can make both arguments; a hook is never handed the window size, so
it makes the first one only.

```bash
bash scripts/tokenomics.sh                            # newest session of the current project
bash scripts/tokenomics.sh --list                     # browse sessions
bash scripts/tokenomics.sh --projects                 # every project, sizes, date ranges
bash scripts/tokenomics.sh --watch 30 --serve 8899    # live dashboard at localhost:8899
bash scripts/tokenomics.sh --inline -o page.html      # self-contained snapshot, for publishing
bash scripts/tokenomics.sh --json                     # just the measured data
bash scripts/tokenomics.sh --statusline init          # configure the status line
bash scripts/tokenomics.sh --help                     # every flag
```

Deterministic by construction — the "measured through" stamp comes from the last record's
timestamp, never the wall clock, so the same transcript always produces byte-identical
output.

**Bundle mode** (the default) writes `index.html` + `data.json`; the page fetches the JSON,
has a Refresh button and an auto-refresh timer, and re-renders in place. It must be served
over http — `file://` blocks `fetch`. **Inline mode** bakes the data into one file, which is
what publishing needs: a published artifact runs under a strict CSP that blocks every
external request, so a live-fetching page cannot work there.

No shell command can push to an artifact URL — only a Claude turn can call the Artifact
tool. That is what `/tokenomics --artifact` is for: it runs `--inline`, then publishes the
file. Republishing the same path keeps the same URL.

**What it detects automatically:** rebuilds (read collapse + write spike) with the cause
attributed from the data — model switch, idle gap past the TTL actually in use, the
compact-boundary record, or a preceding `end_turn` (a turn boundary). Compact economics
come partly from the transcript's own `compactMetadata` (`trigger`, `preTokens`,
`postTokens`, `cumulativeDroppedTokens`, `durationMs`).

The rendered report deliberately shows **token counts only, no pricing** — the ₹ unit in
this document is a teaching device, not something the tool asserts about your account.

---

## 10. Measure it by hand

`--list` and `--projects` will find sessions for you, but the transcripts are plain JSONL
and worth reading directly:
`~/.claude/projects/<project-slug>/<session-id>.jsonl`
(subagents under `<session-id>/subagents/agent-*.jsonl`).

**Deduped totals for a session:**

```bash
jq -s '
  ([ .[] | select(.message.usage != null) ] | group_by(.message.id) | map(.[-1])) as $u
  | def n(k): (.message.usage[k] // 0);
  { calls:  ($u|length),
    input:  ($u|map(n("input_tokens"))|add),
    output: ($u|map(n("output_tokens"))|add),
    cread:  ($u|map(n("cache_read_input_tokens"))|add),
    cwrite: ($u|map(n("cache_creation_input_tokens"))|add),
    total:  ($u|map(n("input_tokens")+n("output_tokens")
                  +n("cache_creation_input_tokens")+n("cache_read_input_tokens"))|add) }' \
  ~/.claude/projects/<slug>/<session-id>.jsonl
```

**Per-call series — this is where rebuilds become visible:**

```bash
jq -s -r '
  [ .[] | select(.message.usage != null) ] | group_by(.message.id) | map(.[-1])
  | .[] | def n(k): (.message.usage[k] // 0);
    "\(.timestamp[11:16]) \(.message.model) cr=\(n("cache_read_input_tokens")) cw=\(n("cache_creation_input_tokens")) out=\(n("output_tokens"))"' \
  <transcript>
```

Read it like this: **look at the write column, not the read.**
- write 0.5–3k → normal turn, you are paying rent
- write 35k+ → a rebuild happened, you are paying re-filing fees
- read collapsing to the *same number* repeatedly → that number is your bookmark floor

**Other signals in the transcript** worth pulling: `stop_reason` (turn vs tool round-trip
split), `effort`, `entrypoint`, `permissionMode`, `service_tier`, `isSidechain` (subagent
work), `toolUseResult` sizes, `hookCount`/`hookInfos`, `parentUuid`/`leafUuid` (the message
family tree), `requestId`. Compact boundaries are their own record type:
`{"type":"system","subtype":"compact_boundary"}`, carrying `compactMetadata`.

---

## 11. The practical rules that fall out

1. **Batch your questions.** Three short messages = three full rebuilds. One message with
   three questions = one. Each rebuild re-files the whole conversation at 2×.
2. **`/clear` between unrelated pieces of work**, not `/compact`. Compact has a floor; clear
   resets to the base prefix, which is still cached.
3. **Don't switch models mid-session** unless you mean it — it is a full 2× re-file.
4. **Don't walk away mid-session past the cache TTL** — same cost as a model switch, for
   nothing gained.
5. **Keep tool output small.** Size × remaining calls, not size once.
6. **Push heavy reading into subagents.** They start at zero.
7. **Judge output length per session, not by rule.** It is ~1% of tokens but 20–30% of
   weight, so it matters in a generation-heavy session and is noise in a rebuild-heavy one.
   Measure before optimising it.
8. **Compact early enough to earn it back.** The payback is counted in calls remaining.
9. **The cost of talking grows with session length.** A question at call 5 is cheap; the
   same question at call 50 is not.

---

## 12. Known idea, not yet built

**`surgery <session-id> --drop <n>`** — surgically remove a fat exchange from the middle of
a transcript rather than compacting everything: rank exchanges by `toolUseResult` size, let
the user pick, then cut **whole exchanges only** (never orphan a `tool_use` from its
`tool_result` — that makes the reconstructed request malformed) and re-link `parentUuid`
across the cut. Effect = a targeted compact: permanent per-call saving, one 2× re-file.

**Untested.** Verify resume-after-cut on a throwaway copy before trusting it.
