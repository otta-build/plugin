#!/usr/bin/env bash
# pulse-install.sh [--pulse-url URL] [--open] [--instructions-only|--verify]
# the repo's Pulse credentials into .otta/pulse.env.
#
# Install is interactive browser consent (GitHub never lets a tool install an
# App silently). This prints the install URL and, with --open, launches it.
# Verification uses Pulse's customer-safe installation-status endpoint. GitHub
# App credentials remain server-side and are never requested from customers.
set -euo pipefail

OPEN=0
INSTRUCTIONS_ONLY=0
VERIFY_ONLY=0
PULSE_URL_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pulse-url)
      [ "$#" -ge 2 ] && [ -n "$2" ] || {
        echo "ERROR: --pulse-url requires a URL." >&2
        exit 2
      }
      PULSE_URL_OVERRIDE="$2"
      shift 2
      ;;
    --open) OPEN=1; shift ;;
    --instructions-only) INSTRUCTIONS_ONLY=1; shift ;;
    --verify) VERIFY_ONLY=1; shift ;;
    *) echo "usage: pulse-install.sh [--pulse-url URL] [--open] [--instructions-only|--verify]" >&2; exit 2 ;;
  esac
done
if [ "$INSTRUCTIONS_ONLY" -eq 1 ] && [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "ERROR: --instructions-only and --verify are mutually exclusive." >&2
  exit 2
fi

APP_SLUG="otta-pulse"
INSTALL_URL="https://github.com/apps/${APP_SLUG}/installations/new"
PULSE_URL="${PULSE_URL_OVERRIDE:-${OTTA_PULSE_URL:-https://pulse.otta.build}}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '<your repo>')"

if [ "$VERIFY_ONLY" -eq 0 ]; then
cat <<EOF
Otta Pulse — DORA metrics + merge gates for your repos.

1. Open:   ${INSTALL_URL}
2. Pick your account/org (the owner of ${REPO}).
3. Choose "All repositories" (auto-covers future repos) or select specific ones.
4. Install. Backfill of ~180 days runs automatically within minutes.

After install, Pulse ingests your PR/CI/tag webhooks with zero further config.
EOF
fi

if [ "$OPEN" -eq 1 ]; then
  if command -v open >/dev/null; then open "$INSTALL_URL"
  elif command -v xdg-open >/dev/null; then xdg-open "$INSTALL_URL"
  else echo "(could not auto-open — visit the URL above)"; fi
fi

[ "$INSTRUCTIONS_ONLY" -eq 1 ] && exit 0

# Auto-wire Pulse credentials: POST /connect to get a per-repo scoped token and
# write .otta/pulse.env so ledger-append.sh can stream gate verdicts without any
# manual shell-profile edits.
if ! command -v gh >/dev/null 2>&1; then
  echo "(skipped Pulse wiring — gh not found; install the GitHub CLI to enable)"
  exit 0
fi
if ! gh auth token >/dev/null 2>&1; then
  echo "(skipped Pulse wiring — gh not authenticated; run 'gh auth login' to enable)"
  exit 0
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')"
if [ -z "$REPO" ]; then
  echo "(skipped Pulse wiring — could not determine repo name)"
  exit 0
fi

CONNECT_RESP="$(curl -s -m 10 -w '\n%{http_code}' \
  -X POST "${PULSE_URL%/}/connect" \
  -H "Authorization: Bearer $(gh auth token)" \
  -H "content-type: application/json" \
  -d "{\"repo\":\"${REPO}\"}" 2>/dev/null)" || {
  echo "(skipped Pulse wiring — /connect request failed; verdicts stay local)"
  exit 0
}

HTTP_CODE="$(printf '%s' "$CONNECT_RESP" | tail -1)"
BODY="$(printf '%s' "$CONNECT_RESP" | sed '$d')"

if [ "$HTTP_CODE" != "200" ]; then
  echo "(skipped Pulse wiring — /connect returned HTTP $HTTP_CODE; verdicts stay local)"
  exit 0
fi

# Parse {url, token} from the response (jq if available, else grep/sed).
if command -v jq >/dev/null 2>&1; then
  PULSE_TOKEN="$(printf '%s' "$BODY" | jq -r '.token // empty' 2>/dev/null)"
  PULSE_CONNECT_URL="$(printf '%s' "$BODY" | jq -r '.url // empty' 2>/dev/null)"
else
  PULSE_TOKEN="$(printf '%s' "$BODY" | grep -o '"token":"[^"]*"' | sed 's/"token":"//;s/"//')"
  PULSE_CONNECT_URL="$(printf '%s' "$BODY" | grep -o '"url":"[^"]*"' | sed 's/"url":"//;s/"//')"
fi

if [ -z "$PULSE_TOKEN" ]; then
  echo "(skipped Pulse wiring — no token in /connect response; verdicts stay local)"
  exit 0
fi

# Use the URL from the response if present, else the URL we POSTed to.
[ -n "$PULSE_CONNECT_URL" ] && PULSE_URL="$PULSE_CONNECT_URL"

# Write .otta/pulse.env — idempotent (overwrite is fine).
mkdir -p .otta
printf 'OTTA_PULSE_URL=%s\nOTTA_PULSE_TOKEN=%s\n' "$PULSE_URL" "$PULSE_TOKEN" > .otta/pulse.env
chmod 600 .otta/pulse.env

# Ensure .otta/ is gitignored (append only if absent).
if [ -f .gitignore ]; then
  grep -qxF '.otta/' .gitignore || printf '\n.otta/\n' >> .gitignore
else
  printf '.otta/\n' > .gitignore
fi

echo "✓ Pulse wired — .otta/pulse.env written (gitignored). Gate verdicts will stream automatically."

# Verify the browser installation with the server-side App authority. Missing
# access and stale permission approval are definitive setup failures. A
# temporary Pulse/GitHub outage fails open: preserve the repo token and explain
# that readiness remains unverified so local gates can still run.
STATUS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/otta-pulse-status.sh"
ATTEMPTS="${OTTA_PULSE_STATUS_ATTEMPTS:-15}"
INTERVAL="${OTTA_PULSE_STATUS_INTERVAL_SECONDS:-2}"
STATUS_RC=5
for _attempt in $(seq 1 "$ATTEMPTS"); do
  set +e
  STATUS_OUT="$(OTTA_PULSE_URL="$PULSE_URL" OTTA_PULSE_TOKEN="$PULSE_TOKEN" bash "$STATUS_SCRIPT" "$REPO" 2>&1)"
  STATUS_RC=$?
  set -e
  if [ "$STATUS_RC" -eq 0 ] || [ "$STATUS_RC" -eq 4 ]; then
    break
  fi
  if [ "$_attempt" -ge "$ATTEMPTS" ]; then
    break
  fi
  sleep "$INTERVAL"
done

case "$STATUS_RC" in
  0) printf '%s\n' "$STATUS_OUT" ;;
  3|4) printf '%s\n' "$STATUS_OUT"; exit "$STATUS_RC" ;;
  *)
    printf '%s\n' "${STATUS_OUT:-Pulse verification unavailable; local setup can continue, but connection is not verified.}"
    ;;
esac
