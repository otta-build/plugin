#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: otta-repair-loop.sh classify <AC> | route <--read-only|--state-changing> | decide ... | emit --attempt N --failure TEXT --outcome NAME [--stage NAME]" >&2; exit 64; }

normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ';|' '\n' |
    sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]]+/ /g' |
    sed '/^$/d' | sort -u | paste -sd, - | sed 's/,/, /g'
}

emit() {
  record="$(jq -cn --argjson attempt "$attempt" --arg stage "$stage" \
    --arg failure_signature "$signature" --arg outcome "$outcome" \
    '{attempt:$attempt,stage:$stage,failure_signature:$failure_signature,outcome:$outcome}')"
  [ -z "${LEDGER:-}" ] || printf '%s\n' "$record" >> "$LEDGER" 2>/dev/null || true

  # Always persist locally; the existing transport also streams to Pulse when wired.
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$here/ledger-append.sh" --source repair-loop --event repair_attempt \
    --score 0 --feedback "$outcome: $signature" --output "$record" >/dev/null
}

case "${1:-}" in
  classify)
    [ "$#" -eq 2 ] || usage
    ac="$2"
    labels="$(printf '%s' "$ac" | grep -oE '\[(test|review|human)\]' | tr -d '[]' || true)"
    count="$(printf '%s\n' "$labels" | sed '/^$/d' | wc -l | tr -d ' ')"
    [ "$count" -le 1 ] || { echo "multiple verification labels are ambiguous" >&2; exit 1; }
    # Quoted: `test` is also a command name, so a bare assignment reads as a
    # missing command substitution to shellcheck (SC2209). This is the literal
    # default verification label.
    [ -n "$labels" ] || labels="test"
    printf '%s\n' "$labels"
    ;;
  route)
    case "${2:-}" in --read-only) echo direct;; --state-changing) echo otta;; *) usage;; esac
    ;;
  emit)
    shift; attempt=""; failure=""; stage=reviewer; outcome=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --attempt) attempt="${2:-}"; shift 2;; --failure) failure="${2:-}"; shift 2;;
        --stage) stage="${2:-}"; shift 2;; --outcome) outcome="${2:-}"; shift 2;; *) usage;; esac
    done
    [[ "$attempt" =~ ^[1-9][0-9]*$ ]] && [ -n "$failure" ] && [ -n "$outcome" ] || usage
    signature="$(normalize "$failure")"; emit
    echo "Recorded $outcome evidence for attempt $attempt: $signature."
    ;;
  decide)
    shift; attempt=""; failure=""; state=""; stage=reviewer; max="${OTTA_MAX_REVISIONS:-3}"
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --attempt) attempt="${2:-}"; shift 2;; --failure) failure="${2:-}"; shift 2;;
        --state) state="${2:-}"; shift 2;; --stage) stage="${2:-}"; shift 2;;
        --max-revisions) max="${2:-}"; shift 2;; *) usage;; esac
    done
    [[ "$attempt" =~ ^[1-9][0-9]*$ && "$max" =~ ^[1-9][0-9]*$ ]] || usage
    [ -n "$failure" ] && [ -n "$state" ] || usage
    signature="$(normalize "$failure")"
    previous=""; repeats=1
    if [ -f "$state" ]; then IFS=$'\t' read -r previous repeats < "$state" || true; fi
    if [ "$signature" = "$previous" ]; then repeats=$((repeats + 1)); else repeats=1; fi
    mkdir -p "$(dirname "$state")"; printf '%s\t%s\n' "$signature" "$repeats" > "$state"
    if [ "$repeats" -ge 2 ]; then
      outcome=stalled; emit
      echo "Escalated on attempt $attempt: the same blockers repeated twice without meaningful progress: $signature."
      exit 2
    fi
    if [ "$attempt" -ge "$max" ]; then
      outcome=stalled; emit
      echo "Stopped after $attempt of $max repair attempts. Remaining blockers: $signature."
      exit 2
    fi
    outcome=retry; emit
    echo "Retry repair attempt $attempt of $max. Current blockers: $signature."
    ;;
  *) usage;;
esac
