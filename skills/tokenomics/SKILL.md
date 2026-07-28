---
name: tokenomics
description: >
  Explains where a Claude Code session's tokens and context go, and what to do about it.
  Use when the user asks why a session feels slow, heavy, or expensive; whether to run
  /compact or /clear; what cache read vs cache write means; why context keeps growing;
  or how to read token usage from a transcript. Also use before answering any question
  about Claude Code token accounting, because the transcript double-writes and naive
  sums are wrong.
---

# Session tokenomics

## The one-paragraph model

Every API call re-sends the entire conversation. Almost all of it arrives as a **cache read**
rather than fresh input, which is why a long session's token counts look enormous while the
work being done is small. The number that matters is not the total — it is **context per
call**, and whether it is still growing.

## The four token classes

| Class | What it is | Weight |
|---|---|---|
| fresh input | genuinely new words — usually a rounding error | 1× |
| cache read | the whole conversation, re-sent every call | 0.1× |
| cache write | context filed into the cache so later calls can re-read it | 1.25× (5m) / 2× (1h) |
| output | what the model wrote | 5× |

`fresh input + cache read + cache write` = the context size for that call. That is exactly how
Claude Code computes its own context-window figure.

## Volume is not weight — the correction most analyses miss

There is a 20× spread between the cheapest and dearest class, so **token share and actual
load are different questions.** Cache read routinely lands at 90–96% of the tokens, and
weighting collapses it to roughly a third to a half of the load. Cache write and output —
together ~5% of the tokens — carry most of the rest.

How the remainder splits depends on the session's shape, so measure it rather than quoting
a rule of thumb:

- **rebuild-heavy** (many short user messages, model switches, idle gaps) → cache write
  dominates, often ~half the load
- **output-heavy** (long generated answers, few turn boundaries) → output dominates, and
  can exceed cache read's weighted share

So: a 90%+ cache-read share is normal and is *not* the problem. Never call it "90% of the
cost." Whether trimming output actually helps is a per-session question — in a rebuild-heavy
session it is noise, in a generation-heavy one it is the main lever.

## Cache rebuilds — the event worth watching

A cache hit needs the conversation to be byte-identical from the bottom up to a save point.
Anything that edits the middle voids everything above it, and the read falls back to the
deepest save point that still matches — everything after it gets **re-written**.

Watch the **write**, not the read. A small write is a normal turn. A large write means the
cache broke and the conversation is being re-filed.

Observed causes, in rough order of frequency: a turn boundary (the user sending a new
message), an idle gap past the cache TTL, a model switch, a compact boundary.

## /compact vs /clear

- `/compact` permanently reduces how much context exists, so every later call re-sends less.
  A rebuild afterwards does not cancel it — the rebuild re-files whatever exists now, and
  permanently less exists.
- A compact is an investment with a payback period counted in **calls remaining**: it costs
  one 2× write of the summary, and repays it as a smaller read on every later call.
  Compacting right before stopping work is pure loss.
- `/clear` starts a new transcript. It is cheaper than it looks: the system prompt, tool
  definitions and CLAUDE.md prefix stay cached across sessions, so re-warming costs little.
  Compact has a floor (summary + prefix); clear returns to the prefix alone.
- Neither stops new work from re-inflating context. Check whether context has peaked *above*
  its pre-compact level before recommending another compact.

## Tool output is not a one-off

Every byte a tool returns lands in the conversation and is re-read on every remaining call.
The true weight of a tool result is **size x calls remaining**, not size once. A large file
read early in a long session is far heavier than the same read at the end.

## The measurement trap — get this right or every number is wrong

The transcript **re-writes the same assistant message while it streams**, so the same
`message.id` appears on several lines. A naive sum roughly doubles every figure.

```bash
jq -s 'group_by(.message.id) | map(.[-1])' session.jsonl
```

Other things worth knowing when reading a transcript directly:

- compact boundaries are `{"type":"system","subtype":"compact_boundary"}` carrying
  `compactMetadata` (trigger, preTokens, postTokens, cumulativeDroppedTokens, durationMs)
- `customTitle` is the seat, `aiTitle` is the work — show both or every row looks identical
- cache writes split by TTL under `usage.cache_creation`
  (`ephemeral_5m_input_tokens`, `ephemeral_1h_input_tokens`)

## Tooling in this plugin

- `/tokenomics` — measure this session and summarise it; `--list`, `--projects`,
  `--dashboard`, `--artifact`.
- `scripts/tokenomics.sh` — measure any transcript, render HTML. `--list`, `--projects`,
  `--watch N --serve PORT`, `--inline -o page.html`, `--json`.
- `statusline/statusline.sh` — live per-call and per-session token counts plus a compact
  nudge, in the Claude Code status line.
- `docs/tokenomics-explained.md` — the long-form companion: the rate card, rebuild
  arithmetic, and compact break-even worked through end to end.

## Framing rule

This measures **tokens and context**. Whether that is *money* depends on how the user is
authenticated, so do not assume:

- **Subscription (Pro / Max / Team / Enterprise)** — usage is included in the plan. Tokens
  are not charged per unit; they spend the user's **rate-limit budget**. The right framing
  is "this is why you hit your limit sooner", not "this cost you X".
- **API key / Console billing** — tokens map to real per-token charges at Anthropic's
  published rates. Here the weights above (0.1× / 1.25×–2× / 5×) are literally the billing
  structure.

Never quote a currency figure. Do not invent a rate, do not guess which plan the user is on,
and do not present a token count as a bill. If cost in money genuinely matters to the answer,
ask which billing mode they use. The advice is identical either way — only the unit of pain
changes — so in almost every case you can answer without knowing.
