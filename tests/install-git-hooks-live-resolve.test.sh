#!/usr/bin/env bash
# Regression test for install-git-hooks.sh's version-drift bug.
# Bug: the hook baked in $HERE (the install-time plugin version dir), so it
# ran the SAME cached otta-gate.sh forever — every later plugin update
# (including gate fixes) was invisible to already-installed hooks. Verified
# live: a repo's hook installed under plugin v0.9.0 was still exec'ing the
# v0.9.0 gate after the plugin had moved on to v0.20.0.
# Run: bash plugins/otta/tests/install-git-hooks-live-resolve.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/../scripts/install-git-hooks.sh"

fail() { echo "✗ $1" >&2; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Fake a versioned plugin cache: .../otta/0.9.0/scripts/otta-gate.sh (old,
# "wrong" gate) and .../otta/0.20.0/scripts/otta-gate.sh (new, "right" gate).
PLUGIN_ROOT="$TMPDIR/cache/otta"
for v in 0.9.0 0.20.0; do
  mkdir -p "$PLUGIN_ROOT/$v/scripts"
  cat > "$PLUGIN_ROOT/$v/scripts/otta-gate.sh" <<EOF
#!/usr/bin/env bash
echo "gate-version:$v"
EOF
  chmod +x "$PLUGIN_ROOT/$v/scripts/otta-gate.sh"
done

# Install the hook as if running from the OLD version (0.9.0) — simulates a
# hook installed before any upgrade happened.
REPO="$TMPDIR/repo"
mkdir -p "$REPO" && (cd "$REPO" && git init -q)
cp "$INSTALLER" "$PLUGIN_ROOT/0.9.0/scripts/install-git-hooks.sh"
(cd "$REPO" && bash "$PLUGIN_ROOT/0.9.0/scripts/install-git-hooks.sh") >/dev/null

HOOK="$REPO/.git/hooks/pre-push"
[ -f "$HOOK" ] || fail "pre-push hook was not installed at $HOOK"

# The hook must resolve to the NEWEST version (0.20.0), not the install-time
# version (0.9.0), even though it was installed while 0.9.0 was current.
OUT="$(cd "$REPO" && bash "$HOOK" 2>&1)"
[ "$OUT" = "gate-version:0.20.0" ] \
  || fail "hook ran '$OUT', expected 'gate-version:0.20.0' — it's frozen at install-time version, not resolving latest"

# Simulate a further upgrade to 0.20.1 — the SAME already-installed hook
# (no reinstall) must pick it up automatically.
mkdir -p "$PLUGIN_ROOT/0.20.1/scripts"
cat > "$PLUGIN_ROOT/0.20.1/scripts/otta-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "gate-version:0.20.1"
EOF
chmod +x "$PLUGIN_ROOT/0.20.1/scripts/otta-gate.sh"

OUT2="$(cd "$REPO" && bash "$HOOK" 2>&1)"
[ "$OUT2" = "gate-version:0.20.1" ] \
  || fail "hook ran '$OUT2', expected 'gate-version:0.20.1' after a later upgrade with no reinstall"

# Marketplace-style layout: siblings are plugin NAMES, not semver dirs (e.g.
# .../marketplaces/{otta,superpowers-marketplace,...}). A naive `sort -V |
# tail -1` over ALL siblings could alphabetically pick a non-otta sibling's
# scripts/otta-gate.sh (or silently pass validation by luck of the fallback).
# The version filter must skip non-semver dirs entirely.
MKT_ROOT="$TMPDIR/marketplaces"
mkdir -p "$MKT_ROOT/otta/scripts" "$MKT_ROOT/zzz-other-plugin/scripts"
cat > "$MKT_ROOT/otta/scripts/otta-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "gate-version:marketplace-otta"
EOF
chmod +x "$MKT_ROOT/otta/scripts/otta-gate.sh"
cat > "$MKT_ROOT/zzz-other-plugin/scripts/otta-gate.sh" <<'EOF'
#!/usr/bin/env bash
echo "gate-version:WRONG-unrelated-plugin"
EOF
chmod +x "$MKT_ROOT/zzz-other-plugin/scripts/otta-gate.sh"

MKT_REPO="$TMPDIR/mkt-repo"
mkdir -p "$MKT_REPO" && (cd "$MKT_REPO" && git init -q)
cp "$INSTALLER" "$MKT_ROOT/otta/scripts/install-git-hooks.sh"
(cd "$MKT_REPO" && bash "$MKT_ROOT/otta/scripts/install-git-hooks.sh") >/dev/null

MKT_HOOK="$MKT_REPO/.git/hooks/pre-push"
[ -f "$MKT_HOOK" ] || fail "pre-push hook was not installed at $MKT_HOOK (marketplace layout)"
MKT_OUT="$(cd "$MKT_REPO" && bash "$MKT_HOOK" 2>&1)"
[ "$MKT_OUT" = "gate-version:marketplace-otta" ] \
  || fail "marketplace-layout hook ran '$MKT_OUT', expected 'gate-version:marketplace-otta' — it must not alphabetically pick an unrelated sibling plugin dir"

echo "✓ install-git-hooks-live-resolve: hook tracks the newest plugin version automatically"
