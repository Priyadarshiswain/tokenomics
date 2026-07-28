#!/usr/bin/env bash
# compact-nudge.sh — Stop hook. Says "/compact" once, when it starts being worth it.
#
# WHY A HOOK AND NOT THE STATUS LINE
# The status line renders in the terminal only; the desktop app has no surface for it.
# Hooks run everywhere, and unlike `statusLine` they ship with the plugin, so there is
# no manual settings.json step. Stop fires when Claude finishes a turn — the same moment
# the status line would have refreshed.
#
# WHY IT READS THE TRANSCRIPT
# Stop hooks do NOT receive context-window usage on stdin (the status-line payload does).
# So context size is recomputed here as input + cache_read + cache_creation of the last
# call, which is exactly how Claude Code derives its own context figure.
#
# WHY IT IS QUIET
# It speaks only when a threshold is CROSSED, not on every turn, and it re-arms when a
# compact drops context back down. A nag on every message would be noise, and noise in a
# plugin about wasted tokens would be self-defeating.
set -uo pipefail

[ "${TOKENOMICS_NUDGE:-on}" = "off" ] && exit 0

J=$(cat)
g() { printf '%s' "$J" | jq -r "$1 // empty" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || exit 0        # never break a turn over a missing dep

F=$(g '.transcript_path')
[ -n "$F" ] && [ -f "$F" ] || exit 0

# ---- context size, without reading the whole file -----------------------------
# Transcripts reach hundreds of MB. Read a bounded tail and take the last complete
# usage-bearing line. A truncated first line in the window is harmless: we only ever
# use the LAST match, and a jq failure exits quietly.
WINDOW=${TOKENOMICS_NUDGE_WINDOW:-262144}
LAST=$(tail -c "$WINDOW" "$F" 2>/dev/null | grep '"usage"' | tail -1)
[ -n "$LAST" ] || exit 0

CTX=$(printf '%s' "$LAST" | jq -r '
  (.message.usage // {})
  | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
' 2>/dev/null)
case "$CTX" in ''|*[!0-9]*) exit 0 ;; esac
[ "$CTX" -gt 0 ] || exit 0

# ---- one tier, absolute, COST only ----------------------------------------------
# The status line has a second and more urgent tier keyed on % of the context window:
# room left, plus the point where a long context starts costing recall as well as
# tokens. That tier cannot exist here — the status line is handed
# .context_window.context_window_size, but no hook payload carries it and it is not in
# the transcript either.
#
# The alternatives were both worse than doing without. A hardcoded constant is wrong for
# somebody: a live opus-5 session measured here sat at 234k, which a 200k assumption
# would have called 117%. Inferring the window from observed usage false-alarms in the
# dangerous direction — at 140k on a fresh 1M-window session it would assume 200k, call
# it 70%, and shout about a session sitting at 14%.
#
# So this makes the one argument it can make honestly: rent. 150k of context costs the
# same on every call whether the window is 200k or 1M.
NUDGE_AT=${TOKENOMICS_NUDGE_AT:-150000}

LEVEL=0
[ "$CTX" -ge "$NUDGE_AT" ] && LEVEL=1

# ---- speak only on a crossing --------------------------------------------------
# State is per transcript, so /clear starts clean. Storing the level (not a flag) is
# what re-arms the nudge after a compact: context falls, LEVEL falls, and the next
# climb crosses again.
STATED="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/.tokenomics-statusline}"
mkdir -p "$STATED" 2>/dev/null
NF="$STATED/$(basename "$F" .jsonl).nudge"
SEEN=0; [ -f "$NF" ] && SEEN=$(cat "$NF" 2>/dev/null)
case "$SEEN" in ''|*[!0-9]*) SEEN=0 ;; esac

[ "$LEVEL" -ne "$SEEN" ] && printf '%s' "$LEVEL" > "$NF" 2>/dev/null
[ "$LEVEL" -gt "$SEEN" ] || exit 0              # unchanged, or dropped after a compact

human() { local n=${1:-0}
  if   [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1e6}'
  elif [ "$n" -ge 1000 ];    then awk -v n="$n" 'BEGIN{printf "%.0fk", n/1e3}'
  else printf '%s' "$n"; fi; }

# The saving is the persuasive part, so quote it rather than just flagging size. The 67%
# figure is the one compact measured in docs/tokenomics-explained.md (107,585 → 35,481),
# labelled as measured so it does not read as a guarantee.
CUT=$(( CTX * 67 / 100 ))
MSG="◆ context $(human "$CTX") — a /compact here would cut about $(human "$CUT") from every call that follows (measured cut ≈67%). It repays over the calls remaining, so it is worth doing while there are some."

jq -n --arg m "$MSG" '{systemMessage: $m}'
