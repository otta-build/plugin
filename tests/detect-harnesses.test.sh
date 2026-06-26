#!/usr/bin/env bash
# detect-harnesses.test.sh — tests for scripts/detect-harnesses.sh (issue #34).
# Checks: CC detected, Cursor detected, Gemini detected, empty-repo (exit 0 + no output),
#         multiple harnesses, Codex detected via ~/.codex/config.toml.
# Run: bash tests/detect-harnesses.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/detect-harnesses.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }
pass() { echo "✓ $1"; }

[ -f "$SCRIPT" ] || fail "detect-harnesses.sh not found at $SCRIPT"

# PATH stub dir — no codex/gemini/cursor binaries exist here.
# Include /usr/bin:/bin so bash itself is available; AI CLIs live outside these
# standard dirs (typically /usr/local/bin or ~/.local/bin) so they won't be found.
STUB_BIN="$TMP/stub_bin"
mkdir -p "$STUB_BIN"
SAFE_PATH="$STUB_BIN:/usr/bin:/bin"
# Fake HOME with no .codex dir so ~/.codex/config.toml fallback doesn't trigger
FAKE_HOME="$TMP/fakehome"
mkdir -p "$FAKE_HOME"

# ---------------------------------------------------------------------------
# 1. Claude Code detected: .claude/ dir present
# ---------------------------------------------------------------------------
RDIR="$TMP/repo1"
mkdir -p "$RDIR/.claude"
OUT="$(HOME="$FAKE_HOME" PATH="$SAFE_PATH" bash "$SCRIPT" "$RDIR")"
echo "$OUT" | grep -q "claude_code" || fail "CC: 'claude_code' not in output ('$OUT')"
pass "1: claude_code detected when .claude/ present"

# ---------------------------------------------------------------------------
# 2. Cursor detected: .cursor/ dir present
# ---------------------------------------------------------------------------
RDIR="$TMP/repo2"
mkdir -p "$RDIR/.cursor"
OUT="$(HOME="$FAKE_HOME" PATH="$SAFE_PATH" bash "$SCRIPT" "$RDIR")"
echo "$OUT" | grep -q "cursor" || fail "Cursor: 'cursor' not in output ('$OUT')"
pass "2: cursor detected when .cursor/ present"

# ---------------------------------------------------------------------------
# 3. Gemini detected: .gemini/settings.json present
# ---------------------------------------------------------------------------
RDIR="$TMP/repo3"
mkdir -p "$RDIR/.gemini"
touch "$RDIR/.gemini/settings.json"
OUT="$(HOME="$FAKE_HOME" PATH="$SAFE_PATH" bash "$SCRIPT" "$RDIR")"
echo "$OUT" | grep -q "gemini" || fail "Gemini: 'gemini' not in output ('$OUT')"
pass "3: gemini detected when .gemini/settings.json present"

# ---------------------------------------------------------------------------
# 4. Empty repo: no harnesses detected, exit code 0, output is empty
# ---------------------------------------------------------------------------
RDIR="$TMP/repo4"
mkdir -p "$RDIR"
OUT="$(HOME="$FAKE_HOME" PATH="$SAFE_PATH" bash "$SCRIPT" "$RDIR")" \
  || fail "Empty repo: script exited non-zero"
[ -z "$OUT" ] || fail "Empty repo: expected empty output, got '$OUT'"
pass "4: empty repo returns no output and exit 0"

# ---------------------------------------------------------------------------
# 5. Multiple harnesses: CC + Cursor both in output
# ---------------------------------------------------------------------------
RDIR="$TMP/repo5"
mkdir -p "$RDIR/.claude" "$RDIR/.cursor"
OUT="$(HOME="$FAKE_HOME" PATH="$SAFE_PATH" bash "$SCRIPT" "$RDIR")"
echo "$OUT" | grep -q "claude_code" || fail "Multi: 'claude_code' not in output ('$OUT')"
echo "$OUT" | grep -q "cursor"      || fail "Multi: 'cursor' not in output ('$OUT')"
pass "5: multiple harnesses (CC + Cursor) both detected"

# ---------------------------------------------------------------------------
# 6. Codex detected via ~/.codex/config.toml (global install marker)
# ---------------------------------------------------------------------------
RDIR="$TMP/repo6"
mkdir -p "$RDIR"
CODEX_HOME="$TMP/codexhome"
mkdir -p "$CODEX_HOME/.codex"
touch "$CODEX_HOME/.codex/config.toml"
OUT="$(HOME="$CODEX_HOME" PATH="$SAFE_PATH" bash "$SCRIPT" "$RDIR")"
echo "$OUT" | grep -q "codex" || fail "Codex: 'codex' not in output ('$OUT')"
pass "6: codex detected when ~/.codex/config.toml present"

# ---------------------------------------------------------------------------
# 7. Output is strictly newline-separated IDs, no extra paths
# ---------------------------------------------------------------------------
RDIR="$TMP/repo7"
mkdir -p "$RDIR/.claude"
OUT="$(HOME="$FAKE_HOME" PATH="$SAFE_PATH" bash "$SCRIPT" "$RDIR")"
# Output should be exactly "claude_code" — no path lines
[ "$OUT" = "claude_code" ] || fail "Clean output: expected exactly 'claude_code', got '$OUT'"
pass "7: output contains only harness IDs (no path output)"

# ---------------------------------------------------------------------------
# 8. No false-positive for gemini when only CLI is in PATH (no repo config)
#    Before fix: command -v gemini succeeds → false positive
#    After fix:  only .gemini/settings.json triggers detection
# ---------------------------------------------------------------------------
RDIR="$TMP/repo8"
mkdir -p "$RDIR"
# Put a fake gemini binary in the stub bin dir
echo '#!/bin/sh' > "$STUB_BIN/gemini"
chmod +x "$STUB_BIN/gemini"
PATH_WITH_GEMINI="$STUB_BIN:/usr/bin:/bin"
OUT="$(HOME="$FAKE_HOME" PATH="$PATH_WITH_GEMINI" bash "$SCRIPT" "$RDIR")"
if echo "$OUT" | grep -q "gemini"; then
  fail "False-positive gemini: detected 'gemini' in repo with no .gemini/settings.json (CLI only)"
fi
pass "8: no false-positive for gemini when only CLI is in PATH"

# ---------------------------------------------------------------------------
# 9. No false-positive for cursor when only CLI is in PATH (no .cursor/ dir)
#    Before fix: command -v cursor succeeds → false positive
#    After fix:  only .cursor/ dir triggers detection
# ---------------------------------------------------------------------------
RDIR="$TMP/repo9"
mkdir -p "$RDIR"
# Put a fake cursor binary in the stub bin dir
echo '#!/bin/sh' > "$STUB_BIN/cursor"
chmod +x "$STUB_BIN/cursor"
PATH_WITH_CURSOR="$STUB_BIN:/usr/bin:/bin"
OUT="$(HOME="$FAKE_HOME" PATH="$PATH_WITH_CURSOR" bash "$SCRIPT" "$RDIR")"
if echo "$OUT" | grep -q "cursor"; then
  fail "False-positive cursor: detected 'cursor' in repo with no .cursor/ dir (CLI only)"
fi
pass "9: no false-positive for cursor when only CLI is in PATH"

echo ""
echo "detect-harnesses: all checks passed"
