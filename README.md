# tokenomics

A Claude Code plugin that measures where a session's **tokens and context** actually go.

Not a billing tool — it reports token counts and never asserts a price.

Whether those tokens are *money* depends on how you're authenticated, and the difference is
worth stating plainly:

| How you use Claude Code | What a token spends |
|---|---|
| **Pro / Max / Team / Enterprise** | nothing directly — usage is included in the plan. Tokens spend your **rate-limit budget**: the thing that decides whether you hit a cap mid-afternoon. |
| **API key (Console billing)** | **real money**, per token, at Anthropic's published rates. |

The mechanism this measures is identical either way, and so is the advice. Only the unit of
pain changes: on a subscription a wasteful session costs you *headroom*; on API billing it
costs you *cash*. If you are on a plan and have never thought about tokens, the useful frame
is that this tool shows you why you hit a limit sooner than you expected.

## What it gives you

| Surface | What it does |
|---|---|
| `/tokenomics` | measure a session, summarise it, or render an HTML report |
| status line | live per-call and per-session token counts, plus a compact nudge — **terminal only** |
| compact nudge | a `Stop` hook that speaks once when context gets expensive — works everywhere, including desktop |
| skill | Claude reaches for the mental model on its own when you ask why a session feels heavy |

## Install

```bash
/plugin marketplace add Priyadarshiswain/tokenomics
/plugin install tokenomics@pd-claude-plugins
```

Requires `bash` and `jq`. `python3` is optional — it is only used by `--serve` for the local
dashboard, and everything else works without it.

Once installed, `tokenomics` is on the Bash tool's `PATH` inside a Claude Code session, so
Claude can run `tokenomics --json` without knowing where the plugin lives. From your own
terminal, call the script by path (see below).

## The status line

**Terminal only.** The status line renders in the Claude Code CLI. It does not appear in the
desktop app — the setting applies and the script runs, but there is no surface to draw it on.
Measured, not assumed: identical settings render in a terminal and show nothing in desktop.
Desktop users get the same numbers on demand from `/tokenomics`.

`statusLine` is also a user setting that a plugin cannot ship — plugin `settings.json`
currently honours only the `agent` and `subagentStatusLine` keys — so this is one manual
step. Add a `statusLine` block to `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/plugins/marketplaces/pd-claude-plugins/plugins/tokenomics/statusline/statusline.sh",
  "refreshInterval": 5,
  "padding": 0
}
```

Or merge it in without opening an editor:

```bash
jq '.statusLine = {"type":"command","command":"bash ~/.claude/plugins/marketplaces/pd-claude-plugins/plugins/tokenomics/statusline/statusline.sh","refreshInterval":5,"padding":0}' ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
```

Note the path points at `marketplaces/` — the marketplace clone, which updates in place —
rather than `cache/<sha>/`, which gets a new directory on every release. If you cloned the
repo manually, point it at your own checkout instead. To confirm where it landed:

```bash
ls ~/.claude/plugins/marketplaces/*/plugins/*/statusline/statusline.sh
```

```
Opus 5 · call  in 38  ↻41.2k  ✎2.1k  out 740
         sess  in 2.0k  ↻3.9M  ✎238.8k  out 55.2k
         ctx  ■■■■■■■■■■■■··  91%  183.0k/200.0k
         ⚠ /compact now — ctx 91%; measured cut ≈67%
```

`↻` cache read · `✎` cache write. Row 1 is the last call, row 2 is the session to date.

Row 3 is the context window — the only "how much room is left" figure here; everything
above it is about cost. It is green below 70%, amber to 85%, red above. Claude Code does not
otherwise surface this in the terminal. The row is omitted rather than shown as `0%` when
`used_percentage` is null, which it is before the first API call and again after a `/compact`
until the next one repopulates it.

The bar is 14 cells (≈7% each); set `TOKENOMICS_BAR_WIDTH` to change it.

Row 4, the compact nudge, appears only at ≥70% and ≥85%.

Session totals are not in the status-line payload, so the script reads the transcript
**incrementally** by byte offset, keeping per-session state under
`~/.claude/.tokenomics-statusline/`. Steady-state cost is independent of transcript size:
0.03s per tick on a 265 MB transcript. Cold start is capped at 32 MB of back-scan
(`TOKENOMICS_COLD_CAP`); when capped the row reads `sess~` — the tilde means history before
the cap is not counted.

## The compact nudge

The status line's third row, delivered as a hook so it works where the status line cannot —
desktop included. Installed with the plugin; **no setup step**.

```
◆ context 124k — /compact soon. It repays over the calls that follow, so it is worth
                 doing while calls remain.
⚠ context 186k — /compact now. Every call re-sends all of it, and a turn-boundary
                 rebuild re-files it at 2×.
```

It runs on `Stop` — when Claude finishes a turn — and **speaks only when a threshold is
crossed**, never on every turn. A compact drops context back down and re-arms it, so it
warns again if context climbs a second time. A tool about wasted tokens should not itself
be noise.

| Variable | Default | Meaning |
|---|---|---|
| `TOKENOMICS_NUDGE_SOON` | `120000` | context tokens for the amber nudge |
| `TOKENOMICS_NUDGE_NOW` | `180000` | context tokens for the red one |
| `TOKENOMICS_NUDGE` | `on` | set to `off` to silence it entirely |

**Thresholds are absolute token counts, not a percentage of the context window** — on
purpose, for two reasons.

*It isn't available.* The status line is handed `context_window.context_window_size`; hooks
are not, and it is not in the transcript either. Any percentage here would rest on a
hardcoded constant that is wrong for someone — a live `opus-5` session measured here sat at
234k, which a 200k assumption would call 117%.

*It asks the wrong question.* Percentage answers "am I running out of room", which the UI
already tracks. Rent is what this plugin is about, and 200k of context costs the same per
call whether the window is 250k or 1M. On an extended (~1M) window a 70% rule would not fire
until 700k — long after the cost became the point.

Cost: it reads a bounded 256 KB tail of the transcript rather than the whole file —
**0.04s on a 253 MB transcript**. Every failure path exits silently, so a missing `jq`,
an unreadable transcript, or malformed input can never disrupt a turn.

## The measure tool

From a clone, call it by path. Inside a Claude Code session with the plugin installed, the
same arguments work as a bare `tokenomics` command.

```bash
cd plugins/tokenomics
bash scripts/tokenomics.sh                       # newest session of the current project
bash scripts/tokenomics.sh --list                # browse sessions
bash scripts/tokenomics.sh --projects            # every project, sizes, date ranges
bash scripts/tokenomics.sh --watch 30 --serve 8899   # live local dashboard
bash scripts/tokenomics.sh --inline -o page.html # self-contained snapshot, for publishing
bash scripts/tokenomics.sh --json                # just the measured data
```

Deterministic: same transcript in, byte-identical output. No network, no wall-clock reads
in the measurement.

Publishing an HTML snapshot as an Artifact requires a Claude turn — no shell command can
call the Artifact tool. That is what `/tokenomics --artifact` is for.

## The trap everything else gets wrong

The transcript **re-writes each assistant message while it streams**, so the same
`message.id` appears on several lines. A naive sum is about 2× too high. Both tools here
deduplicate by `message.id`; the status line does it incrementally, subtracting a message's
previous contribution when a newer version of the same id arrives.

## Layout

```
.claude-plugin/marketplace.json      the catalog — what this repo offers
plugins/tokenomics/                  the plugin itself; everything below ships on install
  .claude-plugin/plugin.json         manifest
  commands/tokenomics.md             the slash command
  skills/tokenomics/SKILL.md         model-triggered mental model
  scripts/tokenomics.sh              measure + render
  bin/tokenomics                     wrapper, so it is a bare command on the Bash tool's PATH
  statusline/statusline.sh           live status line (terminal)
  hooks/hooks.json                   Stop-hook registration
  hooks/compact-nudge.sh             the compact nudge (everywhere, incl. desktop)
  docs/tokenomics-explained.md       long-form companion
```
