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

# ---- thresholds are ABSOLUTE, deliberately --------------------------------------
# Not a percentage of the context window. Two reasons. The window size is not given to
# hooks — the status line receives it as .context_window.context_window_size, but no
# hook payload carries it and it is not in the transcript either, so a percentage here
# would rest on a hardcoded constant that is wrong for somebody. Measured: a live opus-5
# session sat at 234k, which a 200k assumption would have called 117%. That session was
# on an extended (~1M) window, where a 70% rule would not fire until 700k — long after
# the rent became the point.
# More importantly, percentage answers "am I running out of room", which the UI already
# tracks. Rent is what this plugin is about, and 200k of context costs the same per
# call whether the window is 250k or 1M.
SOON=${TOKENOMICS_NUDGE_SOON:-120000}
NOW=${TOKENOMICS_NUDGE_NOW:-180000}

LEVEL=0
[ "$CTX" -ge "$SOON" ] && LEVEL=1
[ "$CTX" -ge "$NOW" ]  && LEVEL=2

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

if [ "$LEVEL" -ge 2 ]; then
  MSG="⚠ context $(human "$CTX") — /compact now. Every call re-sends all of it, and a turn-boundary rebuild re-files it at 2×."
else
  MSG="◆ context $(human "$CTX") — /compact soon. It repays over the calls that follow, so it is worth doing while calls remain."
fi

jq -n --arg m "$MSG" '{systemMessage: $m}'
