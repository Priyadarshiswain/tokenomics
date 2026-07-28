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

echo "----"
echo "$pass passed, $fail failed"
exit "$fail"
