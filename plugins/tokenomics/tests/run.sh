#!/usr/bin/env bash
# Golden test: measure() on the fixture transcript must reproduce golden.json byte for
# byte — that is the determinism claim, enforced. The fixture exercises the traps this
# tool exists to get right: streaming double-writes (dedup), message ids whose lexical
# order differs from chronological, a model switch, an idle gap past the 1h TTL, and
# TWO compact boundaries.
#
# Regenerating golden.json after an INTENDED change to measure():
#   python3 ../scripts/tokenomics.py --json fixture.jsonl > golden.json
# Diff it first. If the diff surprises you, that is the test working.
set -uo pipefail
cd "$(dirname "$0")"
TOK="../scripts/tokenomics.py"
pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

# jq is used by the ASSERTIONS below, not by the tool under test — the port
# removed tokenomics' own jq dependency, but the status line still needs it.
command -v jq >/dev/null || { echo "tests: jq is required by these assertions" >&2; exit 1; }

# ---- the golden test ----------------------------------------------------------
D=$(mktemp)
if python3 "$TOK" --json fixture.jsonl | diff -u golden.json - > "$D" 2>&1; then
  ok "measure golden — byte-identical"
else
  bad "measure golden"; sed -n '1,40p' "$D"
fi
rm -f "$D"

# ---- determinism: two runs, same bytes ---------------------------------------
A=$(python3 "$TOK" --json fixture.jsonl); B=$(python3 "$TOK" --json fixture.jsonl)
[ "$A" = "$B" ] && ok "deterministic across runs" || bad "deterministic across runs"

# ---- CLI guards ---------------------------------------------------------------
# A value-flag with no value must exit with an error — this once looped forever, so
# babysit the process instead of trusting it to return.
python3 "$TOK" --project >/dev/null 2>&1 &
pid=$!; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null; bad "--project without a value must exit, not hang"
elif wait "$pid"; then
  bad "--project without a value must exit non-zero"
else
  ok "value-flag without a value errors out"
fi

python3 "$TOK" --sessions abc >/dev/null 2>&1 && bad "--sessions abc must be rejected" \
  || ok "non-numeric value rejected"

python3 "$TOK" -h | grep -q '^usage:' && ok "-h prints usage" || bad "-h prints usage"

# ---- --statusline init --------------------------------------------------------
# This one WRITES to ~/.claude/settings.json, so every case runs against a throwaway
# HOME. A bug here corrupts a real user's settings, which is why the refusal paths
# matter more than the happy one.
SH=$(mktemp -d); mkdir -p "$SH/.claude"
SET="$SH/.claude/settings.json"

HOME="$SH" python3 "$TOK" --statusline init >/dev/null 2>&1
jq -e '.statusLine.command' "$SET" >/dev/null 2>&1 \
  && ok "--statusline init creates settings.json" || bad "--statusline init creates settings.json"

printf '{"model":"opus","effortLevel":"high"}\n' > "$SET"
HOME="$SH" python3 "$TOK" --statusline init >/dev/null 2>&1
[ "$(jq -r '[.model,.effortLevel]|join(",")' "$SET" 2>/dev/null)" = "opus,high" ] \
  && ok "--statusline init preserves existing keys" || bad "--statusline init preserves existing keys"

[ -f "$SET.tokenomics-bak" ] && ok "--statusline init writes a backup" || bad "--statusline init writes a backup"

jq '.statusLine.command="bash /somebody/else.sh"' "$SET" > "$SH/t" && mv "$SH/t" "$SET"
if HOME="$SH" python3 "$TOK" --statusline init >/dev/null 2>&1; then
  bad "--statusline init must refuse to clobber a foreign statusLine"
else
  [ "$(jq -r '.statusLine.command' "$SET")" = "bash /somebody/else.sh" ] \
    && ok "--statusline init refuses to clobber, leaves it intact" \
    || bad "--statusline init refused but still modified the file"
fi

HOME="$SH" python3 "$TOK" --statusline init --force >/dev/null 2>&1
[ "$(jq -r '.statusLine.command' "$SET")" != "bash /somebody/else.sh" ] \
  && ok "--statusline init --force replaces it" || bad "--statusline init --force replaces it"

printf '{ not json\n' > "$SET"
if HOME="$SH" python3 "$TOK" --statusline init >/dev/null 2>&1; then
  bad "--statusline init must refuse invalid JSON"
else
  [ "$(cat "$SET")" = "{ not json" ] \
    && ok "--statusline init leaves invalid JSON untouched" \
    || bad "--statusline init damaged an invalid settings.json"
fi
rm -rf "$SH"

# The command --statusline init WRITES must actually execute. Testing only that the JSON
# key appears is not enough: a version of this wrote `"python" "~/.claude/..."` and the
# shell handed Python a literal tilde, because ~ does not expand inside double quotes.
# The key was present and correct-looking; the status line was blank.
SH2=$(mktemp -d); mkdir -p "$SH2/.claude"
HOME="$SH2" python3 "$TOK" --statusline init >/dev/null 2>&1
CMD=$(jq -r '.statusLine.command' "$SH2/.claude/settings.json" 2>/dev/null)
PAYLOAD=$(printf '{"model":{"display_name":"T"},"transcript_path":"%s","context_window":{"used_percentage":50,"context_window_size":200000,"total_input_tokens":100000,"current_usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}}' "$(cd .. && pwd)/tests/fixture.jsonl")
if [ -n "$CMD" ] && printf '%s' "$PAYLOAD" | sh -c "$CMD" 2>/dev/null | grep -q 'ctx'; then
  ok "the command --statusline init writes actually runs"
else
  bad "the command --statusline init writes does not run: $CMD"
fi
rm -rf "$SH2"

# ---- status line ---------------------------------------------------------------
# The context row derives its percentage through a fallback chain, and every bug in it so
# far has looked the same from outside: a row silently not existing, indistinguishable
# from a broken plugin. So assert the row is PRESENT for each shape of payload.
SL="../statusline/statusline.py"
FIX=$(cd .. && pwd)/tests/fixture.jsonl
pay() { # $1 extra context_window fields
  printf '{"model":{"display_name":"M"},"transcript_path":"%s","context_window":{%s"current_usage":{"input_tokens":38,"output_tokens":740,"cache_read_input_tokens":150000,"cache_creation_input_tokens":2100}}}' "$FIX" "$1"
}
ctxrow() { pay "$1" | python3 "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^ *ctx '; }

[ "$(ctxrow '"used_percentage":76,"context_window_size":200000,"total_input_tokens":152000,')" = 1 ] \
  && ok "ctx row: used_percentage present" || bad "ctx row: used_percentage present"

[ "$(ctxrow '"context_window_size":200000,"total_input_tokens":152000,')" = 1 ] \
  && ok "ctx row: derived from total_input_tokens" || bad "ctx row: derived from total_input_tokens"

# The regression that hid the row AND the nudge: a literal 0 is non-empty, so a presence
# check passed while the value carried nothing.
[ "$(ctxrow '"context_window_size":200000,"total_input_tokens":0,')" = 1 ] \
  && ok "ctx row: total_input_tokens=0 falls through to current_usage" \
  || bad "ctx row: total_input_tokens=0 falls through to current_usage"

[ "$(ctxrow '"context_window_size":200000,')" = 1 ] \
  && ok "ctx row: derived from current_usage alone" || bad "ctx row: derived from current_usage alone"

# No window size anywhere: the bar is genuinely undrawable, but the cost tier must survive.
n=$(pay '' | python3 "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -c 'compact')
[ "$n" -ge 1 ] && ok "no window size: bar drops but cost nudge survives" \
  || bad "no window size: bar drops but cost nudge survives"

# A typo in a documented env var must not take the whole line down.
for w in abc -5 0 ''; do
  n=$(pay '"used_percentage":50,"context_window_size":200000,"total_input_tokens":100000,' \
      | TOKENOMICS_BAR_WIDTH="$w" python3 "$SL" 2>/dev/null | grep -c .)
  [ "${n:-0}" -ge 3 ] || { bad "TOKENOMICS_BAR_WIDTH='$w' blanks the status line"; break; }
done
[ "${n:-0}" -ge 3 ] && ok "hostile TOKENOMICS_BAR_WIDTH falls back, line survives"

# ---- the compact nudge ----------------------------------------------------------
# The nudge is a LADDER: it speaks once per NUDGE_AT of context (150k, 300k, 450k) and is
# silent in between. A compact drops the context and re-arms it. Driven by rewriting a
# synthetic transcript, which is how a real session grows.
HD=$(mktemp -d); TX="$HD/sess.jsonl"; export CLAUDE_PLUGIN_DATA="$HD/state"
mkdir -p "$CLAUDE_PLUGIN_DATA"
HOOK="../hooks/compact-nudge.py"

# $1 = context tokens. Echoes "speak" or "silent".
turn() {
  python3 -c "
import json,sys
open(sys.argv[2],'w').write(json.dumps({'type':'assistant','timestamp':'2026-01-01T00:00:00.000Z',
 'message':{'id':'msg_x','model':'m','usage':{'input_tokens':0,'output_tokens':1,
 'cache_read_input_tokens':int(sys.argv[1]),'cache_creation_input_tokens':0}}})+'\n')" "$1" "$TX"
  out=$(printf '{"transcript_path":"%s","hook_event_name":"Stop"}' "$TX" | python3 "$HOOK" 2>/dev/null)
  [ -n "$out" ] && echo speak || echo silent
}

seq_got="$(turn 90000) $(turn 151000) $(turn 220000) $(turn 305000) $(turn 440000) $(turn 460000)"
seq_want="silent speak silent speak silent speak"
[ "$seq_got" = "$seq_want" ] && ok "nudge ladder: speaks once per 150k rung" \
  || bad "nudge ladder: got [$seq_got] want [$seq_want]"

# Tone escalates with the rung: ◆ for the first two, ⚠ from the third. The wording is
# driven by arithmetic rather than adjectives, so assert the marker and the multiple.
msg2() {
  python3 -c "
import json,sys
open(sys.argv[2],'w').write(json.dumps({'type':'assistant','timestamp':'2026-01-01T00:00:00.000Z',
 'message':{'id':'msg_x','model':'m','usage':{'input_tokens':0,'output_tokens':1,
 'cache_read_input_tokens':int(sys.argv[1]),'cache_creation_input_tokens':0}}})+'\n')" "$1" "$TX"
  printf '{"transcript_path":"%s","hook_event_name":"Stop"}' "$TX" | python3 "$HOOK" 2>/dev/null \
    | python3 -c "import sys,json;d=sys.stdin.read();print(json.loads(d)['systemMessage'] if d.strip() else '')"
}
rm -f "$CLAUDE_PLUGIN_DATA"/*.nudge
m1=$(msg2 155000); m2=$(msg2 310000); m3=$(msg2 465000)
esc=1
case "$m1" in "◆"*) ;; *) esc=0 ;; esac
case "$m2" in *"second reminder"*) ;; *) esc=0 ;; esac
case "$m3" in "⚠"*"3×"*) ;; *) esc=0 ;; esac
[ "$esc" = 1 ] && ok "nudge escalates: ◆ then ◆ then ⚠ with the multiple" \
  || bad "nudge escalation wrong: [$m1] [$m2] [$m3]"
rm -f "$CLAUDE_PLUGIN_DATA"/*.nudge

# a compact drops context; the ladder must re-arm and fire again on the way back up
seq_got2="$(turn 155000)"   # re-seed the ladder after the escalation check
rearm_got="$(turn 48000) $(turn 155000)"
[ "$rearm_got" = "silent speak" ] && ok "nudge re-arms after a compact" \
  || bad "nudge re-arms after a compact: got [$rearm_got]"

# it must never be the reason a turn fails
hook_ok=1
for bad_in in '{}' 'garbage' '{"transcript_path":"/nope.jsonl"}'; do
  printf '%s' "$bad_in" | python3 "$HOOK" >/dev/null 2>&1 || hook_ok=0
done
printf '{"transcript_path":"%s"}' "$TX" | TOKENOMICS_NUDGE=off python3 "$HOOK" 2>/dev/null | grep -q . && hook_ok=0
[ "$hook_ok" = 1 ] && ok "nudge exits 0 on bad input and obeys the off switch" \
  || bad "nudge exits non-zero on bad input, or ignores TOKENOMICS_NUDGE=off"
unset CLAUDE_PLUGIN_DATA
rm -rf "$HD"

echo "----"
echo "$pass passed, $fail failed"
exit "$fail"
