#!/usr/bin/env bash
# otta-gate-demo.sh — live gate demo in a throwaway temp dir.
# Shows the gate block a code change with no test (RED), then pass after a test
# is added (GREEN). Runs entirely in mktemp -d; never touches the user's repo.
# Exit 0 on success, 1 if the demo logic itself misbehaves.
set -euo pipefail

# Resolve gate script path BEFORE any cd (must be absolute).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-test-coverage.sh"

if [ ! -f "$GATE" ]; then
  echo "⛔ check-test-coverage.sh not found at $GATE" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Otta Gate Demo (runs in throwaway temp dir — never touches your repo) ==="
echo ""

# All repo work in a subshell so the calling process's cwd never changes.
(
  cd "$TMP"
  git init -q
  git config user.email demo@otta.build
  git config user.name "Otta Demo"

  # Root commit so git has a history baseline.
  touch README.md
  git add README.md
  git commit -qm "chore: init"
  ROOT="$(git rev-list --max-parents=0 HEAD)"

  # Empty body file (no [test-impractical:] bypass).
  BODY="$TMP/pr-body.md"
  touch "$BODY"

  # ------------------------------------------------------------------
  # Phase 1 — code change WITHOUT a test: gate should BLOCK
  # ------------------------------------------------------------------
  printf '#!/usr/bin/env bash\necho "hello world"\n' > app.sh
  git add app.sh
  git commit -qm "feat: add app.sh"

  echo "→ Committed a code change (app.sh) with NO test file."
  echo "  Running gate..."
  echo ""

  GATE_OUTPUT=""
  if GATE_OUTPUT="$(bash "$GATE" "$ROOT" "$BODY" 2>&1)"; then
    echo "⛔ ERROR: gate should have blocked but passed — demo is broken" >&2
    echo "   gate output: $GATE_OUTPUT" >&2
    exit 1
  else
    echo "⛔ gate blocked: no test found — change cannot merge"
    echo "   (gate said: $(echo "$GATE_OUTPUT" | head -1))"
    echo ""
  fi

  # ------------------------------------------------------------------
  # Phase 2 — add a test: gate should PASS
  # ------------------------------------------------------------------
  printf '#!/usr/bin/env bash\n# test for app.sh\nbash app.sh | grep -q "hello world"\necho "✓ app output correct"\n' > app.test.sh
  git add app.test.sh
  git commit -qm "test: add app.test.sh"

  echo "→ Added app.test.sh. Running gate again..."
  echo ""

  if GATE_OUTPUT="$(bash "$GATE" "$ROOT" "$BODY" 2>&1)"; then
    echo "✓ gate passes: test file detected — change is clear to merge"
    echo "   (gate said: $(echo "$GATE_OUTPUT" | head -1))"
  else
    echo "⛔ ERROR: gate should have passed but blocked — demo is broken" >&2
    echo "   gate output: $GATE_OUTPUT" >&2
    exit 1
  fi
)

echo ""
echo "=== Demo complete (temp dir cleaned up automatically) ==="
echo "The same gate runs pre-push and in CI on every PR in this repo."
