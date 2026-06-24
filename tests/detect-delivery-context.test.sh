#!/usr/bin/env bash
# detect-delivery-context.test.sh — regression tests for detect-delivery-context.sh (#65).
# Asserts output conforms to the #64 DeliveryContext schema:
#   deploy.mode ∈ {auto-on-merge, tag, manual, none}
#   ci.required  boolean (false | true)
#   staging      null | "<branch-name>"
# Run: bash tests/detect-delivery-context.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/detect-delivery-context.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Build fixture: git repo with a default branch, CI workflows, staging branch
# ---------------------------------------------------------------------------
REPO="$TMP/repo"
git init -q -b main "$REPO"
cd "$REPO"
git config user.email t@t.t
git config user.name t

# CI workflow with paths filter (no deploy signal)
mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<'EOF'
name: CI
on:
  pull_request:
    paths:
      - 'src/**'
      - '.github/workflows/ci.yml'
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo test
EOF

# Release workflow with tauri-action → deploy.mode should be "tag"
cat > .github/workflows/release.yml <<'EOF'
name: Release
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: tauri-apps/tauri-action@v0
        with:
          tagName: ${{ github.ref_name }}
EOF

echo readme > README.md
git add .
git commit -qm "initial"

# Create a staging branch
git switch -qc staging
git switch -q main

# ---------------------------------------------------------------------------
# 1. Script runs and produces output (exit 0)
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT")" || fail "script exited non-zero"
[ -n "$OUT" ] || fail "script produced no output"

# ---------------------------------------------------------------------------
# 2. base field is detected as main
# ---------------------------------------------------------------------------
echo "$OUT" | grep -q '^base: "main"' || fail "base not detected as main — got: $(echo "$OUT" | grep '^base:')"

# ---------------------------------------------------------------------------
# 3. staging field is "staging" (branch exists locally) — schema: quoted string
# ---------------------------------------------------------------------------
echo "$OUT" | grep -q '^staging: "staging"' || fail "staging branch not detected as quoted string"

# ---------------------------------------------------------------------------
# 4. CI workflows appear as informational comment, NOT as schema fields
# ---------------------------------------------------------------------------
echo "$OUT" | grep -q '#.*ci\|#.*release' || fail "detected workflows not surfaced as comments"
# The schema must NOT have a ci.workflows key
if echo "$OUT" | grep -q '^  workflows:'; then
  fail "ci.workflows must not appear in schema YAML (belongs in comment only)"
fi

# ---------------------------------------------------------------------------
# 5. paths filter from ci.yml appears in the informational comment
# ---------------------------------------------------------------------------
echo "$OUT" | grep -q 'src/\*\*' || fail "paths filter src/** not found in informational comment"

# ---------------------------------------------------------------------------
# 6. deploy.mode is in the #64 enum {auto-on-merge, tag, manual, none}
# ---------------------------------------------------------------------------
MODE_LINE="$(echo "$OUT" | grep '^  mode:')"
MODE_VALUE="$(echo "$MODE_LINE" | sed 's/.*mode: "\([^"]*\)".*/\1/')"
VALID_MODES="auto-on-merge tag manual none"
echo "$VALID_MODES" | grep -qw "$MODE_VALUE" || \
  fail "deploy.mode '$MODE_VALUE' not in enum {auto-on-merge, tag, manual, none}"

# ---------------------------------------------------------------------------
# 7. tauri-action in release.yml → deploy.mode must be "tag"
# ---------------------------------------------------------------------------
echo "$OUT" | grep -q 'mode: "tag"' || fail "tauri-action should map to deploy.mode: tag (got mode: $MODE_VALUE)"

# ---------------------------------------------------------------------------
# 8. ci.required is a boolean (false or true), NOT a list
# ---------------------------------------------------------------------------
echo "$OUT" | grep -q '^  required: false\|^  required: true' || \
  fail "ci.required must be a boolean (false/true), got: $(echo "$OUT" | grep 'required:')"

# ---------------------------------------------------------------------------
# 9. --output writes a file with correct content
# ---------------------------------------------------------------------------
OUTFILE="$TMP/out.yml"
bash "$SCRIPT" --output "$OUTFILE" >/dev/null
[ -f "$OUTFILE" ] || fail "--output did not create file"
grep -q '^base: "main"' "$OUTFILE" || fail "--output file missing base field"

# ---------------------------------------------------------------------------
# 10. No staging branch → staging: null (YAML null, not quoted "none")
# ---------------------------------------------------------------------------
REPO2="$TMP/repo2"
git init -q -b main "$REPO2"
cd "$REPO2"
git config user.email t@t.t; git config user.name t
echo x > f; git add f; git commit -qm init
mkdir -p .github/workflows
OUT2="$(bash "$SCRIPT")"
echo "$OUT2" | grep -q '^staging: null' || \
  fail "no staging branch must yield 'staging: null', got: $(echo "$OUT2" | grep '^staging:')"

# ---------------------------------------------------------------------------
# 11. YAML parses and passes schema assertions (requires python3 + PyYAML)
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  cd "$REPO"
  bash "$SCRIPT" | python3 -c "
import yaml, sys
d = yaml.safe_load(sys.stdin)
assert d['base'] == 'main', 'base wrong: ' + repr(d['base'])
assert d['staging'] == 'staging', 'staging wrong: ' + repr(d['staging'])
valid_modes = {'auto-on-merge', 'tag', 'manual', 'none'}
assert d['deploy']['mode'] in valid_modes, 'mode not in enum: ' + repr(d['deploy']['mode'])
assert d['deploy']['mode'] == 'tag', 'tauri-action must give tag, got: ' + repr(d['deploy']['mode'])
assert isinstance(d['ci']['required'], bool), 'ci.required not bool: ' + repr(d['ci']['required'])
assert d['pulse']['installed'] == False, 'pulse.installed wrong'
print('  python3 schema assertions: ok')
" || fail "YAML failed schema assertion in python3"
fi

# ---------------------------------------------------------------------------
# setup.md structural checks (AC2-AC5)
# ---------------------------------------------------------------------------
SETUP="$HERE/../commands/setup.md"
[ -f "$SETUP" ] || fail "setup.md not found at $SETUP"

# AC2: setup.md documents the #64 deploy.mode enum exactly
# (auto-on-merge | tag | manual | none — NOT the old "continuous"/"release" wording)
grep -q "auto-on-merge" "$SETUP" || fail "AC2: setup.md missing enum value 'auto-on-merge'"
grep -q '"tag"' "$SETUP"         || fail "AC2: setup.md missing enum value 'tag'"
grep -q '"manual"' "$SETUP"      || fail "AC2: setup.md missing enum value 'manual'"
grep -q '"none"' "$SETUP"        || fail "AC2: setup.md missing enum value 'none'"
grep -qv "continuous\|\"release\"" "$SETUP" || fail "AC2: setup.md must not use old 'continuous' or 'release' mode names"

# AC3: onboards Pulse App (calls pulse-install.sh)
grep -q "pulse-install.sh" "$SETUP" || fail "AC3: setup.md must reference pulse-install.sh"

# AC4: writes and commits .otta.yml
grep -q "\.otta\.yml" "$SETUP" || fail "AC4: setup.md must mention .otta.yml write"
grep -qi "commit\|git commit" "$SETUP" || fail "AC4: setup.md must mention committing .otta.yml"

# AC5: offers to scaffold CI workflow
grep -qi "scaffold\|test-runner\|ci workflow" "$SETUP" || fail "AC5: setup.md must offer to scaffold CI"

echo "✓ detect-delivery-context: all 11 checks passed"
echo "✓ setup.md structural checks: AC2-AC5 confirmed"
