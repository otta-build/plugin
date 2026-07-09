#!/usr/bin/env bash
# otta-pulse-doctor.sh [owner/repo]
#
# Verify the Otta Pulse GitHub App installation with GitHub App auth, not a
# normal gh user token. This checks the permission that matters for advisory
# checks: the app installation token must include checks=write.
set -euo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: $1 is required." >&2
    exit 2
  }
}

need curl
need jq
need openssl
need python3

APP_ID="${OTTA_PULSE_APP_ID:-${GITHUB_APP_ID:-}}"
PRIVATE_KEY_PATH="${OTTA_PULSE_PRIVATE_KEY_PATH:-${GITHUB_APP_PRIVATE_KEY_PATH:-}}"
PRIVATE_KEY_VALUE="${OTTA_PULSE_PRIVATE_KEY:-${GITHUB_APP_PRIVATE_KEY:-}}"

if [ -z "$APP_ID" ] || { [ -z "$PRIVATE_KEY_PATH" ] && [ -z "$PRIVATE_KEY_VALUE" ]; }; then
  cat >&2 <<'EOF'
ERROR: GitHub App credentials required.

This doctor intentionally uses GitHub App JWT auth. A normal `gh` user token is
not enough to verify /repos/{owner}/{repo}/installation or checks:write for the
app installation.

Set:
  OTTA_PULSE_APP_ID=<app-id>
  OTTA_PULSE_PRIVATE_KEY_PATH=/path/to/github-app-private-key.pem

or:
  OTTA_PULSE_APP_ID=<app-id>
  OTTA_PULSE_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----...'
EOF
  exit 2
fi

if [ "${1:-}" != "" ]; then
  REPO="$1"
else
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: repo argument required when gh is not installed." >&2
    echo "usage: otta-pulse-doctor.sh <owner/repo>" >&2
    exit 2
  fi
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  if [ -z "$REPO" ]; then
    echo "ERROR: could not detect repo. Pass <owner/repo> explicitly." >&2
    exit 2
  fi
fi

case "$REPO" in
  */*) ;;
  *)
    echo "ERROR: repo must be owner/repo, got: $REPO" >&2
    exit 2
    ;;
esac

TMP_KEY=""
cleanup() {
  [ -n "$TMP_KEY" ] && rm -f "$TMP_KEY"
  return 0
}
trap cleanup EXIT

if [ -n "$PRIVATE_KEY_PATH" ]; then
  KEY_FILE="$PRIVATE_KEY_PATH"
else
  TMP_KEY="$(mktemp)"
  chmod 600 "$TMP_KEY"
  PRIVATE_KEY_VALUE="$PRIVATE_KEY_VALUE" python3 - "$TMP_KEY" <<'PY'
import os, pathlib, sys
value = os.environ["PRIVATE_KEY_VALUE"]
if "\\n" in value and "\n" not in value:
    value = value.replace("\\n", "\n")
pathlib.Path(sys.argv[1]).write_text(value)
PY
  KEY_FILE="$TMP_KEY"
fi

[ -f "$KEY_FILE" ] || { echo "ERROR: private key file not found: $KEY_FILE" >&2; exit 2; }

b64url() {
  python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).rstrip(b"=").decode())'
}

NOW="$(date +%s)"
IAT="$((NOW - 60))"
EXP="$((NOW + 540))"
HEADER_B64="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
PAYLOAD_B64="$(APP_ID="$APP_ID" IAT="$IAT" EXP="$EXP" python3 - <<'PY' | b64url
import json, os, sys
sys.stdout.write(json.dumps({
    "iat": int(os.environ["IAT"]),
    "exp": int(os.environ["EXP"]),
    "iss": os.environ["APP_ID"],
}, separators=(",", ":")))
PY
)"
SIGNING_INPUT="${HEADER_B64}.${PAYLOAD_B64}"
SIGNATURE_B64="$(printf '%s' "$SIGNING_INPUT" | openssl dgst -sha256 -sign "$KEY_FILE" -binary | b64url)"
JWT="${SIGNING_INPUT}.${SIGNATURE_B64}"

gh_app_get() {
  local path="$1"
  curl -fsS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${JWT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API%/}${path}"
}

gh_app_post() {
  local path="$1"
  curl -fsS \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${JWT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API%/}${path}"
}

APP_JSON="$(gh_app_get "/app")" || {
  echo "ERROR: GitHub App JWT auth failed. Check OTTA_PULSE_APP_ID and private key." >&2
  exit 3
}
APP_SLUG="$(printf '%s' "$APP_JSON" | jq -r '.slug // "unknown"')"
APP_CHECKS="$(printf '%s' "$APP_JSON" | jq -r '.permissions.checks // "none"')"

INSTALL_JSON="$(gh_app_get "/repos/${REPO}/installation")" || {
  echo "ERROR: no GitHub App installation found for ${REPO}, or this app cannot access it." >&2
  echo "Open https://github.com/apps/${APP_SLUG}/installations/new and install/update it for the repo." >&2
  exit 3
}
INSTALL_ID="$(printf '%s' "$INSTALL_JSON" | jq -r '.id // empty')"
[ -n "$INSTALL_ID" ] || {
  echo "ERROR: GitHub installation response did not include an installation id." >&2
  exit 3
}

TOKEN_JSON="$(gh_app_post "/app/installations/${INSTALL_ID}/access_tokens")" || {
  echo "ERROR: could not mint an installation token for ${REPO}." >&2
  exit 3
}
INSTALL_CHECKS="$(printf '%s' "$TOKEN_JSON" | jq -r '.permissions.checks // "none"')"

echo "Pulse app: ${APP_SLUG}"
echo "Repo installation: ${REPO} (installation ${INSTALL_ID})"
echo "App manifest checks: ${APP_CHECKS}"
echo "Installation token checks: ${INSTALL_CHECKS}"

if [ "$INSTALL_CHECKS" != "write" ]; then
  echo "ERROR: checks: ${INSTALL_CHECKS}" >&2
  echo "Update the GitHub App permission to Checks: Read and write, then re-accept the installation for ${REPO}." >&2
  exit 4
fi

echo "OK: Otta Pulse can post GitHub Check Runs for ${REPO}."
