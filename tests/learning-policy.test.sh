#!/usr/bin/env bash
# Regression coverage for issue #135: independent per-run learning controls,
# deterministic LEARNINGS.md consultation, metadata-only receipts, and capture opt-out.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-learning-policy.sh"
fail() { echo "✗ $1" >&2; exit 1; }

[ -x "$SCRIPT" ] || fail "otta-learning-policy.sh is missing or not executable"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/.otta.yml" <<'YAML'
learn:
  enabled: true
  consult: false
  capture: true
  expiry_days: 30
YAML

cat > "$TMP/LEARNINGS.md" <<'MD'
# Learnings

- 2026-07-12 [decision] active rule text
- 2026-05-01 [gotcha] expired rule text
- canonical engine active rule <!-- source: gate:3@2026-07-12T10:00:00Z | added: 2026-07-12 | expires: 2026-08-01 | recurrence: 2 | enforced-by: tests/engine-rule.test.sh -->
- canonical engine expired rule <!-- source: gate:1@2026-05-01T10:00:00Z | added: 2026-05-01 | expires: 2026-06-01 -->
- malformed content that is not a governed rule
MD

assert_receipt() {
  local path="$1" expression="$2" message="$3"
  python3 - "$path" "$expression" <<'PY' || fail "$message"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
if not eval(sys.argv[2], {"__builtins__": {}}, {"d": data}):
    raise SystemExit(1)
PY
}

# Repo defaults are independent: disabling consultation does not disable capture.
bash "$SCRIPT" prepare --config "$TMP/.otta.yml" --learnings "$TMP/LEARNINGS.md" \
  --receipt "$TMP/repo.json" --rules-output "$TMP/repo-rules.md" --now 2026-07-13 >/dev/null
assert_receipt "$TMP/repo.json" \
  'd["policy"]["consult"] is False and d["policy"]["capture"] is True' \
  "repo consult/capture defaults were not resolved independently"
assert_receipt "$TMP/repo.json" \
  'd["consultation"]["status"] == "skipped" and d["consultation"]["reason"] == "consult_disabled_repo"' \
  "disabled repo consultation lacks an explicit skip reason"

# Environment overrides beat repo defaults, consult only active/non-expired rules,
# and the receipt contains identifiers/count/provenance but no raw rule content.
OTTA_LEARN_CONSULT=true OTTA_LEARN_CAPTURE=false \
  bash "$SCRIPT" prepare --config "$TMP/.otta.yml" --learnings "$TMP/LEARNINGS.md" \
    --receipt "$TMP/env.json" --rules-output "$TMP/env-rules.md" --now 2026-07-13 >/dev/null
assert_receipt "$TMP/env.json" \
  'd["policy"] == {"consult": True, "consult_source": "environment", "capture": False, "capture_source": "environment"}' \
  "environment overrides did not beat repo defaults"
assert_receipt "$TMP/env.json" \
  'd["consultation"]["status"] == "consulted" and d["consultation"]["rule_count"] == 2 and d["consultation"]["rule_ids"][0] and d["consultation"]["rule_ids"][1] and d["consultation"]["provenance"] == "repo:LEARNINGS.md"' \
  "active-rule receipt is incomplete"
grep -q 'active rule text' "$TMP/env-rules.md" || fail "active rule was not supplied to the workflow"
! grep -q 'expired rule text' "$TMP/env-rules.md" || fail "expired rule was supplied to the workflow"
grep -q 'canonical engine active rule' "$TMP/env-rules.md" || fail "active canonical Engine rule was not supplied to the workflow"
! grep -q 'canonical engine expired rule' "$TMP/env-rules.md" || fail "expired canonical Engine rule was supplied to the workflow"
! grep -q 'active rule text\|expired rule text\|canonical engine active rule\|canonical engine expired rule' "$TMP/env.json" \
  || fail "receipt copied raw learning content"

# Explicit CLI run overrides beat environment overrides without coupling controls.
OTTA_LEARN_CONSULT=true OTTA_LEARN_CAPTURE=false \
  bash "$SCRIPT" prepare --config "$TMP/.otta.yml" --learnings "$TMP/LEARNINGS.md" \
    --receipt "$TMP/cli.json" --rules-output "$TMP/cli-rules.md" --now 2026-07-13 \
    --consult false --capture true >/dev/null
assert_receipt "$TMP/cli.json" \
  'd["policy"] == {"consult": False, "consult_source": "run_override", "capture": True, "capture_source": "run_override"}' \
  "explicit run overrides did not beat environment overrides"

# Missing and malformed config fail open: the workflow continues with a receipt.
bash "$SCRIPT" prepare --config "$TMP/missing.yml" --learnings "$TMP/LEARNINGS.md" \
  --receipt "$TMP/missing.json" --rules-output "$TMP/missing-rules.md" --now 2026-07-13 >/dev/null
assert_receipt "$TMP/missing.json" \
  'd["consultation"]["status"] == "skipped" and d["consultation"]["reason"] == "config_missing"' \
  "missing config did not fail open with an explicit reason"

cat > "$TMP/malformed.yml" <<'YAML'
learn:
  consult: sometimes
  capture: definitely
  expiry_days: yesterday
YAML
bash "$SCRIPT" prepare --config "$TMP/malformed.yml" --learnings "$TMP/LEARNINGS.md" \
  --receipt "$TMP/malformed.json" --rules-output "$TMP/malformed-rules.md" --now 2026-07-13 >/dev/null
assert_receipt "$TMP/malformed.json" \
  'd["consultation"]["status"] == "skipped" and d["consultation"]["reason"] == "config_malformed" and d["policy"]["capture"] is False' \
  "malformed config did not resolve safely"

# Legacy learn.enabled remains a fallback for repositories not yet using the two keys.
cat > "$TMP/legacy.yml" <<'YAML'
learn:
  enabled: true
  expiry_days: 30
YAML
bash "$SCRIPT" prepare --config "$TMP/legacy.yml" --learnings "$TMP/LEARNINGS.md" \
  --receipt "$TMP/legacy.json" --rules-output "$TMP/legacy-rules.md" --now 2026-07-13 >/dev/null
assert_receipt "$TMP/legacy.json" \
  'd["policy"]["consult"] is True and d["policy"]["capture"] is True and d["policy"]["consult_source"] == "repo_legacy_enabled"' \
  "legacy learn.enabled fallback is broken"

# A run-start capture decision survives later config/env drift for every verdict
# producer. Capture receipts stay metadata-only and identify the persisted policy.
RUN_DISABLED="$TMP/run-disabled"
mkdir -p "$RUN_DISABLED"
(
  cd "$RUN_DISABLED"
  bash "$SCRIPT" prepare --config "$TMP/.otta.yml" --learnings "$TMP/LEARNINGS.md" \
    --now 2026-07-13 --capture false >/dev/null
)
for producer in 'gate gate_run' 'reviewer spec_review' 'qa verify'; do
  set -- $producer
  (
    cd "$RUN_DISABLED"
    OTTA_LEDGER_DIR="$TMP/lifecycle-disabled-ledger" \
      bash "$SCRIPT" capture --config "$TMP/.otta.yml" \
        --receipt "$TMP/lifecycle-disabled.jsonl" --source "$1" --event "$2" \
        --score 0 --feedback 'RUN_POLICY_SECRET_SENTINEL' --project test/repo >/dev/null
  )
done
[ ! -e "$TMP/lifecycle-disabled-ledger/test-repo.jsonl" ] \
  || fail "persisted capture=false consent was lost after prepare"
python3 - "$TMP/lifecycle-disabled.jsonl" <<'PY' \
  || fail "persisted capture=false receipts are missing or unsafe"
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert len(lines) == 3
records = [json.loads(line) for line in lines]
assert [(r["source"], r["event"]) for r in records] == [
    ("gate", "gate_run"), ("reviewer", "spec_review"), ("qa", "verify")]
assert all(r["status"] == "skipped" and r["policy_origin"] == "run_receipt" for r in records)
assert "RUN_POLICY_SECRET_SENTINEL" not in "".join(lines)
PY

# The inverse decision is also stable: capture=true at run start still captures
# after the repo policy changes to false.
cat > "$TMP/capture-off.yml" <<'YAML'
learn:
  consult: false
  capture: false
YAML
RUN_ENABLED="$TMP/run-enabled"
mkdir -p "$RUN_ENABLED"
(
  cd "$RUN_ENABLED"
  bash "$SCRIPT" prepare --config "$TMP/.otta.yml" --learnings "$TMP/LEARNINGS.md" \
    --now 2026-07-13 --capture true >/dev/null
  OTTA_LEDGER_DIR="$TMP/lifecycle-enabled-ledger" \
    bash "$SCRIPT" capture --config "$TMP/capture-off.yml" \
      --receipt "$TMP/lifecycle-enabled.jsonl" --source qa --event verify \
      --score 1 --feedback 'run-start consent persists' --project test/repo >/dev/null
)
[ -s "$TMP/lifecycle-enabled-ledger/test-repo.jsonl" ] \
  || fail "persisted capture=true decision was lost after prepare"
assert_receipt "$TMP/lifecycle-enabled.jsonl" \
  'd["status"] == "captured" and d["policy_origin"] == "run_receipt"' \
  "capture=true lifecycle receipt did not identify its persisted policy"

# Callers may point capture at a non-default run-start policy receipt without
# conflating it with the append-only capture receipt output.
bash "$SCRIPT" prepare --config "$TMP/.otta.yml" --learnings "$TMP/LEARNINGS.md" \
  --receipt "$TMP/explicit-policy.json" --rules-output "$TMP/explicit-rules.md" \
  --now 2026-07-13 --capture false >/dev/null
OTTA_LEDGER_DIR="$TMP/explicit-policy-ledger" \
  bash "$SCRIPT" capture --config "$TMP/.otta.yml" \
    --policy-receipt "$TMP/explicit-policy.json" --receipt "$TMP/explicit-capture.jsonl" \
    --source gate --event gate_run --score 0 --feedback 'must stay skipped' \
    --project test/repo >/dev/null
[ ! -e "$TMP/explicit-policy-ledger/test-repo.jsonl" ] \
  || fail "explicit run-start policy receipt was ignored"

# A present but unreadable policy receipt fails closed instead of silently
# re-enabling capture from current config.
printf '{invalid\n' > "$TMP/invalid-policy.json"
OTTA_LEDGER_DIR="$TMP/invalid-policy-ledger" \
  bash "$SCRIPT" capture --config "$TMP/.otta.yml" \
    --policy-receipt "$TMP/invalid-policy.json" --receipt "$TMP/invalid-capture.jsonl" \
    --source reviewer --event spec_review --score 0 --feedback 'must not escape' \
    --project test/repo >/dev/null
[ ! -e "$TMP/invalid-policy-ledger/test-repo.jsonl" ] \
  || fail "invalid persisted policy receipt re-enabled capture"
assert_receipt "$TMP/invalid-capture.jsonl" \
  'd["status"] == "skipped" and d["reason"] == "policy_receipt_invalid" and d["policy_origin"] == "run_receipt"' \
  "invalid persisted policy did not fail closed with an explicit reason"

# Capture-disabled verdicts never enter the learning ledger; a sanitized skip
# receipt records source/event/reason without feedback or session content.
OTTA_LEDGER_DIR="$TMP/ledger-disabled" \
  bash "$SCRIPT" capture --config "$TMP/.otta.yml" \
    --policy-receipt "$TMP/no-prepare.json" --receipt "$TMP/capture.jsonl" \
    --capture false --source reviewer --event spec_review --score 0 \
    --feedback 'SESSION_SECRET_SENTINEL' --project test/repo >/dev/null
[ ! -e "$TMP/ledger-disabled/test-repo.jsonl" ] || fail "capture-disabled verdict entered the learning ledger"
python3 - "$TMP/capture.jsonl" <<'PY' || fail "capture skip receipt is missing or unsafe"
import json, sys
line = open(sys.argv[1], encoding="utf-8").read().strip()
record = json.loads(line)
assert record["status"] == "skipped"
assert record["reason"] == "capture_disabled_run_override"
assert record["policy_origin"] == "current_resolution"
assert record["source"] == "reviewer" and record["event"] == "spec_review"
assert "SESSION_SECRET_SENTINEL" not in line
PY

# Capture-enabled verdicts still use the canonical local ledger.
OTTA_LEDGER_DIR="$TMP/ledger-enabled" OTTA_NO_CAPTURE=1 \
  bash "$SCRIPT" capture --config "$TMP/.otta.yml" \
    --policy-receipt "$TMP/no-prepare.json" --receipt "$TMP/capture-enabled.jsonl" \
    --capture true --source qa --event verify --score 1 --feedback 'all ACs verified' \
    --project test/repo >/dev/null
[ -s "$TMP/ledger-enabled/test-repo.jsonl" ] || fail "capture-enabled verdict did not reach the learning ledger"

# Generated run state stays inspectable on disk without becoming a commit
# candidate. Exercise a linked worktree from a fresh Git repo with no .gitignore.
GIT_REPO="$TMP/git-repo"
GIT_FIXTURE="$TMP/git-worktree"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
cat > "$GIT_REPO/.otta.yml" <<'YAML'
learn:
  consult: true
  capture: true
  expiry_days: 30
YAML
cat > "$GIT_REPO/LEARNINGS.md" <<'MD'
# Learnings

- 2026-07-12 [decision] keep generated run state local
MD
git -C "$GIT_REPO" add .otta.yml LEARNINGS.md
git -C "$GIT_REPO" -c user.name=Otta -c user.email=otta@example.invalid \
  commit -qm baseline
git -C "$GIT_REPO" worktree add -q -b run-fixture "$GIT_FIXTURE"
(
  cd "$GIT_FIXTURE"
  bash "$SCRIPT" prepare --now 2026-07-13 >/dev/null
  bash "$SCRIPT" prepare --now 2026-07-13 >/dev/null
  OTTA_LEDGER_DIR="$TMP/git-fixture-ledger" \
    bash "$SCRIPT" capture --source gate --event gate_run --score 1 \
      --feedback 'all gates passed' --project test/repo >/dev/null
)
[ -s "$GIT_FIXTURE/.otta/run/learning-receipt.json" ] \
  || fail "run-start receipt is not inspectable locally"
[ -s "$GIT_FIXTURE/.otta/run/learning-capture-receipts.jsonl" ] \
  || fail "capture receipt is not inspectable locally"
[ -z "$(git -C "$GIT_FIXTURE" status --porcelain)" ] \
  || fail "generated .otta/run artifacts became commit candidates"
git -C "$GIT_FIXTURE" diff --quiet \
  || fail "learning policy mutated tracked source files"
[ "$(cd "$GIT_FIXTURE" && grep -cFx '/.otta/run/' "$(git rev-parse --git-path info/exclude)")" -eq 1 ] \
  || fail "local .otta/run exclusion is missing or duplicated"

# Callers may pass --input through the capture wrapper (e.g. qa/reviewer sending
# the current branch, #171) and it reaches the ledger record unchanged, joinable
# with Pulse /escape-rate. Captures with no --input still succeed (input: {}).
OTTA_LEDGER_DIR="$TMP/input-ledger" \
  bash "$SCRIPT" capture --config "$TMP/.otta.yml" \
    --policy-receipt "$TMP/no-prepare.json" --receipt "$TMP/input-capture.jsonl" \
    --capture true --source qa --event verify --score 1 --feedback 'all ACs verified' \
    --project test/repo --input '{"branch":"feat/171-capture-input-branch"}' >/dev/null
assert_receipt "$TMP/input-ledger/test-repo.jsonl" \
  'd["input"]["branch"] == "feat/171-capture-input-branch"' \
  "capture --input branch did not reach the ledger record"

OTTA_LEDGER_DIR="$TMP/no-input-ledger" \
  bash "$SCRIPT" capture --config "$TMP/.otta.yml" \
    --policy-receipt "$TMP/no-prepare.json" --receipt "$TMP/no-input-capture.jsonl" \
    --capture true --source reviewer --event spec_review --score 1 --feedback 'COMPLIANT' \
    --project test/repo >/dev/null
assert_receipt "$TMP/no-input-ledger/test-repo.jsonl" \
  'd["input"] == {}' \
  "capture without --input broke backward compatibility (AC4)"

# All three delivery paths prepare the same contract; gate/reviewer/QA use its capture wrapper.
for path in commands/dev.md commands/build.md commands/fix.md workflows/otta-build.mjs; do
  grep -q 'otta-learning-policy.sh.*prepare' "$HERE/../$path" \
    || fail "$path does not invoke the shared prepare contract"
done
for path in scripts/otta-gate.sh agents/reviewer.md agents/qa.md; do
  grep -q 'otta-learning-policy.sh.*capture' "$HERE/../$path" \
    || fail "$path does not invoke the shared capture contract"
done

echo "✓ learning-policy: independent controls, precedence, rules, receipts, opt-out, and workflow parity"
