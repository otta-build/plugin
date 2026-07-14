#!/usr/bin/env bash
# otta-status.test.sh — AC4: checklist rendering (Idea → Build → Gate → CI → Release/Deploy)
# with pass/fail/pending markers, driven by scripts/otta-status.sh
# Run: bash tests/otta-status.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-status.sh"
fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$SCRIPT" ] || fail "otta-status.sh not found at $SCRIPT"
command -v jq >/dev/null || fail "jq required to run this test"

# =============================================================================
# 1. All-pass input renders all ✓ markers and a summary line
# =============================================================================
ALL_PASS='{
  "issue": "82",
  "stages": {
    "idea":    {"status": "pass", "detail": "issue #82 open"},
    "build":   {"status": "pass", "detail": "PR #90 open"},
    "gate":    {"status": "pass", "detail": "Otta Gate green"},
    "ci":      {"status": "pass", "detail": "CI green"},
    "release": {"status": "pass", "detail": "merged + tagged v1.2.0"}
  }
}'
OUTPUT="$(printf '%s' "$ALL_PASS" | bash "$SCRIPT" 2>&1)" || fail "script failed on all-pass input:\n$OUTPUT"
echo "$OUTPUT" | grep -q "Idea" || fail "missing Idea stage in output"
echo "$OUTPUT" | grep -q "Build" || fail "missing Build stage in output"
echo "$OUTPUT" | grep -q "Gate" || fail "missing Gate stage in output"
echo "$OUTPUT" | grep -q "CI" || fail "missing CI stage in output"
echo "$OUTPUT" | grep -q "Release" || fail "missing Release/Deploy stage in output"
CHECK_COUNT="$(echo "$OUTPUT" | grep -o '✓' | wc -l | tr -d ' ')"
[ "$CHECK_COUNT" -ge 5 ] || fail "expected at least 5 ✓ markers, got $CHECK_COUNT:\n$OUTPUT"
echo "  ✓ all-pass renders 5 ✓ markers"

# =============================================================================
# 2. Mixed status renders the right marker per stage (✓ / ✗ / ○)
# =============================================================================
MIXED='{
  "issue": "82",
  "stages": {
    "idea":    {"status": "pass",    "detail": "issue #82 open"},
    "build":   {"status": "pass",    "detail": "PR #90 open"},
    "gate":    {"status": "fail",    "detail": "Otta Gate: 2/3 sub-checks failing"},
    "ci":      {"status": "pending", "detail": "CI: queued"},
    "release": {"status": "pending", "detail": "not merged yet"}
  }
}'
OUTPUT="$(printf '%s' "$MIXED" | bash "$SCRIPT" 2>&1)" || fail "script failed on mixed input:\n$OUTPUT"

echo "$OUTPUT" | grep -qE '✓[[:space:]]+Idea' || fail "Idea should be ✓:\n$OUTPUT"
echo "$OUTPUT" | grep -qE '✓[[:space:]]+Build' || fail "Build should be ✓:\n$OUTPUT"
echo "$OUTPUT" | grep -qE '✗[[:space:]]+Gate' || fail "Gate should be ✗:\n$OUTPUT"
echo "$OUTPUT" | grep -qE '○[[:space:]]+CI' || fail "CI should be ○ (pending):\n$OUTPUT"
echo "$OUTPUT" | grep -qE '○[[:space:]]+Release' || fail "Release/Deploy should be ○ (pending):\n$OUTPUT"
echo "  ✓ mixed status renders correct per-stage markers"

# =============================================================================
# 3. Detail text for each stage is included in the output
# =============================================================================
echo "$OUTPUT" | grep -q "Otta Gate: 2/3 sub-checks failing" \
  || fail "gate detail text missing from output:\n$OUTPUT"
echo "$OUTPUT" | grep -q "not merged yet" \
  || fail "release detail text missing from output:\n$OUTPUT"
echo "  ✓ per-stage detail text present"

# =============================================================================
# 4. Issue number is echoed in the header
# =============================================================================
echo "$OUTPUT" | grep -q "82" || fail "issue number not echoed in output:\n$OUTPUT"
echo "  ✓ issue number present in header"

# =============================================================================
# 5. Invalid JSON input fails loudly (exit non-zero), doesn't silently pass
# =============================================================================
if printf 'not json' | bash "$SCRIPT" > /dev/null 2>&1; then
  fail "script should exit non-zero on invalid JSON input"
fi
echo "  ✓ invalid JSON input rejected"


# =============================================================================
# 6. Dashboard mode (AC84): "issues" array renders one compact row per issue
#    with a glyph per stage, instead of the full 5-line checklist.
# =============================================================================
DASHBOARD='{
  "issues": [
    {
      "issue": "82", "title": "Add otta:status command",
      "stages": {
        "idea":    {"status": "pass"},
        "build":   {"status": "pass"},
        "gate":    {"status": "pass"},
        "ci":      {"status": "pass"},
        "release": {"status": "pass"}
      }
    },
    {
      "issue": "84", "title": "status dashboard mode",
      "stages": {
        "idea":    {"status": "pass"},
        "build":   {"status": "pass"},
        "gate":    {"status": "fail"},
        "ci":      {"status": "pending"},
        "release": {"status": "pending"}
      }
    }
  ]
}'
OUTPUT="$(printf '%s' "$DASHBOARD" | bash "$SCRIPT" 2>&1)" || fail "script failed on dashboard input:\n$OUTPUT"

echo "$OUTPUT" | grep -q "82" || fail "issue #82 missing from dashboard output:\n$OUTPUT"
echo "$OUTPUT" | grep -q "84" || fail "issue #84 missing from dashboard output:\n$OUTPUT"
echo "$OUTPUT" | grep -q "Add otta:status command" || fail "issue #82 title missing:\n$OUTPUT"
echo "$OUTPUT" | grep -q "status dashboard mode" || fail "issue #84 title missing:\n$OUTPUT"

ROW_82="$(echo "$OUTPUT" | grep "82")"
ROW_84="$(echo "$OUTPUT" | grep "84")"
[ "$(echo "$ROW_82" | grep -o '✓' | wc -l | tr -d ' ')" -eq 5 ] || fail "issue #82 row should have 5 ✓ glyphs:\n$ROW_82"
echo "$ROW_84" | grep -q '✗' || fail "issue #84 row should have a ✗ glyph (gate failed):\n$ROW_84"
echo "$ROW_84" | grep -q '○' || fail "issue #84 row should have a ○ glyph (ci/release pending):\n$ROW_84"

LINE_COUNT_82="$(echo "$OUTPUT" | grep -c "82")"
[ "$LINE_COUNT_82" -eq 1 ] || fail "issue #82 should render as exactly one compact row, not a full checklist:\n$OUTPUT"
echo "  ✓ dashboard mode renders one compact row per issue with per-stage glyphs"

# =============================================================================
# 7. Dashboard mode with zero open issues still renders cleanly (no crash)
# =============================================================================
EMPTY_DASHBOARD='{"issues": []}'
OUTPUT="$(printf '%s' "$EMPTY_DASHBOARD" | bash "$SCRIPT" 2>&1)" || fail "script failed on empty dashboard input:\n$OUTPUT"
echo "  ✓ empty dashboard input handled without crash"

# =============================================================================
# 8. Dashboard mode sorts most-blocked/stalest first (AC89):
#    rank 0 = any stage "fail", rank 1 = any stage "pending" (no fail),
#    rank 2 = all "pass"; ties broken by createdAt ascending (older first).
# =============================================================================
UNSORTED='{
  "issues": [
    {
      "issue": "10", "title": "all pass, newer", "createdAt": "2026-06-20T00:00:00Z",
      "stages": {
        "idea": {"status": "pass"}, "build": {"status": "pass"}, "gate": {"status": "pass"},
        "ci": {"status": "pass"}, "release": {"status": "pass"}
      }
    },
    {
      "issue": "20", "title": "has a fail, older", "createdAt": "2026-06-01T00:00:00Z",
      "stages": {
        "idea": {"status": "pass"}, "build": {"status": "pass"}, "gate": {"status": "fail"},
        "ci": {"status": "pending"}, "release": {"status": "pending"}
      }
    },
    {
      "issue": "30", "title": "has a fail, newer", "createdAt": "2026-06-15T00:00:00Z",
      "stages": {
        "idea": {"status": "pass"}, "build": {"status": "pass"}, "gate": {"status": "fail"},
        "ci": {"status": "pending"}, "release": {"status": "pending"}
      }
    },
    {
      "issue": "40", "title": "pending only, older", "createdAt": "2026-06-05T00:00:00Z",
      "stages": {
        "idea": {"status": "pass"}, "build": {"status": "pending"}, "gate": {"status": "pending"},
        "ci": {"status": "pending"}, "release": {"status": "pending"}
      }
    }
  ]
}'
OUTPUT="$(printf '%s' "$UNSORTED" | bash "$SCRIPT" 2>&1)" || fail "script failed on unsorted dashboard input:\n$OUTPUT"
ORDER="$(echo "$OUTPUT" | grep -oE '#[0-9]+' | tr -d '#')"
EXPECTED=$'20\n30\n40\n10'
[ "$ORDER" = "$EXPECTED" ] || fail "dashboard rows not sorted most-blocked/stalest first, got:\n$ORDER\nexpected:\n$EXPECTED"
echo "  ✓ dashboard mode sorts most-blocked/stalest first (fail > pending > pass, ties by createdAt ascending)"

# =============================================================================
# 9. Dashboard mode falls back to numeric issue number for tiebreak when
#    createdAt is absent (older gh versions / callers that omit it).
# =============================================================================
NO_CREATED_AT='{
  "issues": [
    {"issue": "9", "title": "pending, no createdAt", "stages": {"idea": {"status":"pending"}, "build":{"status":"pending"}, "gate":{"status":"pending"}, "ci":{"status":"pending"}, "release":{"status":"pending"}}},
    {"issue": "100", "title": "pending, no createdAt", "stages": {"idea": {"status":"pending"}, "build":{"status":"pending"}, "gate":{"status":"pending"}, "ci":{"status":"pending"}, "release":{"status":"pending"}}}
  ]
}'
OUTPUT="$(printf '%s' "$NO_CREATED_AT" | bash "$SCRIPT" 2>&1)" || fail "script failed on no-createdAt dashboard input:\n$OUTPUT"
ORDER="$(echo "$OUTPUT" | grep -oE '#[0-9]+' | tr -d '#')"
EXPECTED=$'9\n100'
[ "$ORDER" = "$EXPECTED" ] || fail "expected numeric issue-number tiebreak fallback, got:\n$ORDER"
echo "  ✓ dashboard mode falls back to numeric issue-number tiebreak when createdAt absent"

# =============================================================================
# 10. format-gate-detail: extracts the most recent /grade verdict feedback
#     for the matching branch, using synthetic Pulse JSON (no live network).
# =============================================================================
GRADE_JSON='{
  "counts": {"total": 4, "pass": 2, "fail": 2, "bySource": {}},
  "defects": {"issueReopened": 0, "prReverted": 0, "total": 0},
  "verdicts": [
    {"ts": "2026-06-30T12:00:00Z", "source": "gate", "event": "loop_verdict", "score": 0, "branch": "otta/89", "feedback": "tsc failed: 2 errors"},
    {"ts": "2026-06-29T12:00:00Z", "source": "gate", "event": "loop_verdict", "score": 1, "branch": "otta/89", "feedback": ""},
    {"ts": "2026-06-28T12:00:00Z", "source": "gate", "event": "loop_verdict", "score": 1, "branch": "otta/other", "feedback": ""}
  ]
}'
OUT="$(printf '%s' "$GRADE_JSON" | bash "$SCRIPT" format-gate-detail "otta/89")" || fail "format-gate-detail failed:\n$OUT"
[ "$OUT" = "gate failed: tsc failed: 2 errors" ] || fail "expected most-recent-verdict fail text, got: $OUT"
echo "  ✓ format-gate-detail returns most recent verdict's failure feedback for the branch"

OUT="$(printf '%s' "$GRADE_JSON" | bash "$SCRIPT" format-gate-detail "otta/other")" || fail "format-gate-detail failed:\n$OUT"
[ "$OUT" = "gate passed" ] || fail "expected pass text for otta/other, got: $OUT"
echo "  ✓ format-gate-detail returns pass text when the matching verdict passed"

OUT="$(printf '%s' "$GRADE_JSON" | bash "$SCRIPT" format-gate-detail "otta/no-such-branch")" || fail "format-gate-detail failed:\n$OUT"
[ -z "$OUT" ] || fail "expected empty output when no verdict matches the branch, got: $OUT"
echo "  ✓ format-gate-detail returns empty string when no verdict matches the branch"

# =============================================================================
# 11. format-release-detail: extracts /lifecycle version + shipped_at for the
#     matching issue, using synthetic Pulse JSON (no live network).
# =============================================================================
LIFECYCLE_JSON='{
  "repo": "otta-build/plugin",
  "items": [
    {"idea_ref": "issue:#89", "gh_issue": 89, "pr": 90, "commit": "abc123", "version": "v0.23.0", "shipped_at": "2026-07-01T09:00:00Z"},
    {"idea_ref": "issue:#82", "gh_issue": 82, "pr": 83, "commit": "def456", "version": "v0.22.0", "shipped_at": "2026-06-29T09:00:00Z"}
  ],
  "stats": {}
}'
OUT="$(printf '%s' "$LIFECYCLE_JSON" | bash "$SCRIPT" format-release-detail "89")" || fail "format-release-detail failed:\n$OUT"
[ "$OUT" = "merged + shipped v0.23.0 (2026-07-01T09:00:00Z)" ] || fail "expected shipped detail for issue 89, got: $OUT"
echo "  ✓ format-release-detail returns version + shipped_at for the matching issue"

OUT="$(printf '%s' "$LIFECYCLE_JSON" | bash "$SCRIPT" format-release-detail "999")" || fail "format-release-detail failed:\n$OUT"
[ -z "$OUT" ] || fail "expected empty output when no lifecycle item matches the issue, got: $OUT"
echo "  ✓ format-release-detail returns empty string when no lifecycle item matches the issue"

# =============================================================================
# 12. format-deploy-outcome: release evidence states are explicit and safe.
# =============================================================================
for pair in \
  'deploy_runtime_verified:pass:runtime_verified' \
  'deploy_included:pass:included' \
  'deploy_superseded:pass:superseded' \
  'deploy_workflow_failed:fail:failed' \
  'deploy_dispatch_unknown:fail:dispatch_unknown' \
  'deploy_blocked:fail:blocked' \
  'deploy_dispatched:pending:pending'; do
  event="${pair%%:*}"; rest="${pair#*:}"; expected_status="${rest%%:*}"; expected_outcome="${rest#*:}"
  OUT="$(bash "$SCRIPT" format-deploy-outcome "$event")" || fail "format-deploy-outcome failed for $event"
  [ "$(printf '%s' "$OUT" | jq -r .status)" = "$expected_status" ] || fail "$event status mismatch: $OUT"
  [ "$(printf '%s' "$OUT" | jq -r .outcome)" = "$expected_outcome" ] || fail "$event outcome mismatch: $OUT"
done
echo "  ✓ deploy outcomes render runtime_verified, included, superseded, failed, dispatch_unknown, blocked, and pending"

echo "✓ otta-status: all checks passed (all-pass render, mixed markers, detail text, header, invalid-input guard, dashboard mode, empty dashboard, dashboard sort + tiebreak, Pulse grade/lifecycle detail formatting)"
