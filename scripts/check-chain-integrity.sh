#!/usr/bin/env bash
# check-chain-integrity.sh [--ledger <path>] [--branch <name>] [--require-chain]
#
# Refuses to let a truncated `/otta:build` run reach `gh pr create`.
#
# WHY THIS EXISTS
#   workflows/otta-build.mjs already enforces the rule programmatically:
#     if (verify && verify.gatePassed && verify.allAcsPass) { ...ship... }
#   But that is only the bundled-Workflow path. commands/build.md documents three
#   other execution paths — native subagents, Codex primitives, and "run the four
#   role contracts sequentially in the current agent" — and in all three the rule
#   ("Never open the PR when review, qa, or the gate is failing") is PROSE. A
#   model that skips a stage produces the same artifacts as one that ran it.
#
#   Measured on a consumer repo (leadcognition/leadcognition_v2, 2026-08-05):
#   21 of 258 sessions ever spawned an Otta subagent, and from 2026-07-07 the
#   chains routinely truncated — builder-only (07-07, 07-09, 07-14, 08-03) and
#   builder+reviewer with no qa (07-16, 07-24 x2, 08-01) — while PRs still
#   opened. Over the same period the reviewer and qa stages, when they DID run,
#   failed 46.5% and 25.6% of the time on real defects. Silent truncation is
#   therefore the single most expensive failure mode in the pipeline.
#
# WHY DETECTION AND NOT PREVENTION
#   Same constraint documented in scripts/otta-bypass-detect.sh (#202): on a free
#   GitHub org, private repos cannot have branch protection, so no required check
#   can hold the line. Enforcement has to live at a point Otta itself controls.
#
# CONTRACT
#   A run is "pipeline-tier" when the ledger holds a `pipeline`/`build_start`
#   record for the branch. Only those runs require reviewer + qa verdicts.
#   /otta:fix documents skipping builder/reviewer/qa, emits no build_start, and is
#   therefore unaffected — the gate still applies to it, as fix.md requires.
#
#   --require-chain says "the caller asserts a pipeline run happened here". Under
#   that flag an unreadable ledger is a FAILURE, because a build that ran and
#   recorded nothing is exactly the state this check exists to catch. Without it
#   an unreadable ledger only warns: agents/devops.md is the shared ship contract
#   (/otta:ship and /otta:dev use it too), so failing closed by default would block
#   every PR in any repo that has never run the pipeline — a worse outage than the
#   one being prevented. The core detection (build_start present, stage missing)
#   needs no flag: that case has positive evidence either way.
#
# Exit 0 = chain intact, not pipeline-tier, or unverifiable-but-unasserted.
# Exit 1 = truncated chain, failing verdict, or unverifiable under --require-chain.
set -euo pipefail

TAG="[otta-gate:chain-integrity]"
LEDGER="" BRANCH="" REQUIRE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --ledger) LEDGER="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --require-chain) REQUIRE=1; shift;;
    -h|--help) sed -n '2,38p' "$0"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

if [ -z "$BRANCH" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

if [ -z "$LEDGER" ]; then
  # Mirror scripts/ledger-append.sh's destination exactly (DIR/SLUG.jsonl).
  _dir="${OTTA_LEDGER_DIR:-$HOME/.otta/ledger}"
  _project="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo unknown)"
  _slug="$(printf '%s' "$_project" | tr '/' '-' | tr -cd 'A-Za-z0-9._-')"
  [ -z "$_slug" ] && _slug="unknown"
  LEDGER="$_dir/$_slug.jsonl"
fi

if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then
  if [ "$REQUIRE" -eq 1 ]; then
    # The caller asserted a pipeline run happened. A build that ran and recorded
    # nothing is precisely the failure this check exists to catch, so "could not
    # check" must not mean "allowed" here.
    echo "⛔ $TAG a pipeline run was asserted but no ledger is readable at: $LEDGER" >&2
    echo "   The reviewer and qa verdicts were never recorded — refusing to certify the chain." >&2
    exit 1
  fi
  echo "⚠ $TAG cannot verify the chain — no readable ledger at $LEDGER (not asserted as a pipeline run; not blocking)." >&2
  exit 0
fi

if [ -z "$BRANCH" ]; then
  echo "⛔ $TAG cannot determine the current branch — refusing to certify the chain." >&2
  exit 1
fi

python3 - "$LEDGER" "$BRANCH" "$TAG" "$REQUIRE" <<'PY'
import json, sys

ledger_path, branch, tag = sys.argv[1], sys.argv[2], sys.argv[3]
require_chain = sys.argv[4] == "1"

records = []
try:
    with open(ledger_path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, start=1):
            if not raw.strip():
                continue
            try:
                obj = json.loads(raw)
            except json.JSONDecodeError as exc:
                # A corrupt ledger is not evidence of a clean run. Under
                # --require-chain that is fatal; otherwise it is unverifiable
                # rather than wrong, so warn and let the caller's own gates hold.
                if require_chain:
                    print(f"⛔ {tag} ledger is unparseable at line {lineno}: {exc}", file=sys.stderr)
                    print(f"   {ledger_path}", file=sys.stderr)
                    sys.exit(1)
                print(f"⚠ {tag} cannot verify the chain — ledger unparseable at line {lineno} (not blocking).", file=sys.stderr)
                sys.exit(0)
            if isinstance(obj, dict):
                records.append(obj)
except OSError as exc:  # noqa: unreachable under the bash pre-check, kept as defence
    print(f"⛔ {tag} cannot read the ledger: {exc}", file=sys.stderr)
    sys.exit(1)


def for_branch(source, event):
    """Records for THIS branch only, oldest→newest.

    A record without a `branch` field is not evidence for any particular branch.
    23 of 43 historical qa records predate that field; counting them would let an
    unrelated older run certify this one.
    """
    out = [
        r for r in records
        if r.get("source") == source
        and r.get("event") == event
        and r.get("branch") == branch
    ]
    out.sort(key=lambda r: str(r.get("ts", "")))
    return out


# Not pipeline-tier → nothing to enforce. /otta:fix and plain pushes land here.
#
# Under --require-chain the caller has asserted a pipeline DID run, so a missing
# marker is not a fast path — it is either a broken emit or a false assertion.
# Without this branch the check would carry its own bypass: the marker is written
# by an agent following prose, the same trust level as the rule being enforced,
# so a run that skipped the marker would also skip the check.
if not for_branch("pipeline", "build_start"):
    if require_chain:
        print(f"⛔ {tag} a pipeline run was asserted for {branch} but no build_start marker was recorded.", file=sys.stderr)
        print("   Either the build stage never emitted it, or this was not a pipeline run.", file=sys.stderr)
        print("   Refusing to certify a chain with no recorded beginning.", file=sys.stderr)
        sys.exit(1)
    print(f"✓ {tag} no pipeline run recorded for {branch} — fast path, chain check not applicable.")
    sys.exit(0)

missing, failed = [], []
for source, event, human in (
    ("reviewer", "spec_review", "reviewer (spec review)"),
    ("qa", "verify", "qa (adversarial verify)"),
):
    found = for_branch(source, event)
    if not found:
        missing.append(human)
        continue
    newest = found[-1]  # a later passing verdict supersedes an earlier failure
    try:
        score = float(newest.get("score", 0))
    except (TypeError, ValueError):
        score = 0.0
    if score < 1:
        failed.append((human, str(newest.get("feedback", "")).strip()))

if not missing and not failed:
    print(f"✓ {tag} chain intact for {branch} — reviewer and qa both verified.")
    sys.exit(0)

print(f"⛔ {tag} pipeline chain is incomplete for {branch} — refusing to open the PR.", file=sys.stderr)
for human in missing:
    print(f"   ✗ {human} never ran — no verdict recorded for this branch.", file=sys.stderr)
for human, feedback in failed:
    print(f"   ✗ {human} FAILED.", file=sys.stderr)
    if feedback:
        print(f"     {feedback}", file=sys.stderr)
print("   A truncated chain ships unreviewed work. Re-run the missing stage, or use", file=sys.stderr)
print("   /otta:fix if this change is genuinely tiny (it skips those stages by design).", file=sys.stderr)
sys.exit(1)
PY
