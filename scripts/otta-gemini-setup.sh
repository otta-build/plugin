#!/usr/bin/env bash
# otta-gemini-setup.sh <owner/repo> <pulse-token>
#
# Wires Gemini CLI telemetry to Otta Pulse via an OTel Collector sidecar.
# Gemini CLI has no native OTLP auth headers, so we:
#   1. Point Gemini at a local OTel Collector (localhost:4318).
#   2. Generate otel-collector-config.yaml — collector adds auth header + attrs.
#
# Token is kept out of both committed files:
#   - otel-collector-config.yaml uses ${env:OTTA_PULSE_TOKEN} (OTel env sub)
#   - .gemini/settings.json only points at localhost (no token)
#
# Endpoint base: OTTA_PULSE_URL if set, else the hosted default.
set -euo pipefail

REPO="${1:-}"
TOKEN="${2:-}"

if [ -z "$REPO" ] || [ -z "$TOKEN" ]; then
  echo "usage: otta-gemini-setup.sh <owner/repo> <pulse-token>" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required." >&2; exit 1; }

PULSE="${OTTA_PULSE_URL:-https://pulse.otta.build}"
PULSE="${PULSE%/}"  # normalize trailing slash

# ---------------------------------------------------------------------------
# 1. Write .gemini/settings.json — merge, never clobber; token NOT in this file
# ---------------------------------------------------------------------------
mkdir -p .gemini

PULSE_LOGS_URL="$PULSE" python3 - ".gemini/settings.json" <<'PY'
import json, os, sys

path = sys.argv[1]
pulse_logs = os.environ["PULSE_LOGS_URL"]

try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

# Merge telemetry block (local collector — token handled by sidecar)
tel = data.get("telemetry")
if not isinstance(tel, dict):
    tel = {}
tel["endpoint"] = "http://localhost:4318/v1/logs"
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
# 2. Write otel-collector-config.yaml — token via env substitution (committable)
# ---------------------------------------------------------------------------
# Uses OTel Collector env var substitution: ${env:OTTA_PULSE_TOKEN}
# so the token never appears literally in this file.
cat > otel-collector-config.yaml <<YAML
# OTel Collector sidecar for Gemini CLI telemetry → Otta Pulse
# Start: docker run --rm \\
#   -e OTTA_PULSE_TOKEN=<your-pulse-token> \\
#   -p 4317:4317 -p 4318:4318 \\
#   -v \$(pwd)/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml \\
#   otel/opentelemetry-collector-contrib
#
# Token injected via OTTA_PULSE_TOKEN env var (not stored in this file).

receivers:
  otlp:
    protocols:
      http:
        endpoint: "0.0.0.0:4318"
      grpc:
        endpoint: "0.0.0.0:4317"

processors:
  resource:
    attributes:
      - action: insert
        key: repo
        value: "${REPO}"
      - action: insert
        key: harness
        value: gemini
  transform/cost_usd:
    log_statements:
      - context: log
        statements:
          - set(attributes["cost_usd"], Double(attributes["input_tokens"]) * 0.00000025 + Double(attributes["output_tokens"]) * 0.000001) where attributes["input_tokens"] != nil or attributes["output_tokens"] != nil
  batch: {}

exporters:
  otlphttp:
    # The otlphttp exporter appends /v1/logs, /v1/traces, etc. automatically.
    # Use the base URL only — do NOT include /v1 here or it doubles the path.
    endpoint: "${PULSE}"
    headers:
      x-pulse-token: "\${env:OTTA_PULSE_TOKEN}"

service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [resource, transform/cost_usd, batch]
      exporters: [otlphttp]
YAML

echo "Telemetry wired (Gemini → OTel Collector → Pulse logs) — config files written."
echo "Data will be sent to pulse.otta.build (hosted by Otta). Set OTTA_PULSE_URL to override."
echo ""
echo "Start the OTel Collector sidecar:"
echo "  docker run --rm \\"
echo "    -e OTTA_PULSE_TOKEN=$TOKEN \\"
echo "    -p 4317:4317 -p 4318:4318 \\"
echo "    -v \$(pwd)/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml \\"
echo "    otel/opentelemetry-collector-contrib"
echo ""
echo "Committed: otel-collector-config.yaml (no token — uses env sub)"
echo "Gitignored: .gemini/settings.json"
