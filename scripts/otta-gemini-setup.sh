#!/usr/bin/env bash
# otta-gemini-setup.sh <owner/repo> [legacy-positional-pulse-token]
# otta-gemini-setup.sh --derive <owner/repo> [self-hosted-webhook-secret]
#
# Wires Gemini CLI telemetry to Otta Pulse via DIRECT OTLP/HTTP export — no
# collector sidecar required.
#
# Verified against gemini-cli source (packages/core/src/telemetry/sdk.ts,
# config.ts) as of v0.52.0:
#   - `telemetry.target: "local"` (the default) plus a non-empty
#     `telemetry.otlpEndpoint` makes Gemini export OTLP directly — a collector
#     is only relevant for `target: "gcp"` + `useCollector`.
#   - The OTLPTraceExporterHttp/LogExporterHttp/MetricExporterHttp instances
#     are constructed with only a `url` — no explicit `headers` — so the
#     underlying @opentelemetry/otlp-exporter-base falls back to the standard
#     OTEL_EXPORTER_OTLP_HEADERS (or per-signal *_HEADERS) env var to inject
#     auth headers. This means Gemini DOES support header-based auth for
#     direct export; the collector-sidecar approach from a prior version of
#     this script was unnecessary.
# settings.json is where `enabled`/`otlpEndpoint`/`otlpProtocol` live; the
# token-bearing header must go in an env var (never committed).
#
# Token is kept out of the committed file:
#   - .gemini/settings.json only has enabled/target/otlpEndpoint/otlpProtocol
#     (no token) and is gitignored anyway (private, mode 0600)
#   - .otta/gemini.env carries OTEL_EXPORTER_OTLP_HEADERS=x-pulse-token=<token>
#     and is gitignored (token-bearing)
#
# Endpoint base: OTTA_PULSE_URL if set, else the hosted default.
set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required." >&2; exit 1; }

HOSTED_DEFAULT="https://pulse.otta.build"
PULSE="${OTTA_PULSE_URL:-https://pulse.otta.build}"
PULSE="${PULSE%/}"  # normalize trailing slash

usage() {
  echo "usage: OTTA_PULSE_TOKEN=<repo-token> otta-gemini-setup.sh <owner/repo>" >&2
  echo "       OTTA_PULSE_WEBHOOK_SECRET=<secret> otta-gemini-setup.sh --derive <owner/repo>" >&2
  echo "       legacy positional compatibility: <owner/repo> <pulse-token>; --derive <owner/repo> <webhook-secret>" >&2
  exit 2
}

DERIVE=0
REPO=""
TOKEN=""
WEBHOOK_SECRET=""

if [ "${1:-}" = "--derive" ]; then
  DERIVE=1
  REPO="${2:-}"
  WEBHOOK_SECRET="${3:-${OTTA_PULSE_WEBHOOK_SECRET:-}}"
  [ "$#" -le 3 ] || usage
  [ -n "$REPO" ] || usage
else
  REPO="${1:-}"
  TOKEN="${2:-${OTTA_PULSE_TOKEN:-}}"
  if [ "$#" -eq 1 ] && [ -n "${OTTA_PULSE_TOKEN:-}" ]; then
    : # Preferred direct mode: secret comes from the environment, not argv.
  elif [ "$#" -ne 2 ]; then
    usage
  fi
  [ -n "$REPO" ] && [ -n "$TOKEN" ] || usage
fi

if [ "$DERIVE" -eq 1 ]; then
  if [ "$PULSE" = "$HOSTED_DEFAULT" ]; then
    PULSE_ENV_FILE="${OTTA_PULSE_ENV_FILE:-.otta/pulse.env}"
    TOKEN=""
    if [ -f "$PULSE_ENV_FILE" ]; then
      TOKEN="$(sed -n 's/^OTTA_PULSE_TOKEN=//p' "$PULSE_ENV_FILE" | tail -1)"
    fi
    TOKEN="${TOKEN:-${OTTA_PULSE_TOKEN:-}}"
    if [ -z "$TOKEN" ]; then
      echo "Error: hosted Pulse requires the repo token written by pulse-install.sh in ${PULSE_ENV_FILE}." >&2
      echo "Run otta setup/status to complete and verify the GitHub App installation first." >&2
      exit 1
    fi
  else
    command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required for self-hosted --derive." >&2; exit 1; }
    if [ -z "$WEBHOOK_SECRET" ]; then
      echo "Error: self-hosted Pulse requires a webhook secret for --derive." >&2
      usage
    fi
    if ! RESPONSE=$(curl -fsS -m 10 "${PULSE}/token?repo=${REPO}" \
        -H "x-pulse-token: ${WEBHOOK_SECRET}" 2>&1); then
      echo "Error: could not derive a repo token from ${PULSE}/token (response body redacted)." >&2
      exit 1
    fi
    TOKEN=$(printf '%s' "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])" 2>/dev/null) || true
    if [ -z "$TOKEN" ]; then
      echo "Error: /token response did not contain a token field (response body redacted)." >&2
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 1. Merge .gemini/settings.json — telemetry block only, never clobber other
#    keys; token NOT written here (goes in the env file below).
# ---------------------------------------------------------------------------
mkdir -p .gemini

PULSE_ENDPOINT="$PULSE" python3 - ".gemini/settings.json" <<'PY'
import json, os, sys

path = sys.argv[1]
pulse_endpoint = os.environ["PULSE_ENDPOINT"]

try:
    with open(path) as f:
        raw = f.read()
    if raw.strip() == "":
        data = {}
    else:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            print(
                f"ERROR: {path} exists and is not valid JSON — refusing to "
                "overwrite it. Fix or remove the file, then re-run.",
                file=sys.stderr,
            )
            sys.exit(1)
        if not isinstance(data, dict):
            print(
                f"ERROR: {path} exists and is valid JSON but not a JSON "
                "object (found "
                f"{type(data).__name__}) — refusing to overwrite it. Fix or "
                "remove the file, then re-run.",
                file=sys.stderr,
            )
            sys.exit(1)
except FileNotFoundError:
    data = {}

# Merge telemetry block — direct OTLP/HTTP export, target "local" (default).
# otlpEndpoint is the base URL only: Gemini's exporter joins v1/traces,
# v1/logs, v1/metrics onto it (see sdk.ts buildUrl), same convention as the
# Codex adapter's config.toml exporter endpoints.
tel = data.get("telemetry")
if not isinstance(tel, dict):
    tel = {}
tel["enabled"] = True
tel["target"] = "local"
tel["otlpEndpoint"] = pulse_endpoint
tel["otlpProtocol"] = "http"
tel["logPrompts"] = False
data["telemetry"] = tel

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

chmod 600 .gemini/settings.json

# Ensure .gemini/settings.json is gitignored (good hygiene; no token but private)
if [ -f .gitignore ]; then
  grep -qxF '.gemini/settings.json' .gitignore || printf '\n.gemini/settings.json\n' >> .gitignore
else
  printf '.gemini/settings.json\n' > .gitignore
fi

# ---------------------------------------------------------------------------
# 2. Write .otta/gemini.env — OTEL_EXPORTER_OTLP_HEADERS carries the auth
#    header. Gemini's OTLP HTTP exporters read this standard env var when no
#    explicit headers are passed in code (confirmed in
#    @opentelemetry/otlp-exporter-base's env-configuration fallback).
#    Must be sourced before starting `gemini` (e.g. `source .otta/gemini.env`
#    or export in the shell profile) — Gemini does not read this file itself.
#
#    Also sets GEMINI_CLI_TRUST_WORKSPACE=true: workspace-scoped settings
#    (.gemini/settings.json, including our telemetry block) are SILENTLY
#    DROPPED by Gemini's settings merge unless the folder is "trusted"
#    (folder-trust feature, default on — confirmed in
#    packages/cli/src/config/settings.ts mergeSettings + trustedFolders.ts).
#    Without this, telemetry would appear configured but never actually take
#    effect. This is the documented CI/automation bypass (docs/cli/trusted-
#    folders.md), equivalent to `gemini --skip-trust`.
# ---------------------------------------------------------------------------
ENV_FILE=".otta/gemini.env"
mkdir -p ".otta"

shell_export() {
  # Bash %q emits one sourceable shell word, including for embedded newlines,
  # quotes, substitutions, and metacharacters. Never interpolate values into
  # executable shell text directly.
  printf 'export %s=%q\n' "$1" "$2"
}

{
  printf '%s\n' \
    '# Gemini CLI OTLP auth header — sourced by you before starting `gemini`.' \
    '# Gemini reads OTEL_EXPORTER_OTLP_HEADERS from the process environment' \
    '# (standard OpenTelemetry JS SDK fallback) to authenticate direct OTLP' \
    '# export; .gemini/settings.json only carries the non-secret endpoint.' \
    '#' \
    '# Generated by otta-gemini-setup — do NOT commit (token-bearing)'
  shell_export OTEL_EXPORTER_OTLP_HEADERS "x-pulse-token=${TOKEN}"
  shell_export OTEL_RESOURCE_ATTRIBUTES "repo=${REPO},harness=gemini"
  shell_export GEMINI_CLI_TRUST_WORKSPACE "true"
} > "$ENV_FILE"

chmod 600 "$ENV_FILE"

# Ensure .otta/gemini.env is gitignored (token-bearing)
if [ -f .gitignore ]; then
  grep -qxF '.otta/gemini.env' .gitignore || printf '\n.otta/gemini.env\n' >> .gitignore
else
  printf '.otta/gemini.env\n' > .gitignore
fi

echo "Telemetry wired (Gemini → Pulse, direct OTLP/HTTP — no collector needed) — written to .gemini/settings.json."
echo "Data will be sent to ${PULSE}. Set OTTA_PULSE_URL to override."
echo ""
echo "Source the auth header before starting Gemini CLI:"
echo "  source ${ENV_FILE} && gemini"
echo ""
echo "That also sets GEMINI_CLI_TRUST_WORKSPACE=true — without it, Gemini's folder-trust"
echo "feature silently ignores this workspace's .gemini/settings.json (telemetry included)."
echo "Restart Gemini CLI fully (settings.json telemetry changes require a restart)."
echo "Committed: nothing telemetry-specific (both files are gitignored, private)."
echo "Gitignored: .gemini/settings.json, ${ENV_FILE}"
