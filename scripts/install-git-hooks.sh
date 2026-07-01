#!/usr/bin/env bash
# install-git-hooks.sh — install a pre-push hook in the CURRENT repo that runs
# the Otta gate. Idempotent. Works whether or not core.hooksPath is set.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a git repo." >&2; exit 1; }
HOOKS_DIR="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOKS_DIR"
HOOK="$HOOKS_DIR/pre-push"

# Plugins are cached one directory per version (…/otta/otta/X.Y.Z/scripts).
# Baking in $HERE would freeze the hook at today's version forever — every
# later plugin update ships gate fixes this repo would never see. Instead the
# hook resolves the newest sibling version dir at RUN time, falling back to
# the install-time path if the parent isn't a version-dir layout.
INSTALL_TIME_SCRIPT="$HERE/otta-gate.sh"
VERSIONS_DIR="$(cd "$HERE/../.." && pwd)"

cat > "$HOOK" <<EOF
#!/usr/bin/env bash
# Installed by the Otta plugin — local mirror of the Pulse merge gates.
# Bypass once with: OTTA_SKIP_GATE=1 git push
[ -n "\${OTTA_SKIP_GATE:-}" ] && exit 0
VERSIONS_DIR="$VERSIONS_DIR"
LATEST="\$(cd "\$VERSIONS_DIR" 2>/dev/null && ls -d */ 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+/\$' | sort -V | tail -1)"
GATE="\${VERSIONS_DIR}/\${LATEST}scripts/otta-gate.sh"
[ -f "\$GATE" ] || GATE="$INSTALL_TIME_SCRIPT"
exec "\$GATE"
EOF
chmod +x "$HOOK"
echo "✓ installed pre-push gate → $HOOK"
echo "  bypass once with: OTTA_SKIP_GATE=1 git push"
