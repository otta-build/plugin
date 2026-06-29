#!/usr/bin/env bash
# otta-release-setup.sh [--dry-run]
# Installs .github/workflows/otta-release.yml — auto-tags on version bump to main.
# Idempotent: skips if file already exists. --dry-run prints without writing.
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

WORKFLOW_DIR=".github/workflows"
WORKFLOW_FILE="${WORKFLOW_DIR}/otta-release.yml"

CONTENT='name: otta-release
on:
  push:
    branches: [main]
jobs:
  tag:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - name: tag if version bumped
        run: |
          VERSION=$(node -p "require('"'"'./package.json'"'"').version" 2>/dev/null || echo "")
          [ -z "$VERSION" ] && exit 0
          git tag "v${VERSION}" 2>/dev/null && git push origin "v${VERSION}" || true
'

if [ "$DRY_RUN" = "1" ]; then
  echo "Would write: ${WORKFLOW_FILE}"
  echo "---"
  printf '%s' "$CONTENT"
  exit 0
fi

if [ -f "$WORKFLOW_FILE" ]; then
  echo "✓ ${WORKFLOW_FILE} already exists — skipped (idempotent)."
  exit 0
fi

mkdir -p "$WORKFLOW_DIR"
printf '%s' "$CONTENT" > "$WORKFLOW_FILE"
echo "✓ Installed ${WORKFLOW_FILE} — tags vX.Y.Z on push to main when package.json version changes."
