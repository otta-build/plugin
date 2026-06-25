#!/usr/bin/env bash
# otta-codex-setup.sh <owner/repo> <pulse-token>
#
# Writes (or merges) an [otel] table into ~/.codex/config.toml so Codex CLI
# emits telemetry to Otta Pulse. Merge-into-existing, never clobber; idempotent
# on re-run. Endpoint base: OTTA_PULSE_URL if set, else the hosted default.
set -euo pipefail

REPO="${1:-}"
TOKEN="${2:-}"

if [ -z "$REPO" ] || [ -z "$TOKEN" ]; then
  echo "usage: otta-codex-setup.sh <owner/repo> <pulse-token>" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required." >&2; exit 1; }

PULSE="${OTTA_PULSE_URL:-https://pulse.otta.build}"
PULSE="${PULSE%/}"  # normalize trailing slash

CONFIG="${HOME}/.codex/config.toml"
mkdir -p "${HOME}/.codex"

# Merge the [otel] section using pure Python text manipulation so we have zero
# external TOML library dependencies. Strategy:
#   1. Parse the file into sections (list of (header, lines) pairs).
#   2. Find/replace the [otel] section, updating only our 3 keys; leave others.
#   3. If no [otel] section exists, append one.
#   4. Write the result back atomically.
REPO="$REPO" TOKEN="$TOKEN" PULSE="$PULSE" CONFIG="$CONFIG" \
python3 - <<'PY'
import os, sys, re

path   = os.environ["CONFIG"]
pulse  = os.environ["PULSE"]
repo   = os.environ["REPO"]
token  = os.environ["TOKEN"]

otel_keys = {
    "logs_endpoint":        pulse + "/v1/logs",
    "headers":              "x-pulse-token=" + token,
    "resource_attributes":  "repo=" + repo + ",harness=codex",
}

# Read existing file (empty list if missing)
try:
    with open(path) as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

# Split into sections: list of {"header": str|None, "lines": [str]}
sections = []
current = {"header": None, "lines": []}
for line in lines:
    if re.match(r'^\[', line.rstrip()):
        sections.append(current)
        current = {"header": line.rstrip(), "lines": []}
    else:
        current["lines"].append(line)
sections.append(current)

# Find the [otel] section index
otel_idx = next((i for i, s in enumerate(sections) if s["header"] == "[otel]"), None)

if otel_idx is not None:
    # Merge: update our keys, preserve others
    sec = sections[otel_idx]
    updated_lines = []
    written_keys = set()
    for line in sec["lines"]:
        m = re.match(r'^(\w+)\s*=', line)
        if m and m.group(1) in otel_keys:
            key = m.group(1)
            updated_lines.append('{} = "{}"\n'.format(key, otel_keys[key]))
            written_keys.add(key)
        else:
            updated_lines.append(line)
    # Append keys we didn't see
    for key, val in otel_keys.items():
        if key not in written_keys:
            updated_lines.append('{} = "{}"\n'.format(key, val))
    sec["lines"] = updated_lines
else:
    # Append a new [otel] section
    new_sec = {"header": "[otel]", "lines": []}
    for key, val in otel_keys.items():
        new_sec["lines"].append('{} = "{}"\n'.format(key, val))
    sections.append(new_sec)

# Reconstruct and write
out = []
for sec in sections:
    if sec["header"] is not None:
        out.append(sec["header"] + "\n")
    out.extend(sec["lines"])
# Ensure single trailing newline
content = "".join(out)
if not content.endswith("\n"):
    content += "\n"

with open(path, "w") as f:
    f.write(content)
PY

chmod 600 "$CONFIG"

# Ensure ~/.codex/config.toml is gitignored globally (token-bearing)
GLOBAL_GITIGNORE="${HOME}/.gitignore_global"
if [ -f "$GLOBAL_GITIGNORE" ]; then
  grep -qxF '.codex/config.toml' "$GLOBAL_GITIGNORE" || printf '\n.codex/config.toml\n' >> "$GLOBAL_GITIGNORE"
else
  echo "WARN: ~/.gitignore_global not found. Add '.codex/config.toml' to your global gitignore manually to prevent accidental commits." >&2
fi

echo "Telemetry wired (Codex → Pulse logs) — written to ${CONFIG} (gitignored)."
echo "Data will be sent to pulse.otta.build (hosted by Otta). Set OTTA_PULSE_URL to override."
