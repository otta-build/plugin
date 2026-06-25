#!/usr/bin/env bash
# otta-gate-demo.test.sh — AC1/AC7: demo runs in temp dir, shows red→green, exits 0, leaves no artifact
# Run: bash tests/otta-gate-demo.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-gate-demo.sh"
fail() { echo "✗ $1" >&2; exit 1; }

# 1. Script must exist
[ -f "$SCRIPT" ] || fail "otta-gate-demo.sh not found at $SCRIPT"

# Record CWD and a sorted file list of the plugin repo (depth-limited)
BEFORE_CWD="$(pwd)"
BEFORE_FILES="$(find "$HERE/.." -maxdepth 3 -not -path '*/.git/*' | sort)"

# Run the demo, capturing stdout+stderr combined
OUTPUT="$(bash "$SCRIPT" 2>&1)" && STATUS=0 || STATUS=$?

# 2. Exits 0
[ "$STATUS" -eq 0 ] || fail "otta-gate-demo.sh exited $STATUS (expected 0); output:\n$OUTPUT"

# 3. Output shows a RED / blocked narration (gate blocked on no test)
echo "$OUTPUT" | grep -qiE "blocked|⛔|gate.*block|no test|test.*not found" \
  || fail "demo output missing red/blocked narration; got:\n$OUTPUT"

# 4. Output shows a GREEN / passes narration (after test added)
echo "$OUTPUT" | grep -qiE "green|passes|✓.*gate|gate.*pass|test.*detected|test file detected" \
  || fail "demo output missing green/passes narration; got:\n$OUTPUT"

# 5. CWD unchanged
[ "$(pwd)" = "$BEFORE_CWD" ] || fail "cwd changed from $BEFORE_CWD to $(pwd)"

# 6. No new files left in plugin repo (only demo's temp dir, outside plugin dir)
AFTER_FILES="$(find "$HERE/.." -maxdepth 3 -not -path '*/.git/*' | sort)"
NEW_FILES="$(comm -13 <(echo "$BEFORE_FILES") <(echo "$AFTER_FILES") || true)"
[ -z "$NEW_FILES" ] || fail "new files left in plugin repo after demo:\n$NEW_FILES"

echo "✓ otta-gate-demo: all checks passed (exit-0, red narration, green narration, cwd unchanged, no artifacts)"
