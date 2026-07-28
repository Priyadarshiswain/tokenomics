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

echo "----"
echo "$pass passed, $fail failed"
exit "$fail"
