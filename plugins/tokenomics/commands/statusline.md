---
description: Check or set up the tokenomics status line — live token counts and a context bar in the terminal
argument-hint: "[init] [--force]"
allowed-tools: Bash
---

Check or configure the tokenomics status line.

The tool lives at `${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py`.

Arguments: `$ARGUMENTS`

- **no argument** → `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py --statusline`
  Reports where the status-line script is and whether `~/.claude/settings.json` points at
  it. Read-only. Run this first when someone says the status line is missing — it
  distinguishes "not configured" from "configured, pointing somewhere else".
- **`init`** → `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py --statusline init`
  Writes the `statusLine` block into `~/.claude/settings.json`.
- **`init --force`** → same with `--force`, which replaces a `statusLine` that is already
  set to something else.

`init` modifies the user's settings, so **say what it will do and get confirmation before
running it** unless the user explicitly asked to set it up. It is careful by construction —
it backs up to `settings.json.tokenomics-bak`, writes via tmp+mv, refuses to replace a
foreign `statusLine` without `--force`, and refuses to touch the file at all if it is not
valid JSON — but it is still their settings.

After a successful `init`, tell them it takes effect on their next interaction with Claude
Code, and show what the rows mean:

```
Opus 5 · call  in 38  ↻41.2k  ✎2.1k  out 740
         sess  in 2.0k  ↻3.9M  ✎238.8k  out 55.2k
         ctx  ■■■■■■■■■■■■··  91%  183.0k/200.0k
         ⚠ /compact now — 91% of window · ~122.6k off every later call
```

Row 1 is the last call, row 2 the session to date (`↻` cache read, `✎` cache write), row 3
the context window, row 4 the compact nudge when it applies.

Two things worth stating if they come up:

- **The status line is terminal only.** The desktop app has no surface to render one, so
  `init` will appear to do nothing there. That is not a failure — the plugin's `Stop` hook
  carries the compact nudge to the desktop instead, and it needs no setup.
- **A plugin cannot ship a `statusLine`.** Plugin `settings.json` currently honours only
  the `agent` and `subagentStatusLine` keys, which is the whole reason this command exists
  rather than the setting being installed automatically.
