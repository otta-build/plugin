#!/usr/bin/env bash
# sync-to-public.sh <path-to-otta-plugin-clone>
#
# Pushes the plugin from this monorepo (the canonical source) to the public
# distribution repo (otta-build/plugin), so installs are fast + public
# without cloning the whole monorepo.
#
# Syncs the plugin COMPONENTS + manifest, and bumps the public marketplace
# version/description to match. Leaves public-only files alone (LICENSE,
# CHANGELOG, CONTRIBUTING, SECURITY, README, .github/). After running, review +
# commit + push in the public clone.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # plugins/otta
PUB="${1:?usage: sync-to-public.sh <path-to-otta-plugin-clone>}"
[ -f "$PUB/.claude-plugin/marketplace.json" ] || { echo "not an otta-plugin clone: $PUB" >&2; exit 1; }

for d in agents commands hooks scripts skills workflows tests; do
  rm -rf "$PUB/${d:?}"
  [ -d "$SRC/$d" ] && cp -R "$SRC/$d" "$PUB/$d"
done
cp "$SRC/.claude-plugin/plugin.json" "$PUB/.claude-plugin/plugin.json"

VER="$(jq -r .version "$SRC/.claude-plugin/plugin.json")"
DESC="$(jq -r .description "$SRC/.claude-plugin/plugin.json")"
jq --arg v "$VER" --arg d "$DESC" \
  '.plugins[0].version=$v | .plugins[0].description=$d' \
  "$PUB/.claude-plugin/marketplace.json" > "$PUB/.claude-plugin/marketplace.json.tmp"
mv "$PUB/.claude-plugin/marketplace.json.tmp" "$PUB/.claude-plugin/marketplace.json"

echo "✓ synced plugin v$VER → $PUB"
echo "  next: update CHANGELOG/README in the public clone if needed, then commit + push"
