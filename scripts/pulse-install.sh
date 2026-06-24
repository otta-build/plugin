#!/usr/bin/env bash
# pulse-install.sh [--open] — onboard the Otta Pulse GitHub App and auto-wire
# the repo's Pulse credentials into .otta/pulse.env.
#
# Install is interactive browser consent (GitHub never lets a tool install an
# App silently). This prints the install URL and, with --open, launches it.
# Detection of an existing install needs the App's own JWT, which a customer
# doesn't have — so we guide rather than auto-detect.
set -euo pipefail

APP_SLUG="otta-pulse"
INSTALL_URL="https://github.com/apps/${APP_SLUG}/installations/new"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '<your repo>')"

cat <<EOF
Otta Pulse — DORA metrics + merge gates for your repos.

1. Open:   ${INSTALL_URL}
2. Pick your account/org (the owner of ${REPO}).
3. Choose "All repositories" (auto-covers future repos) or select specific ones.
4. Install. Backfill of ~180 days runs automatically within minutes.

After install, Pulse ingests your PR/CI/tag webhooks with zero further config.
EOF

if [ "${1:-}" = "--open" ]; then
  if command -v open >/dev/null; then open "$INSTALL_URL"
  elif command -v xdg-open >/dev/null; then xdg-open "$INSTALL_URL"
  else echo "(could not auto-open — visit the URL above)"; fi
fi

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

PULSE_URL="${OTTA_PULSE_URL:-https://pulse.otta.build}"
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
BODY="$(printf '%s' "$CONNECT_RESP" | head -n -1)"

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
