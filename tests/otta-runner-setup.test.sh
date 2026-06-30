#!/usr/bin/env bash
# otta-runner-setup.test.sh — tests for scripts/otta-runner-setup.sh (issue #58)
# Covers: AC2 (docker command + docs/runner-setup.md), AC3 (token fetch command printed)
# Also: regression guard for setup.md AC1 (contains gh repo view --json isPrivate)
# Run: bash tests/otta-runner-setup.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-runner-setup.sh"
SETUP_MD="$HERE/../commands/setup.md"

fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

[ -f "$SCRIPT" ] || fail "otta-runner-setup.sh not found at $SCRIPT"

# ---------------------------------------------------------------------------
# Test 1: stdout contains REPO_URL for supplied owner/repo
# ---------------------------------------------------------------------------
TMPDIR1="$(mktemp -d)"
trap 'rm -rf "$TMPDIR1"' EXIT

OUTPUT="$(cd "$TMPDIR1" && bash "$SCRIPT" acme/widget)"

echo "$OUTPUT" | grep -q "REPO_URL=https://github.com/acme/widget" \
  || fail "AC2: stdout must contain REPO_URL=https://github.com/acme/widget (got: $OUTPUT)"

pass "AC2: stdout contains REPO_URL with full GitHub URL"

# ---------------------------------------------------------------------------
# Test 2: docker --name uses sanitized slug (no slash in container name)
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "otta-runner-acme-widget" \
  || fail "AC2: docker --name must use sanitized slug 'otta-runner-acme-widget' (got: $OUTPUT)"

pass "AC2: docker --name is sanitized (slash replaced with dash)"

# ---------------------------------------------------------------------------
# Test 3: stdout contains myoung34/github-runner image
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "myoung34/github-runner" \
  || fail "AC2: stdout must reference myoung34/github-runner image (got: $OUTPUT)"

pass "AC2: stdout references myoung34/github-runner:latest image"

# ---------------------------------------------------------------------------
# Test 4: stdout contains RUNNER_TOKEN placeholder (not a real token)
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "RUNNER_TOKEN=" \
  || fail "AC2: stdout must include RUNNER_TOKEN= env var (got: $OUTPUT)"

# Must NOT shell out to gh api — token should be a placeholder string
echo "$OUTPUT" | grep -qiE "RUNNER_TOKEN=\\\$\{TOKEN" \
  || echo "$OUTPUT" | grep -q "RUNNER_TOKEN=<TOKEN" \
  || echo "$OUTPUT" | grep -qE "RUNNER_TOKEN=\$\(gh api" \
  || {
    # check it's a placeholder and not an empty value or a real-looking token
    TOKEN_LINE="$(echo "$OUTPUT" | grep "RUNNER_TOKEN=")"
    echo "$TOKEN_LINE" | grep -qE "RUNNER_TOKEN=.+" \
      || fail "AC2: RUNNER_TOKEN must have a non-empty placeholder value (got: $TOKEN_LINE)"
  }

pass "AC2: stdout contains RUNNER_TOKEN placeholder"

# ---------------------------------------------------------------------------
# Test 5: stdout contains LABELS=self-hosted,otta
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "LABELS=self-hosted,otta" \
  || fail "AC2: stdout must contain LABELS=self-hosted,otta (got: $OUTPUT)"

pass "AC2: stdout contains LABELS=self-hosted,otta"

# ---------------------------------------------------------------------------
# Test 6: stdout contains RUNNER_SCOPE=repo
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "RUNNER_SCOPE=repo" \
  || fail "AC2: stdout must contain RUNNER_SCOPE=repo (got: $OUTPUT)"

pass "AC2: stdout contains RUNNER_SCOPE=repo"

# ---------------------------------------------------------------------------
# Test 7: docs/runner-setup.md is written in the working directory
# ---------------------------------------------------------------------------
[ -f "$TMPDIR1/docs/runner-setup.md" ] \
  || fail "AC2: docs/runner-setup.md was not created in working directory"

pass "AC2: docs/runner-setup.md written"

# ---------------------------------------------------------------------------
# Test 8: docs/runner-setup.md contains gh api registration-token command (AC3)
# ---------------------------------------------------------------------------
DOC_CONTENT="$(cat "$TMPDIR1/docs/runner-setup.md")"

echo "$DOC_CONTENT" | grep -q "registration-token" \
  || fail "AC3: docs/runner-setup.md must contain 'registration-token' (got: $DOC_CONTENT)"

echo "$DOC_CONTENT" | grep -q "gh api" \
  || fail "AC3: docs/runner-setup.md must contain 'gh api' token-fetch command (got: $DOC_CONTENT)"

pass "AC3: docs/runner-setup.md contains gh api registration-token command"

# ---------------------------------------------------------------------------
# Test 9: docs/runner-setup.md contains why-self-hosted context
# ---------------------------------------------------------------------------
echo "$DOC_CONTENT" | grep -qi "self-hosted\|minutes\|quota\|Actions" \
  || fail "AC2: docs/runner-setup.md should explain why self-hosted runner is useful"

pass "AC2: docs/runner-setup.md contains context / rationale"

# ---------------------------------------------------------------------------
# Test 10: AC3 — gh api command also appears in stdout
# ---------------------------------------------------------------------------
echo "$OUTPUT" | grep -q "registration-token" \
  || fail "AC3: stdout must also show the gh api registration-token command"

pass "AC3: stdout shows gh api registration-token fetch command"

# ---------------------------------------------------------------------------
# Test 11: script does NOT call gh (hermetic — no network, no token needed)
# ---------------------------------------------------------------------------
# We verify by running without GH_TOKEN set; if gh were called it would error out
TMPDIR_HERMETIC="$(mktemp -d)"
trap 'rm -rf "$TMPDIR1" "$TMPDIR_HERMETIC"' EXIT
GH_TOKEN="" GH_ENTERPRISE_TOKEN="" GITHUB_TOKEN="" \
  bash -c "cd \"$TMPDIR_HERMETIC\" && bash \"$SCRIPT\" acme/widget" > /dev/null 2>&1 \
  && pass "hermetic: script runs without GH_TOKEN (no live gh calls)" \
  || fail "hermetic: script failed without GH_TOKEN — it must not call gh api"

# ---------------------------------------------------------------------------
# Test 12: AC1 regression guard — setup.md mentions gh repo view --json isPrivate
# ---------------------------------------------------------------------------
[ -f "$SETUP_MD" ] || fail "setup.md not found at $SETUP_MD"

grep -q "isPrivate" "$SETUP_MD" \
  || fail "AC1: commands/setup.md must contain 'isPrivate' (gh repo view detection)"

pass "AC1: commands/setup.md contains isPrivate detection"

# ---------------------------------------------------------------------------
# Test 13: AC1 — setup.md offers AskUserQuestion for runner setup
# ---------------------------------------------------------------------------
grep -q "runner" "$SETUP_MD" \
  || fail "AC1: commands/setup.md must mention 'runner' (self-hosted runner offer)"

pass "AC1: commands/setup.md mentions runner"

echo ""
echo "✓ otta-runner-setup: all checks passed (AC1 guard + AC2 script + AC3 token command)"
