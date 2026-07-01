#!/usr/bin/env bash
# otta-status.sh — render the Otta pipeline checklist for one issue/PR.
#
# Pure renderer: reads a small stage-status JSON (built by /otta:status from
# `gh api` / `gh pr checks` / Pulse `gate_verdict` data) and prints the
# Idea → Build → Gate → CI → Release/Deploy checklist with a marker per stage.
# Does no network I/O itself, so it stays unit-testable without stubbing gh/curl.
#
# Usage:
#   echo "$JSON" | otta-status.sh
#   otta-status.sh <<< "$JSON"
#
# Input JSON shape (single-issue mode):
#   {
#     "issue": "82",
#     "stages": {
#       "idea":    {"status": "pass|fail|pending", "detail": "..."},
#       "build":   {"status": "pass|fail|pending", "detail": "..."},
#       "gate":    {"status": "pass|fail|pending", "detail": "..."},
#       "ci":      {"status": "pass|fail|pending", "detail": "..."},
#       "release": {"status": "pass|fail|pending", "detail": "..."}
#     }
#   }
#
# Dashboard mode: pass an "issues" array instead of "issue"/"stages" to render
# one compact row per issue (issue #, title, one glyph per stage) instead of
# the full 5-line checklist:
#   {
#     "issues": [
#       {"issue": "82", "title": "...", "stages": { ...same shape as above... }},
#       ...
#     ]
#   }
set -euo pipefail

command -v jq >/dev/null || { echo "ERROR: jq not found. Install jq." >&2; exit 1; }

INPUT="$(cat)"
echo "$INPUT" | jq -e . >/dev/null 2>&1 || { echo "ERROR: invalid JSON input" >&2; exit 2; }

marker() {
  case "$1" in
    pass) echo "✓" ;;
    fail) echo "✗" ;;
    *)    echo "○" ;;
  esac
}

render_dashboard() {
  local input="$1"
  echo "Otta Status — dashboard"
  echo "----------------------------------------"
  local count
  count="$(echo "$input" | jq '.issues | length')"
  if [ "$count" -eq 0 ]; then
    echo "No open issues found."
    return 0
  fi
  echo "$input" | jq -c '.issues[]' | while IFS= read -r item; do
    local issue title glyphs=""
    issue="$(echo "$item" | jq -r '.issue // "?"')"
    title="$(echo "$item" | jq -r '.title // ""')"
    for key in idea build gate ci release; do
      local status
      status="$(echo "$item" | jq -r --arg k "$key" '.stages[$k].status // "pending"')"
      glyphs="${glyphs}$(marker "$status")"
    done
    printf '#%-6s %s  %s\n' "$issue" "$glyphs" "$title"
  done
  echo "----------------------------------------"
}

if echo "$INPUT" | jq -e 'has("issues")' >/dev/null 2>&1; then
  render_dashboard "$INPUT"
  exit 0
fi

ISSUE="$(echo "$INPUT" | jq -r '.issue // "?"')"

echo "Otta Status — issue #$ISSUE"
echo "----------------------------------------"

SUMMARY=""
for key in idea build gate ci release; do
  case "$key" in
    idea)    label="Idea" ;;
    build)   label="Build" ;;
    gate)    label="Gate" ;;
    ci)      label="CI" ;;
    release) label="Release/Deploy" ;;
  esac

  STATUS="$(echo "$INPUT" | jq -r --arg k "$key" '.stages[$k].status // "pending"')"
  DETAIL="$(echo "$INPUT" | jq -r --arg k "$key" '.stages[$k].detail // ""')"
  M="$(marker "$STATUS")"

  printf '%s %-16s %s\n' "$M" "$label" "$DETAIL"
  SUMMARY="${SUMMARY}${label} ${M} → "
done

echo "----------------------------------------"
echo "${SUMMARY% → }"
