#!/usr/bin/env bash
# check-chain-integrity.test.sh — isolated unit tests for scripts/check-chain-integrity.sh
#
# Covers OTT-71: a `/otta:build` run whose reviewer or qa stage never ran must not
# reach `gh pr create`. The bundled workflows/otta-build.mjs already enforces this
# programmatically (`if (verify.gatePassed && verify.allAcsPass)`), but the native
# subagent, Codex, and single-agent fallback paths in commands/build.md carry the
# same rule as PROSE only — nothing checks it. Measured on one consumer repo:
# 21/258 sessions spawned an Otta subagent, and from 2026-07-07 the chains
# routinely truncated (builder-only; builder+reviewer with no qa) while PRs still
# opened. This script is the harness-independent check.
#
# Run: bash tests/check-chain-integrity.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-chain-integrity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

BR="fix/ott-71-example"

# Helper: build a ledger file from record fragments. Each arg is one JSON line.
ledger() { local f="$TMP/$1"; shift; printf '%s\n' "$@" >"$f"; echo "$f"; }

rec() { # rec <source> <event> <score> [branch] [feedback]
  printf '{"ts":"2026-08-05T10:00:00Z","source":"%s","event":"%s","score":%s,"branch":"%s","feedback":"%s"}' \
    "$1" "$2" "$3" "${4:-$BR}" "${5:-}"
}

run() { bash "$SCRIPT" --ledger "$1" --branch "${2:-$BR}"; }

# ── Test 1: complete chain (build_start + reviewer pass + qa pass) → exit 0 ────
L="$(ledger t1.jsonl \
  "$(rec pipeline build_start 1)" \
  "$(rec reviewer spec_review 1)" \
  "$(rec qa verify 1)")"
run "$L" >/dev/null 2>&1 || fail "test 1: complete chain should pass"
pass "complete chain → pass"

# ── Test 2 (AC1): build_start present, NO qa record at all → exit 1 ───────────
L="$(ledger t2.jsonl \
  "$(rec pipeline build_start 1)" \
  "$(rec reviewer spec_review 1)")"
if run "$L" >/dev/null 2>&1; then fail "test 2: missing qa stage must fail"; fi
out="$(run "$L" 2>&1 || true)"
echo "$out" | grep -qi 'qa' || fail "test 2: failure must name the missing qa stage (got: $out)"
pass "[AC1] build_start without qa → fail, names the stage"

# ── Test 2b (AC1): build_start present, NO reviewer record → exit 1 ──────────
L="$(ledger t2b.jsonl \
  "$(rec pipeline build_start 1)" \
  "$(rec qa verify 1)")"
if run "$L" >/dev/null 2>&1; then fail "test 2b: missing reviewer stage must fail"; fi
pass "[AC1] build_start without reviewer → fail"

# ── Test 3 (AC2): newest qa record scored 0 → exit 1, surfaces its feedback ───
L="$(ledger t3.jsonl \
  "$(rec pipeline build_start 1)" \
  "$(rec reviewer spec_review 1)" \
  "$(rec qa verify 0 "$BR" "AC4 FAILED: no evidence for the redirect case")")"
if run "$L" >/dev/null 2>&1; then fail "test 3: qa score=0 must fail"; fi
out="$(run "$L" 2>&1 || true)"
echo "$out" | grep -qF 'AC4 FAILED' || fail "test 3: must surface the qa feedback (got: $out)"
pass "[AC2] qa score=0 → fail, reports the failing ACs"

# ── Test 4 (AC3): ledger missing + --require-chain → FAIL CLOSED ─────────────
# "Could not check" must never mean "allowed" — but only where the caller has
# asserted a pipeline run happened. See test 4c for why this is flag-gated.
if bash "$SCRIPT" --ledger "$TMP/does-not-exist.jsonl" --branch "$BR" --require-chain >/dev/null 2>&1; then
  fail "test 4: a missing ledger under --require-chain must FAIL, not skip"
fi
pass "[AC3] missing ledger + --require-chain → fail closed"

# ── Test 4b (AC3): unparseable ledger + --require-chain → FAIL CLOSED ────────
L="$(ledger t4b.jsonl 'this is not json at all' '{"broken":')"
if bash "$SCRIPT" --ledger "$L" --branch "$BR" --require-chain >/dev/null 2>&1; then
  fail "test 4b: an unparseable ledger under --require-chain must FAIL, not skip"
fi
pass "[AC3] unparseable ledger + --require-chain → fail closed"

# ── Test 4c: ledger missing WITHOUT --require-chain → warn, exit 0 ───────────
# agents/devops.md is the shared ship contract — /otta:ship and /otta:dev use it
# on repos that may never have run the pipeline. Failing closed there would block
# every PR in a repo with no ledger, which is a worse failure than the one being
# prevented. Only /otta:build asserts a chain ran, so only it passes the flag.
out="$(bash "$SCRIPT" --ledger "$TMP/does-not-exist.jsonl" --branch "$BR" 2>&1)" \
  || fail "test 4c: a missing ledger without --require-chain must not block"
echo "$out" | grep -qi 'warn\|cannot verify' || fail "test 4c: must warn about the unverifiable ledger (got: $out)"
pass "missing ledger without --require-chain → warn, do not block"

# ── Test 5 (AC4): no build_start marker (fast path / plain push) → exit 0 ────
# /otta:fix documents skipping builder/reviewer/qa; it must not be penalised.
L="$(ledger t5.jsonl "$(rec gate gate_run 1)")"
run "$L" >/dev/null 2>&1 || fail "test 5: a run with no build_start must pass (fast path)"
pass "[AC4] no build_start → pass (fast path unaffected)"

# ── Test 5b (AC4): no build_start WITH --require-chain → exit 1 ──────────────
# Closes the bypass this check would otherwise have: the build_start marker is
# emitted by an agent following prose — the same trust level as the rule being
# enforced. If a pipeline run simply never emitted it, a marker-keyed check would
# wave the run through. --require-chain means "the caller asserts a pipeline ran",
# so a missing marker under that flag is either a broken emit or a false
# assertion; both must fail rather than silently degrade to the fast path.
L="$(ledger t5b.jsonl "$(rec gate gate_run 1)")"
if bash "$SCRIPT" --ledger "$L" --branch "$BR" --require-chain >/dev/null 2>&1; then
  fail "test 5b: --require-chain with no build_start must fail, not fall through to fast path"
fi
out="$(bash "$SCRIPT" --ledger "$L" --branch "$BR" --require-chain 2>&1 || true)"
echo "$out" | grep -qi 'build_start\|never started\|no pipeline' \
  || fail "test 5b: failure must explain the missing marker (got: $out)"
pass "[AC4] --require-chain with no build_start → fail (no silent bypass)"

# ── Test 6: records for OTHER branches must not satisfy this branch ───────────
L="$(ledger t6.jsonl \
  "$(rec pipeline build_start 1)" \
  "$(rec reviewer spec_review 1 "other/branch")" \
  "$(rec qa verify 1 "other/branch")")"
if run "$L" >/dev/null 2>&1; then fail "test 6: another branch's verdicts must not count"; fi
pass "another branch's verdicts do not satisfy this branch"

# ── Test 7: recency — a later passing qa supersedes an earlier failure ───────
L="$(ledger t7.jsonl \
  "$(rec pipeline build_start 1)" \
  "$(rec reviewer spec_review 1)" \
  '{"ts":"2026-08-05T10:00:00Z","source":"qa","event":"verify","score":0,"branch":"fix/ott-71-example","feedback":"early fail"}' \
  '{"ts":"2026-08-05T11:00:00Z","source":"qa","event":"verify","score":1,"branch":"fix/ott-71-example","feedback":"all ACs verified"}')"
run "$L" >/dev/null 2>&1 || fail "test 7: newest qa verdict should win"
pass "newest qa verdict wins over an earlier failure"

# ── Test 8: a record with no branch field must not satisfy a branch check ────
# 23 of 43 historical qa records predate the branch field; they are not evidence
# for any particular branch.
L="$(ledger t8.jsonl \
  "$(rec pipeline build_start 1)" \
  '{"ts":"2026-08-05T10:00:00Z","source":"reviewer","event":"spec_review","score":1}' \
  '{"ts":"2026-08-05T10:00:00Z","source":"qa","event":"verify","score":1}')"
if run "$L" >/dev/null 2>&1; then fail "test 8: branchless records must not satisfy the check"; fi
pass "branchless records are not evidence for a branch"

echo "✓ all check-chain-integrity tests passed"
