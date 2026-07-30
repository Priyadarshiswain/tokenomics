---
name: tokenomics
description: Analyze a local Codex session's observed context growth, token usage, and prior compaction events. Use when the user asks about context pressure, token usage, or a Tokenomics dashboard.
---

# Tokenomics for Codex

Use the bundled `scripts/tokenomics.py` tool. It reads Codex session JSONL files locally and is read-only.

## Commands

- Current/latest session: `python3 scripts/tokenomics.py --json`
- Recent sessions: `python3 scripts/tokenomics.py --list`
- Dashboard: `python3 scripts/tokenomics.py --output /tmp/tokenomics.html`
- Live dashboard: `python3 scripts/tokenomics.py --watch 5 --serve 8899`

For an explicit session, pass `--session <id-or-path>`.

## Reporting rules

Lead with current context-window pressure, the observed context history, and any prior compaction events. Explain that all dashboard values are deterministic readings from local session history; it does not forecast future turns or compact outcomes.

Do not dump session transcripts into the chat. Read the compact JSON summary or open the generated dashboard instead.

Do not describe token counts as money. Tokenomics measures context and usage; it does not know the user's billing arrangement.

The dashboard is the nudge surface. Do not add model-visible hook output just to notify the user about context growth.
