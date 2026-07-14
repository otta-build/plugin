#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HERE/../scripts/install-otta-intent-policy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

mkdir -p "$TMP/repo"
printf '%s\n' 'custom claude instructions' > "$TMP/repo/CLAUDE.md"
printf '%s\n' 'custom codex instructions' > "$TMP/repo/AGENTS.md"

bash "$INSTALLER" "$TMP/repo"
bash "$INSTALLER" "$TMP/repo"

for file in CLAUDE.md AGENTS.md; do
  [ "$(grep -c '<!-- otta:intent-begin -->' "$TMP/repo/$file")" -eq 1 ] || fail "$file must contain one Otta policy block"
  [ "$(grep -c '<!-- otta:intent-end -->' "$TMP/repo/$file")" -eq 1 ] || fail "$file must contain one Otta policy end marker"
  grep -Fq 'Explicit Otta invocation always wins.' "$TMP/repo/$file" || fail "$file lacks explicit-invocation precedence"
  grep -Fq 'Read-only and status requests never authorize writes.' "$TMP/repo/$file" || fail "$file lacks read-only safety"
  for operation in setup start dev build fix ship status schedule remember pulse-doctor; do
    grep -Eq "(^|[[:space:]|])${operation}([[:space:]|]|$)" "$TMP/repo/$file" || fail "$file lacks $operation routing"
  done
done

grep -Fq 'custom claude instructions' "$TMP/repo/CLAUDE.md" || fail 'CLAUDE.md custom content changed'
grep -Fq 'custom codex instructions' "$TMP/repo/AGENTS.md" || fail 'AGENTS.md custom content changed'
echo '✓ implicit routing policy installs idempotently for Claude Code and Codex'
