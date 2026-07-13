#!/usr/bin/env bash
# Regression test for ledger-append.sh (#36 LEARN-layer capture).
# Run: bash tests/ledger-append.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/ledger-append.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# 1. append a record → one valid GEPA-shaped JSON line
OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source gate --event gate_run --score 0 \
  --feedback "acceptance-block FAIL" --project "acme/web" --input '{"branch":"x"}' >/dev/null 2>&1
F="$TMP/acme-web.jsonl"
[ -f "$F" ] || fail "ledger file not created"
[ "$(wc -l < "$F" | tr -d ' ')" = "1" ] || fail "expected 1 record"
jq -e '.score==0 and .source=="gate" and .event=="gate_run" and .feedback=="acceptance-block FAIL" and .input.branch=="x"' "$F" >/dev/null || fail "record shape wrong"

# 1b. explicit executor attribution is preserved as exact top-level values.
OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source gate --event gate_run --score 1 \
  --feedback ok --project "attributed/repo" --executor codex --harness codex \
  --session-id thread-1 --issue 131 --pr 132 --branch feat/issue-131 >/dev/null 2>&1
ATTRIBUTED="$TMP/attributed-repo.jsonl"
jq -e '.executor=="codex" and .harness=="codex" and .session_id=="thread-1" and
  .issue==131 and .pr==132 and .branch=="feat/issue-131"' "$ATTRIBUTED" >/dev/null \
  || fail "explicit executor attribution wrong"

# 1c. legacy callers retain a stable schema: unavailable optional values are null.
LEGACY="$TMP/legacy-repo.jsonl"
(cd "$TMP" && unset OTTA_EXECUTOR OTTA_HARNESS CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID && \
  OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source gate --event gate_run --score 1 \
    --feedback ok --project "legacy/repo" >/dev/null 2>&1)
jq -e '.executor==null and .harness==null and .session_id==null and
  .issue==null and .pr==null and .branch==null and
  has("executor") and has("harness") and has("session_id") and
  has("issue") and has("pr") and has("branch")' "$LEGACY" >/dev/null \
  || fail "legacy caller schema is not stable"

# 1d. runtime identity defaults are stable, while explicit flags win.
OTTA_LEDGER_DIR="$TMP" OTTA_EXECUTOR=other OTTA_HARNESS=other CODEX_THREAD_ID=codex-env \
  bash "$SCRIPT" --source gate --event gate_run --score 1 --feedback ok \
    --project "defaults/codex" >/dev/null 2>&1
jq -e '.executor=="other" and .harness=="other" and .session_id=="codex-env"' \
  "$TMP/defaults-codex.jsonl" >/dev/null || fail "Codex/env defaults wrong"
OTTA_LEDGER_DIR="$TMP" CODEX_THREAD_ID=ignored OTTA_EXECUTOR=ignored OTTA_HARNESS=ignored \
  bash "$SCRIPT" --source gate --event gate_run --score 1 --feedback ok \
    --project "defaults/explicit" --executor explicit --harness explicit \
    --session-id explicit-session >/dev/null 2>&1
jq -e '.executor=="explicit" and .harness=="explicit" and .session_id=="explicit-session"' \
  "$TMP/defaults-explicit.jsonl" >/dev/null || fail "explicit identity did not win"
(unset CODEX_THREAD_ID OTTA_EXECUTOR OTTA_HARNESS; \
  OTTA_LEDGER_DIR="$TMP" CLAUDE_CODE_SESSION_ID=claude-env \
    bash "$SCRIPT" --source gate --event gate_run --score 1 --feedback ok \
      --project "defaults/claude" >/dev/null 2>&1)
jq -e '.executor=="claude_code" and .harness=="claude_code" and .session_id=="claude-env"' \
  "$TMP/defaults-claude.jsonl" >/dev/null || fail "Claude defaults wrong"

# 1e. branch defaults to the current attached git branch.
OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source gate --event gate_run --score 1 \
  --feedback ok --project "defaults/branch" >/dev/null 2>&1
CURRENT_BRANCH="$(git branch --show-current)"
if [ -n "$CURRENT_BRANCH" ]; then
  jq -e --arg branch "$CURRENT_BRANCH" '.branch==$branch' \
    "$TMP/defaults-branch.jsonl" >/dev/null || fail "git branch default wrong"
else
  jq -e '.branch==null' "$TMP/defaults-branch.jsonl" >/dev/null \
    || fail "detached HEAD branch default must remain null"
fi

# 2. second append → appends (does not overwrite)
OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source gate --event gate_run --score 1 --feedback ok --project "acme/web" >/dev/null 2>&1
[ "$(wc -l < "$F" | tr -d ' ')" = "2" ] || fail "expected 2 records after second append"

# 3. project slug sanitizes the slash
[ -f "$TMP/acme-web.jsonl" ] || fail "project slug not sanitized to acme-web"

# 4. feedback with quotes is escaped (valid JSON)
OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source qa --event verify --score 1 \
  --feedback 'AC1 "redirect" passed' --project "acme/web" >/dev/null 2>&1
tail -1 "$F" | jq -e '.feedback=="AC1 \"redirect\" passed"' >/dev/null || fail "quote escaping broken"

# 4b. valid JSON scalar null/false values are accepted for input and output.
OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source qa --event scalar --score 1 \
  --feedback ok --project "scalar/repo" --input null --output false >/dev/null 2>&1 \
  || fail "valid JSON scalar null/false rejected"
jq -e '.input == null and .output == false' "$TMP/scalar-repo.jsonl" >/dev/null \
  || fail "valid JSON scalar values changed"

# 4c. jq remains a self-contained legacy path when python3 is unavailable.
JQ_ONLY_BIN="$TMP/jq-only-bin"; mkdir -p "$JQ_ONLY_BIN"
for command_path in /bin/date /bin/mkdir /usr/bin/git /usr/bin/jq /usr/bin/tr; do
  [ -x "$command_path" ] && ln -s "$command_path" "$JQ_ONLY_BIN/$(basename "$command_path")"
done
(unset OTTA_EXECUTOR OTTA_HARNESS CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID; \
  PATH="$JQ_ONLY_BIN" OTTA_LEDGER_DIR="$TMP" /bin/bash "$SCRIPT" \
    --source qa --event jq_only --score 1 --feedback ok --project "jq-only/repo" \
    --input null --output false >/dev/null 2>&1) \
  || fail "jq-only legacy append requires python3"
jq -e '.input == null and .output == false and .executor == null' \
  "$TMP/jq-only-repo.jsonl" >/dev/null || fail "jq-only legacy record wrong"

# 5. missing required arg → exit 2
if OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source x >/dev/null 2>&1; then fail "should exit non-zero on missing args"; fi

# 5b. invalid JSON and non-numeric issue/PR values are rejected with usage errors.
for bad_args in \
  '--input {bad-json}' \
  '--output {bad-json}' \
  '--input NaN' \
  '--output Infinity' \
  '--input {"nested":[NaN]}' \
  '--output {"nested":1e999}' \
  '--issue issue-131' \
  '--pr pr-132'; do
  ERR="$TMP/error.log"
  if OTTA_LEDGER_DIR="$TMP" bash "$SCRIPT" --source x --event y --score 1 \
    --feedback ok --project invalid/repo $bad_args > /dev/null 2>"$ERR"; then
    fail "invalid value accepted: $bad_args"
  fi
  grep -qi 'usage\|invalid' "$ERR" || fail "invalid value lacks clear usage error: $bad_args"
done

# 5c. jq and forced no-jq/Python paths emit equivalent standard JSON records.
NO_JQ_BIN="$TMP/no-jq-bin"; mkdir -p "$NO_JQ_BIN"
for command_path in /bin/date /bin/mkdir /usr/bin/git /usr/bin/python3 /usr/bin/sed /usr/bin/tr; do
  [ -x "$command_path" ] && ln -s "$command_path" "$NO_JQ_BIN/$(basename "$command_path")"
done
JQ_LEDGER="$TMP/jq-path"; PY_LEDGER="$TMP/python-path"
mkdir -p "$JQ_LEDGER" "$PY_LEDGER"
EQUIVALENT_ARGS=(--source qa --event equivalent --score 0.5 --feedback 'same "record"' \
  --project equivalent/repo --input false --output null --executor codex --harness codex \
  --session-id equivalent-1 --issue 131 --pr 132 --branch feat/issue-131)
OTTA_LEDGER_DIR="$JQ_LEDGER" bash "$SCRIPT" "${EQUIVALENT_ARGS[@]}" >/dev/null 2>&1
PATH="$NO_JQ_BIN" OTTA_LEDGER_DIR="$PY_LEDGER" /bin/bash "$SCRIPT" \
  "${EQUIVALENT_ARGS[@]}" >/dev/null 2>&1
JQ_CANONICAL="$(jq -cS 'del(.ts)' "$JQ_LEDGER/equivalent-repo.jsonl")"
PY_CANONICAL="$(jq -cS 'del(.ts)' "$PY_LEDGER/equivalent-repo.jsonl")"
[ "$JQ_CANONICAL" = "$PY_CANONICAL" ] || fail "jq and Python records differ"

# 6. an unreachable Pulse push is best-effort: the ledger is still written and
#    the script still exits 0 (a slow/down server must never break the gate).
OTTA_LEDGER_DIR="$TMP" OTTA_PULSE_URL="http://127.0.0.1:9" OTTA_PULSE_TOKEN="t" \
  bash "$SCRIPT" --source qa --event verify --score 1 --feedback ok --project "acme/web" \
    --input '{"branch":"otta/5"}' >/dev/null 2>&1 \
  || fail "best-effort pulse push broke the gate (non-zero exit on unreachable server)"
[ "$(wc -l < "$F" | tr -d ' ')" = "4" ] || fail "ledger not written when pulse push fails"

# 7. the no-jq fallback still validates and emits valid enriched JSON.
PATH="$NO_JQ_BIN" OTTA_LEDGER_DIR="$TMP" /bin/bash "$SCRIPT" \
  --source qa --event fallback --score 1 --feedback 'fallback "ok"' \
  --project "fallback/repo" --input '{"valid":true}' --output '{"count":1}' \
  --executor codex --harness codex --session-id fallback-1 --issue 131 --pr 132 \
  --branch feat/issue-131 >/dev/null 2>&1
jq -e '.input.valid==true and .output.count==1 and .issue==131 and .pr==132 and
  .feedback=="fallback \"ok\""' "$TMP/fallback-repo.jsonl" >/dev/null \
  || fail "no-jq fallback did not emit valid enriched JSON"

echo "✓ ledger-append: all checks passed"
