#!/usr/bin/env bash
# otta-remember.sh <category> <text>
#
# Appends a signal-gated learning to ./LEARNINGS.md (repo-root relative to cwd).
# Creates the file with a header if it does not exist.
# Category must be one of: decision, gotcha, failed-approach.
# Idempotent: re-running with the same category+text does not append a second entry.
set -euo pipefail

CATEGORY="${1:-}"
TEXT="${2:-}"

if [ -z "$CATEGORY" ] || [ -z "$TEXT" ]; then
  echo "usage: otta-remember.sh <category> <text>" >&2
  echo "  category: decision | gotcha | failed-approach" >&2
  exit 2
fi

case "$CATEGORY" in
  decision|gotcha|failed-approach) ;;
  *)
    echo "error: invalid category '${CATEGORY}'" >&2
    echo "  allowed: decision | gotcha | failed-approach" >&2
    exit 1
    ;;
esac

LEARNINGS="./LEARNINGS.md"

if [ ! -f "$LEARNINGS" ]; then
  printf '# Learnings\n\n' > "$LEARNINGS"
fi

ENTRY_KEY="[${CATEGORY}] ${TEXT}"

if grep -qF "$ENTRY_KEY" "$LEARNINGS"; then
  echo "Already recorded: ${ENTRY_KEY}"
  exit 0
fi

DATE="$(date +%Y-%m-%d)"
printf -- '- %s %s\n' "$DATE" "$ENTRY_KEY" >> "$LEARNINGS"

echo "Recorded: ${ENTRY_KEY}"
