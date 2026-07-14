#!/usr/bin/env bash
# otta-telemetry-setup.sh <owner/repo> [webhook-secret] [--traces]
#
# Reuses the hosted repo token written by pulse-install.sh (or derives one from
# an operator-authenticated self-hosted /token endpoint), then
# merges an OTEL `env` block into .claude/settings.local.json (gitignored,
# token-bearing — NEVER the committed settings.json) so Claude Code emits
# telemetry to Otta Pulse. Logs are the default; --traces additionally opts
# into the BETA traces/spans exporters. Merge-into-existing, never clobber;
# idempotent on re-run.
#
# Hosted pulse.otta.build: .otta/pulse.env is required. /token is admin-only.
#
# Self-hosted (OTTA_PULSE_URL set to a non-hosted URL): the webhook secret must
# be provided as the second positional argument. It is passed as the
# x-pulse-token header only for the /token call; it is NEVER written to any file.
#
# Endpoint base: OTTA_PULSE_URL if set, else the hosted default. Repo slug comes
# from the caller (e.g. `gh repo view --json nameWithOwner -q .nameWithOwner`);
# the interactive /otta:setup step passes it here, so this writer stays
# unit-testable on its own.
#
# Pulse correlation: once wired, Claude Code natively emits workflow.run_id
# and workflow.name on workflow-spawned-agent telemetry, and agent_id /
# agent_type on hook events. Pulse joins runs to pipeline stages on these four
# attributes — this script does not need to set them itself.
set -euo pipefail

REPO="${1:-}"
WEBHOOK_SECRET=""
TRACES=0
# Parse remaining args: optional positional webhook-secret (not starting with --)
# followed by optional --traces flag.
shift || true
for _arg in "$@"; do
  case "$_arg" in
    --traces) TRACES=1 ;;
    --*)      echo "unknown flag: $_arg" >&2; exit 2 ;;
    *)        WEBHOOK_SECRET="$_arg" ;;
  esac
done

if [ -z "$REPO" ]; then
  echo "usage: otta-telemetry-setup.sh <owner/repo> [webhook-secret] [--traces]" >&2
  exit 2
fi

HOSTED_DEFAULT="https://pulse.otta.build"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required for the JSON merge." >&2; exit 1; }

PULSE_ENV_FILE="${OTTA_PULSE_ENV_FILE:-.otta/pulse.env}"
env_value() {
  local key="$1"
  [ -f "$PULSE_ENV_FILE" ] || return 0
  sed -n "s/^${key}=//p" "$PULSE_ENV_FILE" | tail -1
}

PULSE="${OTTA_PULSE_URL:-$(env_value OTTA_PULSE_URL)}"
PULSE="${PULSE:-$HOSTED_DEFAULT}"
PULSE="${PULSE%/}"            # normalize trailing slash so /v1/logs isn't doubled

# Hosted pulse.otta.build: reuse the repo-scoped token from pulse.env.
# Self-hosted: webhook secret required; passed as x-pulse-token header.
if [ "$PULSE" = "$HOSTED_DEFAULT" ]; then
  TOKEN="$(env_value OTTA_PULSE_TOKEN)"
  TOKEN="${TOKEN:-${OTTA_PULSE_TOKEN:-}}"
  if [ -z "$TOKEN" ]; then
    echo "Error: hosted Pulse requires the repo token written by pulse-install.sh in ${PULSE_ENV_FILE}." >&2
    echo "Run otta setup/status to complete and verify the GitHub App installation first." >&2
    exit 1
  fi
else
  # Self-hosted path: webhook secret is required.
  if [ -z "$WEBHOOK_SECRET" ]; then
    echo "Error: OTTA_PULSE_URL is set to a self-hosted instance (${PULSE}). A webhook secret is required as the second argument." >&2
    echo "usage: otta-telemetry-setup.sh <owner/repo> <webhook-secret> [--traces]" >&2
    exit 2
  fi
  # The webhook secret is NEVER written to any file — only the derived TOKEN is stored.
  if ! RESPONSE=$(curl -fsS -m 10 "${PULSE}/token?repo=${REPO}" \
      -H "x-pulse-token: ${WEBHOOK_SECRET}" 2>&1); then
    echo "Error: could not reach Pulse at ${PULSE}/token" >&2
    exit 1
  fi
  TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null) || true
  if [ -z "$TOKEN" ]; then
    echo "Error: /token response did not contain a token field (response body redacted)." >&2
    exit 1
  fi
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
except FileNotFoundError:
    data = {}
except json.JSONDecodeError:
    raise SystemExit("Error: existing .claude/settings.local.json is malformed JSON; refusing to overwrite it.")

if not isinstance(data, dict):
    raise SystemExit("Error: existing .claude/settings.local.json root must be an object; refusing to overwrite it.")

env = data.get("env")
if env is None and "env" not in data:
    env = {}
elif not isinstance(env, dict):
    raise SystemExit("Error: existing .claude/settings.local.json env must be an object; refusing to overwrite it.")

env.update({
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": pulse + "/v1/logs",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": pulse + "/v1/metrics",
    "OTEL_EXPORTER_OTLP_HEADERS": "x-pulse-token=" + token,
    "OTEL_RESOURCE_ATTRIBUTES": "repo=" + repo + ",harness=claude_code",
    "OTTA_PULSE_URL": pulse,
    "OTTA_PULSE_TOKEN": token,
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
  echo "✓ Telemetry wired (logs + metrics + traces BETA) → ${PULSE} — written to ${SETTINGS} (gitignored)."
else
  echo "✓ Telemetry wired (logs + metrics) → ${PULSE} — written to ${SETTINGS} (gitignored). Re-run with --traces to add spans (beta)."
fi
echo "  ↻ Restart Claude Code in this directory for telemetry to take effect (CC reads settings at startup)."
