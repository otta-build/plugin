#!/usr/bin/env bash
# Customer-safe Pulse installation verification using the repo-scoped token.
# Exit: 0 ready, 3 not installed, 4 checks approval stale, 5 unavailable.
set -euo pipefail

REPO="${1:-}"
ENV_FILE="${OTTA_PULSE_ENV_FILE:-.otta/pulse.env}"
HOSTED_DEFAULT="https://pulse.otta.build"

env_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -1
}

if [ -z "$REPO" ] && command -v gh >/dev/null 2>&1; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
  echo "Pulse verification unavailable: could not determine owner/repo." >&2
  exit 5
fi

PULSE_URL="${OTTA_PULSE_URL:-$(env_value OTTA_PULSE_URL)}"
PULSE_URL="${PULSE_URL:-$HOSTED_DEFAULT}"
PULSE_URL="${PULSE_URL%/}"
PULSE_TOKEN="${OTTA_PULSE_TOKEN:-$(env_value OTTA_PULSE_TOKEN)}"
if [ -z "$PULSE_TOKEN" ]; then
  echo "Pulse verification unavailable: no repo token in ${ENV_FILE}." >&2
  exit 5
fi

RESP="$(curl -sS -m 10 -w '\n%{http_code}' \
  -H "x-pulse-token: ${PULSE_TOKEN}" \
  "${PULSE_URL}/installation-status?repo=${REPO}" 2>/dev/null)" || {
  echo "Pulse verification unavailable: could not reach ${PULSE_URL}." >&2
  exit 5
}
HTTP_CODE="$(printf '%s' "$RESP" | tail -1)"
BODY="$(printf '%s' "$RESP" | sed '$d')"
STATE="$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state", ""))' 2>/dev/null || true)"

case "$STATE" in
  ready)
    echo "Pulse installation verified: repository access + checks:write are active."
    exit 0
    ;;
  not_installed)
    echo "Pulse not connected: the GitHub App is not installed or does not have access to ${REPO}." >&2
    echo "Open https://github.com/apps/otta-pulse/installations/new and grant this repository." >&2
    exit 3
    ;;
  permission_approval_required)
    echo "Pulse not connected: the installation has stale permissions." >&2
    echo "Update the App to Checks: Read and write, then re-accept the installation for ${REPO}." >&2
    exit 4
    ;;
  github_unavailable|app_credentials_unavailable)
    echo "Pulse verification unavailable (${STATE}); local setup can continue, but connection is not verified." >&2
    exit 5
    ;;
  *)
    echo "Pulse verification unavailable: installation-status returned HTTP ${HTTP_CODE} without a recognized state." >&2
    exit 5
    ;;
esac
