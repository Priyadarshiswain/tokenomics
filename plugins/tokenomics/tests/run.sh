#!/usr/bin/env bash
# Golden test: measure() on the fixture transcript must reproduce golden.json byte for
# byte — that is the determinism claim, enforced. The fixture exercises the traps this
# tool exists to get right: streaming double-writes (dedup), message ids whose lexical
# order differs from chronological, a model switch, an idle gap past the 1h TTL, and
# TWO compact boundaries.
#
# Regenerating golden.json after an INTENDED change to measure():
#   bash ../scripts/tokenomics.sh --json fixture.jsonl > golden.json
# Diff it first. If the diff surprises you, that is the test working.
set -uo pipefail
cd "$(dirname "$0")"
TOK="../scripts/tokenomics.sh"
pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

command -v jq >/dev/null || { echo "tests: jq is required" >&2; exit 1; }

# ---- the golden test ----------------------------------------------------------
D=$(mktemp)
if bash "$TOK" --json fixture.jsonl | diff -u golden.json - > "$D" 2>&1; then
  ok "measure golden — byte-identical"
else
  bad "measure golden"; sed -n '1,40p' "$D"
fi
rm -f "$D"

# ---- determinism: two runs, same bytes ---------------------------------------
A=$(bash "$TOK" --json fixture.jsonl); B=$(bash "$TOK" --json fixture.jsonl)
[ "$A" = "$B" ] && ok "deterministic across runs" || bad "deterministic across runs"

# ---- CLI guards ---------------------------------------------------------------
# A value-flag with no value must exit with an error — this once looped forever, so
# babysit the process instead of trusting it to return.
bash "$TOK" --project >/dev/null 2>&1 &
pid=$!; n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null; bad "--project without a value must exit, not hang"
elif wait "$pid"; then
  bad "--project without a value must exit non-zero"
else
  ok "value-flag without a value errors out"
fi

bash "$TOK" --sessions abc >/dev/null 2>&1 && bad "--sessions abc must be rejected" \
  || ok "non-numeric value rejected"

bash "$TOK" -h | grep -q '^usage:' && ok "-h prints usage" || bad "-h prints usage"

# ---- --statusline init --------------------------------------------------------
# This one WRITES to ~/.claude/settings.json, so every case runs against a throwaway
# HOME. A bug here corrupts a real user's settings, which is why the refusal paths
# matter more than the happy one.
SH=$(mktemp -d); mkdir -p "$SH/.claude"
SET="$SH/.claude/settings.json"

HOME="$SH" bash "$TOK" --statusline init >/dev/null 2>&1
jq -e '.statusLine.command' "$SET" >/dev/null 2>&1 \
  && ok "--statusline init creates settings.json" || bad "--statusline init creates settings.json"

printf '{"model":"opus","effortLevel":"high"}\n' > "$SET"
HOME="$SH" bash "$TOK" --statusline init >/dev/null 2>&1
[ "$(jq -r '[.model,.effortLevel]|join(",")' "$SET" 2>/dev/null)" = "opus,high" ] \
  && ok "--statusline init preserves existing keys" || bad "--statusline init preserves existing keys"

[ -f "$SET.tokenomics-bak" ] && ok "--statusline init writes a backup" || bad "--statusline init writes a backup"

jq '.statusLine.command="bash /somebody/else.sh"' "$SET" > "$SH/t" && mv "$SH/t" "$SET"
if HOME="$SH" bash "$TOK" --statusline init >/dev/null 2>&1; then
  bad "--statusline init must refuse to clobber a foreign statusLine"
else
  [ "$(jq -r '.statusLine.command' "$SET")" = "bash /somebody/else.sh" ] \
    && ok "--statusline init refuses to clobber, leaves it intact" \
    || bad "--statusline init refused but still modified the file"
fi

HOME="$SH" bash "$TOK" --statusline init --force >/dev/null 2>&1
[ "$(jq -r '.statusLine.command' "$SET")" != "bash /somebody/else.sh" ] \
  && ok "--statusline init --force replaces it" || bad "--statusline init --force replaces it"

printf '{ not json\n' > "$SET"
if HOME="$SH" bash "$TOK" --statusline init >/dev/null 2>&1; then
  bad "--statusline init must refuse invalid JSON"
else
  [ "$(cat "$SET")" = "{ not json" ] \
    && ok "--statusline init leaves invalid JSON untouched" \
    || bad "--statusline init damaged an invalid settings.json"
fi
rm -rf "$SH"

# ---- status line ---------------------------------------------------------------
# The context row derives its percentage through a fallback chain, and every bug in it so
# far has looked the same from outside: a row silently not existing, indistinguishable
# from a broken plugin. So assert the row is PRESENT for each shape of payload.
SL="../statusline/statusline.sh"
FIX=$(cd .. && pwd)/tests/fixture.jsonl
pay() { # $1 extra context_window fields
  printf '{"model":{"display_name":"M"},"transcript_path":"%s","context_window":{%s"current_usage":{"input_tokens":38,"output_tokens":740,"cache_read_input_tokens":150000,"cache_creation_input_tokens":2100}}}' "$FIX" "$1"
}
ctxrow() { pay "$1" | bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -c '^ *ctx '; }

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
n=$(pay '' | bash "$SL" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -c 'compact')
[ "$n" -ge 1 ] && ok "no window size: bar drops but cost nudge survives" \
  || bad "no window size: bar drops but cost nudge survives"

# A typo in a documented env var must not take the whole line down.
for w in abc -5 0 ''; do
  n=$(pay '"used_percentage":50,"context_window_size":200000,"total_input_tokens":100000,' \
      | TOKENOMICS_BAR_WIDTH="$w" bash "$SL" 2>/dev/null | grep -c .)
  [ "${n:-0}" -ge 3 ] || { bad "TOKENOMICS_BAR_WIDTH='$w' blanks the status line"; break; }
done
[ "${n:-0}" -ge 3 ] && ok "hostile TOKENOMICS_BAR_WIDTH falls back, line survives"

echo "----"
echo "$pass passed, $fail failed"
exit "$fail"
