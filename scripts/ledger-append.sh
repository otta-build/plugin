#!/usr/bin/env bash
# ledger-append.sh — append one GEPA-shaped record to the local Otta ledger.
#
# This is the LEARN-layer data capture (#36). It's a file write — 0 LM tokens —
# so capturing every gate run / pipeline verdict is essentially free. Records
# accrue across every project you push from into one user-level ledger, ready to
# become a GEPA trainset later (ADR-0004).
#
# Usage:
#   ledger-append.sh --source <s> --event <e> --score <0..1> --feedback <text> \
#                    [--project <owner/repo>] [--input <json>] [--output <json>] \
#                    [--executor <name>] [--harness <name>] [--session-id <id>] \
#                    [--issue <number>] [--pr <number>] [--branch <name>]
#
# Store: ${OTTA_LEDGER_DIR:-~/.otta/ledger}/<project-slug>.jsonl  (one file per repo)
set -euo pipefail

# Source repo-local Pulse config if present, but only for vars not already SET in env.
# An explicitly-exported env var (even empty) always wins over the file value.
if [ -f "./.otta/pulse.env" ]; then
  _url_set="${OTTA_PULSE_URL+set}"
  _token_set="${OTTA_PULSE_TOKEN+set}"
  _saved_url="${OTTA_PULSE_URL:-}"
  _saved_token="${OTTA_PULSE_TOKEN:-}"
  # shellcheck source=/dev/null
  . "./.otta/pulse.env"
  # Restore any var the caller had already SET in the environment.
  [ "$_url_set"   = "set" ] && OTTA_PULSE_URL="$_saved_url"
  [ "$_token_set" = "set" ] && OTTA_PULSE_TOKEN="$_saved_token"
  unset _url_set _token_set _saved_url _saved_token
fi

usage() {
  echo "usage: ledger-append.sh --source <s> --event <e> --score <n> --feedback <t> [--project p] [--input json] [--output json] [--executor name] [--harness name] [--session-id id] [--issue number] [--pr number] [--branch name]" >&2
  exit 2
}

SOURCE="" EVENT="" SCORE="" FEEDBACK="" PROJECT="" INPUT="{}" OUTPUT="{}"
EXECUTOR="" HARNESS="" SESSION_ID="" ISSUE="" PR="" BRANCH=""
EXECUTOR_SET=0 HARNESS_SET=0 SESSION_ID_SET=0 BRANCH_SET=0
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { echo "invalid argument: $1 requires a value" >&2; usage; }
  case "$1" in
    --source)   SOURCE="$2"; shift 2;;
    --event)    EVENT="$2"; shift 2;;
    --score)    SCORE="$2"; shift 2;;
    --feedback) FEEDBACK="$2"; shift 2;;
    --project)  PROJECT="$2"; shift 2;;
    --input)    INPUT="$2"; shift 2;;
    --output)   OUTPUT="$2"; shift 2;;
    --executor) EXECUTOR="$2"; EXECUTOR_SET=1; shift 2;;
    --harness)  HARNESS="$2"; HARNESS_SET=1; shift 2;;
    --session-id) SESSION_ID="$2"; SESSION_ID_SET=1; shift 2;;
    --issue)    ISSUE="$2"; shift 2;;
    --pr)       PR="$2"; shift 2;;
    --branch)   BRANCH="$2"; BRANCH_SET=1; shift 2;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
[ -z "$SOURCE" ] || [ -z "$EVENT" ] || [ -z "$SCORE" ] && {
  usage; }

case "$ISSUE" in ''|*[!0-9]*) [ -z "$ISSUE" ] || { echo "invalid --issue: expected a number" >&2; usage; };; esac
case "$PR" in ''|*[!0-9]*) [ -z "$PR" ] || { echo "invalid --pr: expected a number" >&2; usage; };; esac

# Explicit flags win. Environment identity is the next preference, followed by
# runtime-specific session markers. The latter make legacy Codex/Claude callers
# attributable without requiring changes at every call site.
[ "$EXECUTOR_SET" -eq 1 ] || EXECUTOR="${OTTA_EXECUTOR:-}"
[ "$HARNESS_SET" -eq 1 ] || HARNESS="${OTTA_HARNESS:-}"
if [ -n "${CODEX_THREAD_ID:-}" ]; then
  [ "$SESSION_ID_SET" -eq 1 ] || SESSION_ID="$CODEX_THREAD_ID"
  [ "$EXECUTOR_SET" -eq 1 ] || [ -n "$EXECUTOR" ] || EXECUTOR="codex"
  [ "$HARNESS_SET" -eq 1 ] || [ -n "$HARNESS" ] || HARNESS="codex"
elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  [ "$SESSION_ID_SET" -eq 1 ] || SESSION_ID="$CLAUDE_CODE_SESSION_ID"
  [ "$EXECUTOR_SET" -eq 1 ] || [ -n "$EXECUTOR" ] || EXECUTOR="claude_code"
  [ "$HARNESS_SET" -eq 1 ] || [ -n "$HARNESS" ] || HARNESS="claude_code"
fi
[ "$BRANCH_SET" -eq 1 ] || BRANCH="$(git branch --show-current 2>/dev/null || true)"

# Project: explicit, else the current repo, else 'unknown'.
[ -z "$PROJECT" ] && PROJECT="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo unknown)"
SLUG="$(printf '%s' "$PROJECT" | tr '/' '-' | tr -cd 'A-Za-z0-9._-')"
[ -z "$SLUG" ] && SLUG="unknown"

DIR="${OTTA_LEDGER_DIR:-$HOME/.otta/ledger}"
mkdir -p "$DIR"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the record with jq if available (safe escaping), else a minimal fallback.
# Capture into RECORD so we can also POST it to Pulse without re-building.
if command -v jq >/dev/null 2>&1; then
  validate_jq_json() {
    jq -en --arg raw "$2" '
      def without_strings: gsub("\"([^\"\\\\]|\\\\.)*\""; "\"\"");
      (($raw | without_strings |
        test("(^|[[:space:]\\[\\]{},:])[-+]?(NaN|Infinity)([[:space:]\\[\\]{},:]|$)")) | not)
      and (($raw | fromjson | [.. | numbers | isfinite] | all))
    ' >/dev/null 2>&1 || { echo "invalid $1: expected finite standard JSON" >&2; usage; }
  }
  validate_jq_json --input "$INPUT"
  validate_jq_json --output "$OUTPUT"
  validate_jq_json --score "$SCORE"
  jq -e 'type == "number" and isfinite' >/dev/null 2>&1 <<<"$SCORE" || { echo "invalid --score: expected a number" >&2; usage; }
  RECORD="$(jq -cn --arg ts "$TS" --arg project "$PROJECT" --arg source "$SOURCE" \
        --arg event "$EVENT" --argjson score "$SCORE" --arg feedback "$FEEDBACK" \
        --argjson input "$INPUT" --argjson output "$OUTPUT" --arg executor "$EXECUTOR" \
        --arg harness "$HARNESS" --arg session_id "$SESSION_ID" --arg issue "$ISSUE" \
        --arg pr "$PR" --arg branch "$BRANCH" \
    'def optional: if . == "" then null else . end;
     def optional_number: if . == "" then null else tonumber end;
     {ts:$ts, project:$project, source:$source, event:$event, score:$score,
      feedback:$feedback, input:$input, output:$output, executor:($executor|optional),
      harness:($harness|optional), session_id:($session_id|optional),
      issue:($issue|optional_number), pr:($pr|optional_number), branch:($branch|optional)}')"
else
  command -v python3 >/dev/null 2>&1 || {
    echo "invalid environment: jq or python3 is required to validate JSON" >&2; usage;
  }
  RECORD="$(python3 - "$TS" "$PROJECT" "$SOURCE" "$EVENT" "$SCORE" "$FEEDBACK" \
    "$INPUT" "$OUTPUT" "$EXECUTOR" "$HARNESS" "$SESSION_ID" "$ISSUE" "$PR" "$BRANCH" <<'PY'
import json
import sys

(ts, project, source, event, score_raw, feedback, input_raw, output_raw,
 executor, harness, session_id, issue_raw, pr_raw, branch) = sys.argv[1:]
try:
    reject_constant = lambda value: (_ for _ in ()).throw(ValueError(f"non-finite JSON constant: {value}"))
    score = json.loads(score_raw, parse_constant=reject_constant)
    input_value = json.loads(input_raw, parse_constant=reject_constant)
    output_value = json.loads(output_raw, parse_constant=reject_constant)
except (TypeError, ValueError) as error:
    print(f"invalid JSON: {error}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(score, (int, float)) or isinstance(score, bool):
    print("invalid --score: expected a number", file=sys.stderr)
    raise SystemExit(2)
record = {
    "ts": ts, "project": project, "source": source, "event": event,
    "score": score, "feedback": feedback, "input": input_value,
    "output": output_value, "executor": executor or None,
    "harness": harness or None, "session_id": session_id or None,
    "issue": int(issue_raw) if issue_raw else None,
    "pr": int(pr_raw) if pr_raw else None, "branch": branch or None,
}
print(json.dumps(record, separators=(",", ":"), allow_nan=False))
PY
)" || usage
fi
printf '%s\n' "$RECORD" >> "$DIR/$SLUG.jsonl"

echo "✓ ledger += $EVENT (score=$SCORE) → $DIR/$SLUG.jsonl" >&2

# Best-effort /ledger stream: POST the raw record to Pulse when wired.
# Failures/timeouts are swallowed — they must NEVER affect the script's exit code.
if [ -n "${OTTA_PULSE_URL:-}" ] && [ -n "${OTTA_PULSE_TOKEN:-}" ] && [ -z "${OTTA_NO_CAPTURE:-}" ]; then
  curl -m 3 -s -o /dev/null \
    -X POST "${OTTA_PULSE_URL%/}/ledger" \
    -H "x-pulse-token: ${OTTA_PULSE_TOKEN}" \
    -H "content-type: application/json" \
    -d "$RECORD" || true
fi
