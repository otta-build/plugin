#!/usr/bin/env bash
# otta-telemetry-setup.sh <owner/repo> <webhook-secret> [--traces]
#
# Derives a per-repo HMAC token by calling the Pulse /token endpoint with the
# webhook secret, then merges an OTEL `env` block into .claude/settings.local.json
# (gitignored, token-bearing — NEVER the committed settings.json) so Claude Code
# emits telemetry to Otta Pulse. Logs are the default; --traces additionally opts
# into the BETA traces/spans exporters. Merge-into-existing, never clobber;
# idempotent on re-run.
#
# The webhook secret is used ONLY to derive the per-repo token from Pulse; it is
# NEVER written to any file. Only the derived token is stored.
#
# Endpoint base: OTTA_PULSE_URL if set, else the hosted default. Repo slug comes
# from the caller (e.g. `gh repo view --json nameWithOwner -q .nameWithOwner`);
# the interactive /otta:setup step passes it here, so this writer stays
# unit-testable on its own.
set -euo pipefail

REPO="${1:-}"
WEBHOOK_SECRET="${2:-}"
TRACES=0
[ "${3:-}" = "--traces" ] && TRACES=1

if [ -z "$REPO" ] || [ -z "$WEBHOOK_SECRET" ]; then
  echo "usage: otta-telemetry-setup.sh <owner/repo> <webhook-secret> [--traces]" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required for the JSON merge." >&2; exit 1; }

PULSE="${OTTA_PULSE_URL:-https://pulse.otta.build}"
PULSE="${PULSE%/}"            # normalize trailing slash so /v1/logs isn't doubled

# Derive the per-repo token via Pulse /token (auth: webhook secret).
# The webhook secret is NEVER written to any file — only TOKEN is stored.
if ! RESPONSE=$(curl -fsS -m 10 "${PULSE}/token?repo=${REPO}" \
    -H "x-pulse-token: ${WEBHOOK_SECRET}" 2>&1); then
  echo "Error: could not reach Pulse at ${PULSE}/token" >&2
  echo "Response: ${RESPONSE}" >&2
  exit 1
fi
TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null) || true
if [ -z "$TOKEN" ]; then
  echo "Error: /token response did not contain a token field. Got: ${RESPONSE}" >&2
  exit 1
fi

SETTINGS=".claude/settings.local.json"

mkdir -p .claude

# Merge with python3 (portable; same dependency the rest of the test suite uses).
# Preserves any existing top-level keys and any unrelated `env` entries; only the
# OTEL keys below are added/overwritten, so a re-run is a no-op (idempotent).
REPO="$REPO" TOKEN="$TOKEN" PULSE="$PULSE" TRACES="$TRACES" \
python3 - "$SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
pulse = os.environ["PULSE"]
repo = os.environ["REPO"]
token = os.environ["TOKEN"]
traces = os.environ["TRACES"] == "1"

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

env = data.get("env")
if not isinstance(env, dict):
    env = {}

env.update({
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": pulse + "/v1/logs",
    "OTEL_EXPORTER_OTLP_HEADERS": "x-pulse-token=" + token,
    "OTEL_RESOURCE_ATTRIBUTES": "repo=" + repo,
})

if traces:
    env.update({
        "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
        "OTEL_TRACES_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json",
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": pulse + "/v1/traces",
    })

data["env"] = env

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

chmod 600 "$SETTINGS"

# Token-bearing file must never be committed — ensure .gitignore covers it.
if [ -f .gitignore ]; then
  grep -qxF '.claude/settings.local.json' .gitignore || printf '\n.claude/settings.local.json\n' >> .gitignore
else
  printf '.claude/settings.local.json\n' > .gitignore
fi

if [ "$TRACES" = "1" ]; then
  echo "✓ Telemetry wired (logs + traces BETA) → ${PULSE} — written to ${SETTINGS} (gitignored)."
else
  echo "✓ Telemetry wired (logs) → ${PULSE} — written to ${SETTINGS} (gitignored). Re-run with --traces to add spans (beta)."
fi
echo "  ↻ Restart Claude Code in this directory for telemetry to take effect (CC reads settings at startup)."
