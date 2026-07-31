#!/usr/bin/env bash
# otta-release-setup.sh [--dry-run] [--runner <value>]
# Installs .github/workflows/otta-release.yml — auto-tags on version bump to main.
# Idempotent: skips if file already exists. --dry-run prints without writing.
#
# The runner is INFERRED from the repo's existing workflows rather than assumed.
# Hardcoding `ubuntu-latest` silently broke any repo that cannot schedule on
# GitHub-hosted runners: the job never picks up a runner, the repo is never
# tagged, and nothing reports an error — setup still printed "✓ Installed" and
# the repo looked correctly configured. Downstream, deploy_tag never fires and
# DORA deployment frequency reads zero instead of "not instrumented"
# (otta-build/pulse#153). Use --runner to override.
set -euo pipefail

DRY_RUN=0
RUNNER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --runner)
      [ "$#" -ge 2 ] || { echo "ERROR: --runner needs a value" >&2; exit 2; }
      RUNNER="$2"; shift 2 ;;
    *) echo "usage: otta-release-setup.sh [--dry-run] [--runner <value>]" >&2; exit 2 ;;
  esac
done

WORKFLOW_DIR=".github/workflows"
WORKFLOW_FILE="${WORKFLOW_DIR}/otta-release.yml"

# Most common `runs-on:` value across the repo's other workflows. The repo
# already encodes the right answer; this just reads it.
detect_runner() {
  local vals
  [ -d "$WORKFLOW_DIR" ] || return 1
  vals="$(
    grep -hE '^[[:space:]]*runs-on:[[:space:]]*\S' \
      "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml 2>/dev/null \
      | sed -E 's/^[[:space:]]*runs-on:[[:space:]]*//; s/[[:space:]]+$//' \
      | grep -vF '${{' \
      || true
  )"
  # `${{ ... }}` values are skipped above: a matrix reference cannot resolve in
  # the generated workflow, which has no matrix, so inheriting it would produce
  # a file broken in a new way rather than a useful default.
  [ -n "$vals" ] || return 1
  printf '%s\n' "$vals" | sort | uniq -c | sort -rn | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//'
}

RUNNER_SOURCE="--runner flag"
if [ -z "$RUNNER" ]; then
  if RUNNER="$(detect_runner)" && [ -n "$RUNNER" ]; then
    RUNNER_SOURCE="inferred from existing workflows in $WORKFLOW_DIR"
  else
    RUNNER="ubuntu-latest"
    RUNNER_SOURCE="default — nothing could be inferred from $WORKFLOW_DIR"
  fi
fi

CONTENT="name: otta-release
on:
  push:
    branches: [main]
jobs:
  tag:
    runs-on: ${RUNNER}
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - name: tag if version bumped
        run: |
          VERSION=\$(node -p \"require('./package.json').version\" 2>/dev/null || echo \"\")
          [ -z \"\$VERSION\" ] && exit 0
          git tag \"v\${VERSION}\" 2>/dev/null && git push origin \"v\${VERSION}\" || true
"

if [ "$DRY_RUN" = "1" ]; then
  echo "Would write: ${WORKFLOW_FILE}"
  echo "  runner: ${RUNNER}  (${RUNNER_SOURCE})"
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
echo "  runner: ${RUNNER}  (${RUNNER_SOURCE})"
