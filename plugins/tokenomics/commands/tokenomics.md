---
description: Measure this session's token and context usage, and render it as an HTML report
argument-hint: "[session-id] | --list | --projects | --dashboard | --artifact"
allowed-tools: Bash, Read, Artifact
---

Run the tokenomics measure tool and report what it found.

The tool lives at `${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py`. It reads Claude Code
transcripts under `~/.claude/projects/` and is read-only — it never modifies a transcript.

Arguments: `$ARGUMENTS`

Pick the mode from the argument:

- no argument, or a session id → measure that session (default: the newest session of the
  current project) and summarise the result in the chat. Use `--json` and read the numbers;
  do NOT dump the whole JSON into the conversation.
- `--list` → `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py --list`
- `--projects` → `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py --projects`
- `--dashboard` → `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py --watch 30 --serve 8899`
  in the background, then give the user the URL. This one keeps running.
- `--artifact` → `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/tokenomics.py --inline -o <path>.html`,
  then publish that file with the Artifact tool. Publishing needs a Claude turn — a shell
  command cannot call the Artifact tool, which is the whole reason this mode exists as a
  slash command. Republishing the same path keeps the same URL.

When you report numbers, lead with the ones that change a decision:

- context per call and whether it is still growing
- cache read as a share of all tokens (it is normally >90% and that is not a problem — it is
  the cheapest class per token, so a high share is not a high cost)
- cache write spikes, which mark rebuilds — a broken cache, re-filed
- rebuild causes, ranked; turn boundaries usually dominate
- whether a `/compact` has happened and what it did to context per call

Two things to state plainly if they come up, because both are easy to get wrong:

- the transcript re-writes each assistant message while streaming, so any naive sum is about
  2x too high; the tool deduplicates by `message.id`
- token share is not load share. The four classes differ by up to 20x per token, so a 90%
  cache-read share is not 90% of anything that matters. Cache writes are the heavy class.
- this measures tokens and context. Whether that is money depends on the user's billing mode:
  on a subscription (Pro/Max/Team/Enterprise) usage is included and tokens spend a rate-limit
  budget instead; on API-key billing they are charged per token. Report token counts, never a
  currency figure, and do not guess which mode the user is on.
