#!/usr/bin/env bash
# statusline-tokenomics.sh — the four token classes Claude Code does NOT show you,
# a context-window bar, and a compact nudge.
#
# The bar was originally omitted on the assumption that the UI already showed it. It
# does not, in the terminal, so it lives here — and it is the one number that answers
# "how much room is left", which the token classes deliberately do not.
#
# Verified against claude-code 2.1.220 status-line payload (function yRS).
#   .context_window.current_usage  = the LAST call only (Ahr walks back to one message)
# Deliberately money-free: no rate card, no dollars. Tokens and context only.
# Session totals are NOT in the payload, so we read the transcript — incrementally,
# by byte offset, so a 265 MB file costs the same per tick as a 2 MB one.
set -uo pipefail

J=$(cat)
g() { printf '%s' "$J" | jq -r "$1 // empty" 2>/dev/null; }

MODEL=$(g '.model.display_name')
USED=$(g '.context_window.used_percentage')
CTXMAX=$(g '.context_window.context_window_size')
CTXIN=$(g '.context_window.total_input_tokens')
L_IN=$(g '.context_window.current_usage.input_tokens')
L_OUT=$(g '.context_window.current_usage.output_tokens')
L_CR=$(g '.context_window.current_usage.cache_read_input_tokens')
L_CW=$(g '.context_window.current_usage.cache_creation_input_tokens')

# ---- locate the transcript ---------------------------------------------------
# .transcript_path is the documented field; the other two are belt-and-braces for
# builds/entrypoints where the base payload spread differs.
F=$(g '.transcript_path')
SID=$(g '.session_id')
if [ -z "$F" ] || [ ! -f "$F" ]; then
  PR="$HOME/.claude/projects"
  if [ -n "$SID" ]; then F=$(ls "$PR"/*/"$SID".jsonl 2>/dev/null | head -1); fi
  if [ -z "$F" ] || [ ! -f "$F" ]; then
    CWD=$(g '.workspace.project_dir'); [ -n "$CWD" ] || CWD=$(g '.cwd')
    SLUG=$(printf '%s' "$CWD" | sed 's#[/.]#-#g')
    F=$(ls -t "$PR/$SLUG"/*.jsonl 2>/dev/null | head -1)
  fi
fi

DIM=$'\033[2m'; R=$'\033[0m'; GRN=$'\033[32m'; AMB=$'\033[33m'; RED=$'\033[31m'
CYA=$'\033[36m'; MAG=$'\033[35m'; BLU=$'\033[34m'; SEP="${DIM} · ${R}"

human() { local n=${1:-0}
  if   [ "$n" -ge 1000000000 ]; then awk -v n="$n" 'BEGIN{printf "%.2fB", n/1e9}'
  elif [ "$n" -ge 1000000 ];    then awk -v n="$n" 'BEGIN{printf "%.1fM", n/1e6}'
  elif [ "$n" -ge 1000 ];       then awk -v n="$n" 'BEGIN{printf "%.1fk", n/1e3}'
  else printf '%s' "$n"; fi; }

# ---- incremental session totals ----------------------------------------------
# Dedup by message.id: the transcript REWRITES an assistant message while streaming,
# so the same id appears on several lines and only the last is real. Naive sums run
# ~2x high. We keep the running contribution of the newest id and subtract it when
# that id reappears -- which makes the dedup work across ticks, not just per chunk.
STATED="$HOME/.claude/.tokenomics-statusline"; mkdir -p "$STATED" 2>/dev/null
TOT=""
if [ -n "$F" ] && [ -f "$F" ]; then
  ST="$STATED/$(basename "$F" .jsonl).state"
  SIZE=$(stat -f%z "$F" 2>/dev/null || stat -c%s "$F" 2>/dev/null || echo 0)
  OFF=0; [ -f "$ST" ] && OFF=$(awk '$1=="OFFSET"{print $2}' "$ST" 2>/dev/null || echo 0)
  [ -z "$OFF" ] && OFF=0
  [ "$SIZE" -lt "$OFF" ] && { rm -f "$ST"; OFF=0; }          # file replaced

  # Cold start on a huge transcript would block the status line for ~19s at 265 MB.
  # Scan at most CAP bytes of history; totals are then marked partial with a leading ~.
  CAP=${TOKENOMICS_COLD_CAP:-33554432}
  PARTIAL=""
  if [ "$OFF" -eq 0 ] && [ "$SIZE" -gt "$CAP" ]; then
    OFF=$((SIZE - CAP)); PARTIAL=1
    printf 'OFFSET %d\nPARTIAL 1\n' "$OFF" > "$ST"
  fi

  if [ "$SIZE" -gt "$OFF" ]; then
    CHUNK=$(mktemp); tail -c "+$((OFF+1))" "$F" > "$CHUNK" 2>/dev/null
    NEW=$(mktemp); touch "$ST"
    awk -v off="$OFF" -v size="$SIZE" -v SF="$ST" '
      FILENAME==SF {                               # ---- replay saved state ----
        if ($1=="LAST") { lid=$2; lmod=$3; li=$4; lo=$5; lr=$6; lw=$7; lh=$8 }
        else if ($1=="PARTIAL") { partial=1 }
        else if ($1=="M") { I[$2]+=$3; O[$2]+=$4; CR[$2]+=$5; CW[$2]+=$6; W1[$2]+=$7 }
        next
      }
      {                                            # ---- new bytes ----
        bytes += length($0) + 1; last_len = length($0) + 1
        if ($0 !~ /"usage"/) { prev_counted=0; next }
        id=""; if (match($0, /"id":"msg_[A-Za-z0-9_]+"/)) { id=substr($0,RSTART+6,RLENGTH-7) }
        if (id=="") next
        mod="?"; if (match($0, /"model":"[^"]+"/)) { mod=substr($0,RSTART+9,RLENGTH-10) }
        # regexes MUST be strings: a /re/ literal passed as an argument evaluates
        # to $0~/re/ (0 or 1), which silently zeroes every count.
        i=n("\"input_tokens\":[0-9]+",15);  o=n("\"output_tokens\":[0-9]+",16)
        r=n("\"cache_read_input_tokens\":[0-9]+",26)
        w=n("\"cache_creation_input_tokens\":[0-9]+",30)
        h=n("\"ephemeral_1h_input_tokens\":[0-9]+",28)
        if (id==lid) { I[lmod]-=li; O[lmod]-=lo; CR[lmod]-=lr; CW[lmod]-=lw; W1[lmod]-=lh }
        I[mod]+=i; O[mod]+=o; CR[mod]+=r; CW[mod]+=w; W1[mod]+=h
        lid=id; lmod=mod; li=i; lo=o; lr=r; lw=w; lh=h
      }
      function n(re, skip,   s) { if (match($0, re)) { s=substr($0,RSTART+skip,RLENGTH-skip); return s+0 } return 0 }
      END {
        # advance the offset only to the last complete line, so a half-written
        # trailing record is re-read whole next tick instead of being lost
        adv = bytes; if (off + bytes > size) adv = bytes - last_len
        printf "OFFSET %d\n", off + adv > OUTS
        printf "LAST %s %s %d %d %d %d %d\n", lid, lmod, li, lo, lr, lw, lh > OUTS
        if (partial) printf "PARTIAL 1\n" > OUTS
        for (m in I) printf "M %s %d %d %d %d %d\n", m, I[m], O[m], CR[m], CW[m], W1[m] > OUTS
        ti=0; to=0; tr=0; tw=0
        for (m in I) { ti+=I[m]; to+=O[m]; tr+=CR[m]; tw+=CW[m] }
        printf "%d %d %d %d\n", ti, to, tr, tw
      }
    ' OUTS="$NEW" "$ST" "$CHUNK" > "$STATED/.tot.$$" 2>/dev/null
    [ -s "$NEW" ] && mv "$NEW" "$ST" || rm -f "$NEW"
    TOT=$(cat "$STATED/.tot.$$" 2>/dev/null); rm -f "$CHUNK" "$STATED/.tot.$$"
  else
    TOT=$(awk '$1=="M"{i+=$3;o+=$4;r+=$5;w+=$6} END{printf "%d %d %d %d", i,o,r,w}' "$ST" 2>/dev/null)
  fi
fi

# ---- line 1: this call --------------------------------------------------------
# "Opus 5 call" read as "5 call" (a turn count) in testing -- the separator and the
# aligned row label make it unambiguous that these are two labelled rows, not a number.
PAD=$(printf '%*s' $(( ${#MODEL} + 3 )) '')
OUT="${MAG}${MODEL}${R}${SEP}${DIM}call${R}"
OUT+="  in ${BLU}$(human "${L_IN:-0}")${R}"
OUT+="  ${DIM}↻${R}${CYA}$(human "${L_CR:-0}")${R}"
OUT+="  ${DIM}✎${R}${AMB}$(human "${L_CW:-0}")${R}"
OUT+="  out ${GRN}$(human "${L_OUT:-0}")${R}"

# ---- line 2: session totals ---------------------------------------------------
if [ -n "$TOT" ]; then
  set -- $TOT; TI=${1:-0}; TO=${2:-0}; TR=${3:-0}; TW=${4:-0}
  P=""; grep -q '^PARTIAL' "$ST" 2>/dev/null && P="~"
  OUT+=$'\n'"${PAD}${DIM}sess${P}${R}"
  OUT+="  in ${BLU}$(human "$TI")${R}"
  OUT+="  ${DIM}↻${R}${CYA}$(human "$TR")${R}"
  OUT+="  ${DIM}✎${R}${AMB}$(human "$TW")${R}"
  OUT+="  out ${GRN}$(human "$TO")${R}"
  # A cost-share segment (in/read/write/out as % of spend) was prototyped here and
  # pulled: it needs a per-model rate card, and the session spans models, so a single
  # multiplier misstates it. The state file already keeps per-model totals and the 1h
  # write split, which is what a correct version would need. Parked, not lost.
fi

# ---- line 3: the context window ------------------------------------------------
# The only "how much room is left" number here; everything above is about cost.
# used_percentage is null before the first API call and again after a /compact until
# the next one, so the row is skipped rather than drawn as a misleading 0%.
UP=${USED%%.*}; UP=${UP:-0}
if [ -n "$USED" ]; then
  # Not the ▓░ blocks this started with: the bar sits under two dense rows of digits and
  # a heavy block competes with them. Dots recede almost completely when the window is
  # mostly empty, which is when the row has nothing to say. Box-drawing glyphs (━─) were
  # the other candidate but render with hairline gaps in some terminal fonts; ■ and ·
  # do not. 14 cells ≈ 7% each — enough resolution to see movement per turn.
  BW=${TOKENOMICS_BAR_WIDTH:-14}
  FILL=$(( UP * BW / 100 )); [ "$FILL" -gt "$BW" ] && FILL=$BW
  [ "$FILL" -lt 0 ] && FILL=0
  EMPTY=$(( BW - FILL ))
  BAR=""
  [ "$FILL"  -gt 0 ] && printf -v S "%${FILL}s"  && BAR="${S// /■}"
  [ "$EMPTY" -gt 0 ] && printf -v S "%${EMPTY}s" && BAR="${BAR}${S// /·}"
  if   [ "$UP" -ge 85 ]; then C=$RED
  elif [ "$UP" -ge 70 ]; then C=$AMB
  else C=$GRN; fi
  OUT+=$'\n'"${PAD}${DIM}ctx ${R} ${C}${BAR}${R} ${C}${UP}%${R}"
  [ -n "$CTXIN" ] && [ -n "$CTXMAX" ] && \
    OUT+="${DIM}  $(human "$CTXIN")/$(human "$CTXMAX")${R}"
fi

# ---- line 4: the compact nudge -------------------------------------------------
# Two separate arguments, deliberately not merged:
#   COST     — absolute tokens. Rent you pay on every call. True at any window size.
#   CAPACITY — % of window. Room left, and the point where a long context starts
#              costing recall as well as tokens.
# A 200k context on a 1M window is expensive but safe; 150k on a 200k window is both.
# Saving is quoted from the one compact measured in docs/: 107,585 → 35,481, a ~67% cut.
CUT=0; [ -n "$CTXIN" ] && CUT=$(( CTXIN * 67 / 100 ))
NUDGE_AT=${TOKENOMICS_NUDGE_AT:-150000}

if [ "$UP" -ge 85 ]; then
  OUT+=$'\n'"${PAD}${RED}⚠ /compact now${R}${DIM} — ${UP}% of window · ~$(human "$CUT") off every later call · long context also makes earlier detail easier to lose${R}"
elif [ "$UP" -ge 70 ]; then
  OUT+=$'\n'"${PAD}${AMB}◆ /compact soon${R}${DIM} — ${UP}% of window · ~$(human "$CUT") off every later call · long context also makes earlier detail easier to lose${R}"
elif [ -n "$CTXIN" ] && [ "$CTXIN" -ge "$NUDGE_AT" ]; then
  OUT+=$'\n'"${PAD}${DIM}◆ /compact would cut ~$(human "$CUT") from every later call (measured ≈67%)${R}"
fi

printf '%b\n' "$OUT"
