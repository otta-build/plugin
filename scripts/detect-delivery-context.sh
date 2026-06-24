#!/usr/bin/env bash
# detect-delivery-context.sh [--output <file>] — inspect the current repo and
# emit a pre-filled .otta.yml conforming to the #64 DeliveryContext schema.
#
# Schema (all fields):
#   base:    string  — default branch
#   staging: string | null — staging branch name, null if absent
#   deploy:
#     mode:   "auto-on-merge" | "tag" | "manual" | "none"
#     target: string — "tauri", "vercel", "coolify", etc., or "none"
#     package_paths: string[]
#   ci:
#     required: boolean  — false (placeholder; fill in from branch-protection)
#   pulse:
#     installed: boolean
#
# Detected CI workflows + path filters are printed to stdout as informational
# comments (not written into the schema'd YAML).
#
# Output goes to stdout by default, or to --output <file>.
# Exit 0 always — missing data produces schema-valid placeholder values.
set -euo pipefail

OUTPUT_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Base branch
# ---------------------------------------------------------------------------
BASE=""
if command -v gh >/dev/null 2>&1; then
  BASE="$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)"
fi
if [ -z "$BASE" ]; then
  # Fallback: check common names that actually exist locally
  for b in main master develop trunk; do
    if git rev-parse --verify "$b" >/dev/null 2>&1; then
      BASE="$b"; break
    fi
  done
fi
BASE="${BASE:-main}"

# ---------------------------------------------------------------------------
# 2. Staging branch → null if absent
# ---------------------------------------------------------------------------
STAGING_VALUE="null"
if git rev-parse --verify "staging" >/dev/null 2>&1 || \
   git rev-parse --verify "origin/staging" >/dev/null 2>&1; then
  STAGING_VALUE='"staging"'
fi

# ---------------------------------------------------------------------------
# 3. CI workflows — collect names + paths for informational stdout hint only
# ---------------------------------------------------------------------------
WORKFLOW_DIR=".github/workflows"
WORKFLOW_HINTS=""

if [ -d "$WORKFLOW_DIR" ]; then
  while IFS= read -r -d '' wf; do
    wf_name="$(basename "$wf" .yml)"
    wf_name="${wf_name%.yaml}"
    paths_block="$(awk '
      /^[[:space:]]+paths:/{in_paths=1; next}
      in_paths && /^[[:space:]]+-/{
        gsub(/^[[:space:]]+-[[:space:]]*/,""); gsub(/^['"'"'"]|['"'"'"]$/,""); print
      }
      in_paths && !/^[[:space:]]+-/{in_paths=0}
    ' "$wf")"

    if [ -n "$paths_block" ]; then
      hint_paths="$(echo "$paths_block" | tr '\n' ',' | sed 's/,$//')"
      WORKFLOW_HINTS="${WORKFLOW_HINTS}#   ${wf_name}: [${hint_paths}]"$'\n'
    else
      WORKFLOW_HINTS="${WORKFLOW_HINTS}#   ${wf_name}: (no paths filter)"$'\n'
    fi
  done < <(find "$WORKFLOW_DIR" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null | sort -z)
fi

# ---------------------------------------------------------------------------
# 4. Deploy signal → #64 enum: auto-on-merge | tag | manual | none
# ---------------------------------------------------------------------------
DEPLOY_MODE="none"
DEPLOY_TARGET="none"
DEPLOY_PACKAGE_PATHS="[]"

if [ -d "$WORKFLOW_DIR" ]; then
  all_wf_content="$(cat "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml 2>/dev/null || true)"

  if echo "$all_wf_content" | grep -q "tauri-action\|tauri build"; then
    # Tauri ships on a git tag → "tag"
    DEPLOY_MODE="tag"
    DEPLOY_TARGET="tauri"
  elif echo "$all_wf_content" | grep -q "vercel\|VERCEL"; then
    # Vercel deploys automatically on merge → "auto-on-merge"
    DEPLOY_MODE="auto-on-merge"
    DEPLOY_TARGET="vercel"
  elif echo "$all_wf_content" | grep -q "coolify\|COOLIFY"; then
    # Coolify auto-deploys on push → "auto-on-merge"
    DEPLOY_MODE="auto-on-merge"
    DEPLOY_TARGET="coolify"
  fi

  # Detect package paths from working-directory directives
  pkg_paths="$(grep -rh 'working-directory:' "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml 2>/dev/null \
    | awk '{gsub(/^[[:space:]]*working-directory:[[:space:]]*/,""); print}' \
    | sort -u || true)"
  if [ -n "$pkg_paths" ]; then
    pkg_yaml=""
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      pkg_yaml="${pkg_yaml}      - \"${p}\""$'\n'
    done <<< "$pkg_paths"
    DEPLOY_PACKAGE_PATHS="$(printf '\n%s' "$pkg_yaml")"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Build informational header (printed above the YAML)
# ---------------------------------------------------------------------------
HINTS_HEADER=""
if [ -n "$WORKFLOW_HINTS" ]; then
  HINTS_HEADER="# Detected CI workflows (informational — not part of the schema):"$'\n'"${WORKFLOW_HINTS}"
fi

# ---------------------------------------------------------------------------
# 6. Emit schema-conformant YAML
# ---------------------------------------------------------------------------
{
  if [ -n "$HINTS_HEADER" ]; then printf '%s\n' "$HINTS_HEADER"; fi
  printf '%s\n' "# .otta.yml — auto-generated by detect-delivery-context.sh"
  printf '%s\n' "# Review and fill in fields marked FILL IN, then run /otta:setup to finish."
  printf 'base: "%s"\n' "$BASE"
  printf 'staging: %s\n' "$STAGING_VALUE"
  printf '\n'
  printf '%s\n' "deploy:"
  printf '  mode: "%s"    # auto-on-merge | tag | manual | none — FILL IN if wrong\n' "$DEPLOY_MODE"
  printf '  target: "%s"   # vercel | coolify | tauri | none — FILL IN\n' "$DEPLOY_TARGET"
  printf '  package_paths: %s\n' "$DEPLOY_PACKAGE_PATHS"
  printf '\n'
  printf '%s\n' "ci:"
  printf '%s\n' "  required: false  # set to true once branch-protection CI checks are configured"
  printf '\n'
  printf '%s\n' "pulse:"
  printf '%s\n' "  installed: false  # set to true after running pulse-install.sh"
} | if [ -n "$OUTPUT_FILE" ]; then
  cat > "$OUTPUT_FILE"
  echo "wrote $OUTPUT_FILE" >&2
else
  cat
fi
