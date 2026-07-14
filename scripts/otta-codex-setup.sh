#!/usr/bin/env bash
# otta-codex-setup.sh <owner/repo> [legacy-positional-pulse-token]
# otta-codex-setup.sh --derive <owner/repo> [self-hosted-webhook-secret]
#
# Wires Codex CLI telemetry to Otta Pulse by merging an [otel] block into
# ~/.codex/config.toml (or $CODEX_HOME/config.toml).
#
# Codex reads OTEL config from config.toml only — it does NOT honor OTEL_* env
# vars. This script merges only the [otel] and [otel.*] sections, preserving all
# other config.toml content verbatim.
#
# Also writes .otta/codex.env (legacy, backward compat — Codex does not read
# these env vars, but kept for documentation / tooling that sources the file).
#
# Endpoint base: OTTA_PULSE_URL if set, else the hosted default.
set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required." >&2; exit 1; }

HOSTED_DEFAULT="https://pulse.otta.build"
PULSE="${OTTA_PULSE_URL:-https://pulse.otta.build}"
PULSE="${PULSE%/}"  # normalize trailing slash

usage() {
  echo "usage: OTTA_PULSE_TOKEN=<repo-token> otta-codex-setup.sh <owner/repo>" >&2
  echo "       OTTA_PULSE_WEBHOOK_SECRET=<secret> otta-codex-setup.sh --derive <owner/repo>" >&2
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
# 1. Merge [otel] block into $CODEX_HOME/config.toml (or ~/.codex/config.toml)
# ---------------------------------------------------------------------------
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_DIR"
CONFIG_TOML="$CODEX_DIR/config.toml"

OTTA_PULSE="$PULSE" OTTA_TOKEN="$TOKEN" OTTA_REPO="$REPO" python3 - "$CONFIG_TOML" <<'PY'
import json, os, re, sys

path = sys.argv[1]
pulse = os.environ["OTTA_PULSE"]
token = os.environ["OTTA_TOKEN"]
repo = os.environ["OTTA_REPO"]

# Read existing content (or start empty)
try:
    with open(path) as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

# Strip only Otta-managed legacy exporter sub-tables and the two Otta-managed
# exporter keys. Codex's schema requires each OTLP/HTTP exporter to be an inline
# tagged object; the older string selector + child table shape is invalid.
# Table names may use bare or quoted TOML segments. All unrelated content,
# including other direct [otel] keys and literal quoted tables, is preserved.
kept = []
has_otel = False
in_managed_table = False

def toml_string(value):
    # JSON basic strings use the same escaping needed here; retain Unicode as
    # UTF-8 so non-BMP values do not become invalid TOML surrogate escapes.
    return json.dumps(value, ensure_ascii=False)

def exporter_value(endpoint):
    return (
        '{ otlp-http = { endpoint = ' + toml_string(endpoint) +
        ', protocol = "json", headers = { x-pulse-token = ' +
        toml_string(token) + ', x-pulse-repo = ' + toml_string(repo) +
        ' } } }'
    )

exporter_lines = (
    'exporter = ' + exporter_value(pulse + '/v1/logs') + '\n'
    'metrics_exporter = ' + exporter_value(pulse + '/v1/metrics') + '\n'
)

def table_path(line):
    match = re.match(r'^\s*\[\s*(.*?)\s*\]\s*(?:#.*)?$', line)
    if not match:
        return None
    inner = match.group(1)
    segments = []
    index = 0
    while index < len(inner):
        while index < len(inner) and inner[index].isspace():
            index += 1
        if index >= len(inner):
            break
        if inner[index] in ('"', "'"):
            quote = inner[index]
            index += 1
            value = []
            while index < len(inner):
                char = inner[index]
                if char == quote:
                    index += 1
                    break
                if quote == '"' and char == '\\' and index + 1 < len(inner):
                    value.extend((char, inner[index + 1]))
                    index += 2
                    continue
                value.append(char)
                index += 1
            else:
                return None
            segments.append(''.join(value))
        else:
            start = index
            while index < len(inner) and inner[index] != '.':
                index += 1
            segment = inner[start:index].strip()
            if not segment:
                return None
            segments.append(segment)
        while index < len(inner) and inner[index].isspace():
            index += 1
        if index < len(inner):
            if inner[index] != '.':
                return None
            index += 1
    return tuple(segments)

managed_prefixes = (
    ('otel', 'exporter', 'otlp-http'),
    ('otel', 'metrics_exporter', 'otlp-http'),
)

current_table = None
for line in lines:
    section = table_path(line)
    if section is not None:
        current_table = section
        in_managed_table = any(
            section[:len(prefix)] == prefix
            for prefix in managed_prefixes
        )
        if section == ('otel',):
            has_otel = True
            kept.append(line)
            kept.append(exporter_lines)
            continue
    if in_managed_table:
        continue
    if current_table == ('otel',) and re.match(
        r'^\s*(?:exporter|metrics_exporter|"exporter"|"metrics_exporter")\s*=',
        line,
    ):
        continue
    kept.append(line)

# Remove trailing blank lines from preserved content
content = ''.join(kept).rstrip('\n')

# Default [otel] header written only when absent from existing config
otel_header = (
    '[otel]\n'
    + exporter_lines +
    'log_user_prompt = false\n'
    'environment = "production"\n'
)

if content:
    if has_otel:
        # Existing [otel] section already received the inline exporter values.
        final = content + '\n'
    else:
        # No [otel] section — add defaults and inline exporters.
        final = content + '\n\n' + otel_header
else:
    final = otel_header

with open(path, 'w') as f:
    f.write(final)
PY

chmod 600 "$CONFIG_TOML"

# ---------------------------------------------------------------------------
# 2. Write .otta/codex.env — LEGACY: Codex does not read these env vars.
#    Kept for backward compat and documentation only.
# ---------------------------------------------------------------------------
ENV_FILE=".otta/codex.env"
mkdir -p ".otta"

shell_export() {
  # Bash %q emits one sourceable shell word, including for embedded newlines,
  # quotes, substitutions, and metacharacters. Never interpolate values into
  # executable shell text directly.
  printf 'export %s=%q\n' "$1" "$2"
}

{
  printf '%s\n' \
    '# LEGACY — Codex does not read these env vars. Use ~/.codex/config.toml instead.' \
    '# This file is kept for backward compatibility only. See config.toml for the' \
    '# active telemetry configuration written by otta-codex-setup.' \
    '#' \
    '# Generated by otta-codex-setup — do NOT commit (token-bearing)'
  shell_export OTEL_LOGS_EXPORTER "otlp"
  shell_export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT "${PULSE}/v1/logs"
  shell_export OTEL_EXPORTER_OTLP_LOGS_HEADERS "x-pulse-token=${TOKEN}"
  shell_export OTEL_EXPORTER_OTLP_LOGS_PROTOCOL "http/json"
  shell_export OTEL_METRICS_EXPORTER "otlp"
  shell_export OTEL_EXPORTER_OTLP_METRICS_ENDPOINT "${PULSE}/v1/metrics"
  shell_export OTEL_EXPORTER_OTLP_METRICS_HEADERS "x-pulse-token=${TOKEN}"
  shell_export OTEL_EXPORTER_OTLP_METRICS_PROTOCOL "http/json"
  shell_export OTEL_RESOURCE_ATTRIBUTES "repo=${REPO},harness=codex"
} > "$ENV_FILE"

chmod 600 "$ENV_FILE"

# Ensure .otta/codex.env is gitignored (token-bearing)
if [ -f .gitignore ]; then
  grep -qxF '.otta/codex.env' .gitignore || printf '\n.otta/codex.env\n' >> .gitignore
else
  printf '.otta/codex.env\n' > .gitignore
fi

echo "Telemetry wired (Codex → Pulse) — written to ${CONFIG_TOML}."
echo "Data will be sent to ${PULSE}. Set OTTA_PULSE_URL to override."
echo ""
echo "Start a new Codex process (or fully restart Codex) to load the updated config.toml."
echo "Legacy env file also written to ${ENV_FILE} (gitignored, Codex does not read it)."
