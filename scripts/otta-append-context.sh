#!/usr/bin/env bash
# otta-append-context.sh <file> <style>
#
# Appends (or replaces in place) the Otta gate notice block in <file>.
# <style>: html  → <!-- otta:begin --> / <!-- otta:end --> delimiters
#          hash  → # otta:begin / # otta:end delimiters (Markdown/cursor rules)
#
# Behaviour:
#   - File absent   → created with the block (no pre-existing content)
#   - File present, block absent   → block appended after existing content
#   - File present, block present  → block replaced in place (idempotent)
#
# Original content outside the delimiters is NEVER clobbered.
set -euo pipefail

FILE="${1:-}"
STYLE="${2:-html}"

if [ -z "$FILE" ]; then
  echo "usage: otta-append-context.sh <file> <style: html|hash>" >&2
  exit 2
fi

# Ensure parent directory exists
mkdir -p "$(dirname "$FILE")"

if [ "$STYLE" = "hash" ]; then
  BEGIN="# otta:begin"
  END="# otta:end"
  BLOCK="# otta:begin — do not edit this block manually
# Otta Gate Active

This repo runs the Otta gate hook before push. Run \`otta gate\` or push — the hook fires automatically.
Pulse wired: telemetry flows to pulse.otta.build.
# otta:end"
else
  BEGIN="<!-- otta:begin"
  END="<!-- otta:end"
  BLOCK="<!-- otta:begin — do not edit this block manually -->
# Otta Gate Active

This repo runs the Otta gate hook before push. Run \`otta gate\` or push — the hook fires automatically.
Pulse wired: telemetry flows to pulse.otta.build.
<!-- otta:end -->"
fi

TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

if [ -f "$FILE" ]; then
  # Strip any existing block (awk: skip lines between BEGIN and END inclusive)
  awk -v begin="$BEGIN" -v end="$END" '
    $0 ~ begin { skip=1 }
    !skip { print }
    $0 ~ end { skip=0 }
  ' "$FILE" > "$TMPFILE"
else
  touch "$TMPFILE"
fi

# Normalize: strip trailing blank lines left by the awk pass so the file is
# byte-stable between runs.  python3 is already required by the telemetry
# script so this adds no new dependency.
python3 - "$TMPFILE" <<'PY'
import sys
path = sys.argv[1]
content = open(path).read().rstrip('\n')
with open(path, 'w') as f:
    if content:
        f.write(content + '\n')
PY

# Append a blank line separator (only if file has content) then the fresh block
if [ -s "$TMPFILE" ]; then
  printf '\n' >> "$TMPFILE"
fi
printf '%s\n' "$BLOCK" >> "$TMPFILE"

mv "$TMPFILE" "$FILE"
