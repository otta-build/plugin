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
# Input JSON shape:
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
set -euo pipefail

command -v jq >/dev/null || { echo "ERROR: jq not found. Install jq." >&2; exit 1; }

INPUT="$(cat)"
echo "$INPUT" | jq -e . >/dev/null 2>&1 || { echo "ERROR: invalid JSON input" >&2; exit 2; }

ISSUE="$(echo "$INPUT" | jq -r '.issue // "?"')"

marker() {
  case "$1" in
    pass) echo "✓" ;;
    fail) echo "✗" ;;
    *)    echo "○" ;;
  esac
}

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
