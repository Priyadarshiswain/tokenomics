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
| status line | live per-call and per-session token counts, plus a compact nudge |
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

`statusLine` is a user setting and a plugin cannot ship one — plugin `settings.json`
currently honours only the `agent` and `subagentStatusLine` keys — so this is one manual
step. Installing via the marketplace above puts the plugin here:

```bash
claude config set --global statusLine '{"type":"command","command":"bash ~/.claude/plugins/marketplaces/pd-claude-plugins/plugins/tokenomics/statusline/statusline.sh","refreshInterval":5,"padding":0}'
```

If you cloned the repo manually instead, point that path at your own checkout. To confirm
where it actually landed:

```bash
ls ~/.claude/plugins/marketplaces/*/plugins/*/statusline/statusline.sh
```

```
Opus 5 · call  in 38  ↻41.2k  ✎2.1k  out 740
         sess  in 2.0k  ↻3.9M  ✎238.8k  out 55.2k
         ⚠ /compact now — ctx 91%; measured cut ≈67%
```

`↻` cache read · `✎` cache write. Row 1 is the last call, row 2 is the session to date.
The third row appears only at ≥70% (amber) and ≥85% (red) context.

Session totals are not in the status-line payload, so the script reads the transcript
**incrementally** by byte offset, keeping per-session state under
`~/.claude/.tokenomics-statusline/`. Steady-state cost is independent of transcript size:
0.03s per tick on a 265 MB transcript. Cold start is capped at 32 MB of back-scan
(`TOKENOMICS_COLD_CAP`); when capped the row reads `sess~` — the tilde means history before
the cap is not counted.

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
  statusline/statusline.sh           live status line
  docs/tokenomics-explained.md       long-form companion
```
