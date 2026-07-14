#!/usr/bin/env bash
# license-metadata.test.sh — blocks drift from the repository's Apache-2.0 license.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."

assert_json_license() {
  local file="$1"
  local filter="$2"
  local label="$3"

  if jq -e "$filter == \"Apache-2.0\"" "$file" >/dev/null; then
    echo "  ✓ $label declares Apache-2.0"
  else
    echo "✗ FAIL: $label must declare Apache-2.0" >&2
    return 1
  fi
}

grep -q '^                                 Apache License$' "$REPO/LICENSE" || {
  echo "✗ FAIL: root LICENSE is not Apache License 2.0" >&2
  exit 1
}

assert_json_license "$REPO/.claude-plugin/plugin.json" '.license' 'Claude plugin manifest'
assert_json_license "$REPO/.codex-plugin/plugin.json" '.license' 'Codex plugin manifest'
assert_json_license "$REPO/.claude-plugin/marketplace.json" '.plugins[] | select(.name == "otta") | .license' 'Marketplace entry'

grep -Fq 'Licensed under the [Apache License 2.0](LICENSE).' "$REPO/README.md" || {
  echo "✗ FAIL: README must identify and link the Apache License 2.0" >&2
  exit 1
}

echo "✓ license metadata agrees on Apache-2.0"
