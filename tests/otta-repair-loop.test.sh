#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-repair-loop.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export OTTA_LEDGER_DIR="$TMP/local-ledger"
fail() { echo "FAIL: $1" >&2; exit 1; }

# Default classification is explicit and the accepted vocabulary is closed.
[ "$(bash "$SCRIPT" classify '- [ ] keeps working')" = test ] || fail "unlabelled AC should default to test"
[ "$(bash "$SCRIPT" classify '- [ ] [review] inspect output')" = review ] || fail "review label"
[ "$(bash "$SCRIPT" classify '- [ ] [human] approve live result')" = human ] || fail "human label"
[ "$(bash "$SCRIPT" classify '- [ ] [data-layer] schema works')" = test ] || fail "layer-only AC defaults to test"
[ "$(bash "$SCRIPT" classify '- [ ] [data-layer] [review] schema design')" = review ] || fail "layer then verification label"
[ "$(bash "$SCRIPT" classify '- [ ] [human] [ui-layer] approve UI')" = human ] || fail "verification then layer label"
bash "$SCRIPT" classify '- [ ] [review] [human] ambiguous' >/dev/null 2>&1 && fail "multiple verification labels should fail"

# Default max is 3 and can be configured.
set +e
out="$(bash "$SCRIPT" decide --attempt 3 --failure 'new failure' --state "$TMP/default")"; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "default max should escalate"
echo "$out" | grep -q 'Stopped after 3 of 3 repair attempts' || fail "default max stop output"
set +e
out="$(bash "$SCRIPT" decide --attempt 2 --max-revisions 2 --failure 'new failure' --state "$TMP/custom")"; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "configured max should escalate"
echo "$out" | grep -q '2 of 2' || fail "configured max"

# Equivalent blocker order/whitespace/case normalizes to one signature and repeats stop early.
bash "$SCRIPT" decide --attempt 1 --failure ' Missing Test ; AUTH Guard ' --state "$TMP/repeat" >/dev/null
set +e
out="$(bash "$SCRIPT" decide --attempt 2 --failure 'auth   guard;missing test' --state "$TMP/repeat" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "repeated signature should escalate with exit 2"
echo "$out" | grep -q 'same blockers repeated twice' || fail "repeat explanation"
echo "$out" | grep -q 'auth guard, missing test' || fail "human-readable blockers"
bash "$SCRIPT" emit --attempt 1 --stage reviewer --failure 'auth guard;missing test' --outcome stalled >/dev/null
jq -e '.event == "repair_attempt" and .output.attempt == 1 and .output.outcome == "stalled" and .output.failure_signature == "auth guard, missing test"' \
  "$(find "$OTTA_LEDGER_DIR" -type f -name '*.jsonl' -print -quit)" >/dev/null || fail "repeated stop ledger evidence"

rm -rf "$OTTA_LEDGER_DIR"; mkdir -p "$OTTA_LEDGER_DIR"
bash "$SCRIPT" emit --attempt 3 --stage reviewer --failure 'new blocker' --outcome stalled >/dev/null
jq -e '.event == "repair_attempt" and .output.attempt == 3 and .output.outcome == "stalled" and .output.failure_signature == "new blocker"' \
  "$(find "$OTTA_LEDGER_DIR" -type f -name '*.jsonl' -print -quit)" >/dev/null || fail "max stop ledger evidence"

# Pulse evidence is compact and best-effort when configured.
LEDGER="$TMP/pulse.jsonl" bash "$SCRIPT" decide --attempt 1 --stage reviewer --failure 'Missing test' --state "$TMP/pulse-state" >/dev/null
jq -e 'length == 4 and .attempt == 1 and .stage == "reviewer" and .failure_signature == "missing test" and .outcome == "retry"' "$TMP/pulse.jsonl" >/dev/null || fail "compact Pulse evidence"

mkdir -p "$TMP/bin" "$TMP/ledger"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"
PATH="$TMP/bin:$PATH" OTTA_PULSE_URL=http://pulse OTTA_PULSE_TOKEN=fake OTTA_LEDGER_DIR="$TMP/ledger" \
  bash "$SCRIPT" decide --attempt 1 --failure 'Review gap' --state "$TMP/wired-state" >/dev/null
ledger_file="$(find "$TMP/ledger" -type f -name '*.jsonl' -print -quit)"
jq -e '.event == "repair_attempt" and .output.attempt == 1 and .output.failure_signature == "review gap" and .output.outcome == "retry"' "$ledger_file" >/dev/null || fail "configured Pulse transport evidence"

# Read-only investigation is intentionally outside the mandatory workflow.
[ "$(bash "$SCRIPT" route --read-only)" = direct ] || fail "read-only route"
[ "$(bash "$SCRIPT" route --state-changing)" = otta ] || fail "state-changing route"

echo "otta-repair-loop: all checks passed"
