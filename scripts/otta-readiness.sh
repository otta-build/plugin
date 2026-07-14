#!/usr/bin/env bash
# otta-readiness.sh — Factory Readiness Score: 0–8 across setup dimensions.
# READ-ONLY: never writes any file. Degrades gracefully when gh/network absent.
# Usage: bash scripts/otta-readiness.sh
# Each failing probe prints ✗ and continues — no single probe aborts the script.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
score=0

pass()     { echo "  ✓ $1"; score=$((score + 1)); }
fail_dim() { echo "  ✗ $1"; }

echo "Factory Readiness Score — $(basename "$REPO_ROOT")"
echo "----------------------------------------"

# ------------------------------------------------------------------
# dim 1: base + staging resolvable (.otta.yml has both non-empty keys)
# ------------------------------------------------------------------
DIM1=false
if [ -f "$REPO_ROOT/.otta.yml" ]; then
  HAS_BASE="$(grep -cE '^base:[[:space:]]+\S' "$REPO_ROOT/.otta.yml" 2>/dev/null || true)"
  HAS_STAGING="$(grep -cE '^staging:[[:space:]]+\S' "$REPO_ROOT/.otta.yml" 2>/dev/null || true)"
  if [ "${HAS_BASE:-0}" -ge 1 ] && [ "${HAS_STAGING:-0}" -ge 1 ]; then
    DIM1=true
  fi
fi
if [ "$DIM1" = true ]; then
  pass "base/staging configured in .otta.yml"
else
  fail_dim "base/staging not configured (missing .otta.yml or base/staging keys)"
fi

# ------------------------------------------------------------------
# dim 2: a .github/workflows/*.yml exists
# ------------------------------------------------------------------
DIM2=false
if find "$REPO_ROOT/.github/workflows" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null \
   | grep -q .; then
  DIM2=true
fi
if [ "$DIM2" = true ]; then
  pass ".github/workflows/*.yml present"
else
  fail_dim "no .github/workflows/*.yml — gate CI check can never go green"
fi

# ------------------------------------------------------------------
# dim 3: branch protection on base (gh api, best-effort — ✗ on any failure)
# ------------------------------------------------------------------
DIM3=false
if command -v gh > /dev/null 2>&1; then
  BASE_BRANCH="$(grep -E '^base:' "$REPO_ROOT/.otta.yml" 2>/dev/null \
    | head -1 | sed 's/^base:[[:space:]]*//' || true)"
  BASE_BRANCH="${BASE_BRANCH:-main}"
  REPO_SLUG="$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  if [ -n "$REPO_SLUG" ] && [ -n "$BASE_BRANCH" ]; then
    if gh api "repos/$REPO_SLUG/branches/$BASE_BRANCH/protection" > /dev/null 2>&1; then
      DIM3=true
    fi
  fi
fi
if [ "$DIM3" = true ]; then
  pass "branch protection enabled on base"
else
  fail_dim "branch protection: not detected (gh unavailable, no remote, or not configured)"
fi

# ------------------------------------------------------------------
# dim 4: gate hook installed (.husky or .githooks pre-push referencing otta)
# ------------------------------------------------------------------
DIM4=false
for hookdir in "$REPO_ROOT/.husky" "$REPO_ROOT/.githooks"; do
  if [ -f "$hookdir/pre-push" ] && grep -qi "otta" "$hookdir/pre-push" 2>/dev/null; then
    DIM4=true; break
  fi
done
if [ "$DIM4" = true ]; then
  pass "local gate hook installed (pre-push references otta)"
else
  fail_dim "gate hook not installed (no .husky/pre-push or .githooks/pre-push referencing otta)"
fi

# ------------------------------------------------------------------
# dim 5: Pulse connected (server-verified; file existence is not authority)
# ------------------------------------------------------------------
if [ -f "$REPO_ROOT/.otta/pulse.env" ]; then
  STATUS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/otta-pulse-status.sh"
  set +e
  PULSE_STATUS="$(OTTA_PULSE_ENV_FILE="$REPO_ROOT/.otta/pulse.env" bash "$STATUS_SCRIPT" 2>&1)"
  PULSE_STATUS_RC=$?
  set -e
  if [ "$PULSE_STATUS_RC" -eq 0 ]; then
    pass "Pulse connected (repository access + checks:write verified)"
  elif [ "$PULSE_STATUS_RC" -eq 3 ] || [ "$PULSE_STATUS_RC" -eq 4 ]; then
    fail_dim "$PULSE_STATUS"
  else
    fail_dim "Pulse verification unavailable — .otta/pulse.env exists, but connection is not verified"
  fi
else
  fail_dim "Pulse not connected (no .otta/pulse.env — Pulse step needed)"
fi

# ------------------------------------------------------------------
# dim 6: sandbox configured (.claude/settings.json has sandbox key)
# ------------------------------------------------------------------
DIM6=false
if [ -f "$REPO_ROOT/.claude/settings.json" ] \
   && grep -q "sandbox" "$REPO_ROOT/.claude/settings.json" 2>/dev/null; then
  DIM6=true
fi
if [ "$DIM6" = true ]; then
  pass "sandbox credentials configured (.claude/settings.json)"
else
  fail_dim "sandbox not configured (no .claude/settings.json with sandbox key)"
fi

# ------------------------------------------------------------------
# dim 7: telemetry on (.claude/settings.local.json has OTEL_ key)
# ------------------------------------------------------------------
DIM7=false
if [ -f "$REPO_ROOT/.claude/settings.local.json" ] \
   && grep -q "OTEL_" "$REPO_ROOT/.claude/settings.local.json" 2>/dev/null; then
  DIM7=true
fi
if [ "$DIM7" = true ]; then
  pass "telemetry on (.claude/settings.local.json has OTEL_ vars)"
else
  fail_dim "telemetry not on (no .claude/settings.local.json with OTEL_ — step 9 needed)"
fi

# ------------------------------------------------------------------
# dim 8: .otta.yml present
# ------------------------------------------------------------------
if [ -f "$REPO_ROOT/.otta.yml" ]; then
  pass ".otta.yml present (delivery context configured)"
else
  fail_dim ".otta.yml not found — run /otta:setup to configure delivery context"
fi

# ------------------------------------------------------------------
# Deploy workflow mutation safety (additive; not part of the legacy 0-8 score)
# ------------------------------------------------------------------
DEPLOY_READINESS_RC=0
READINESS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$REPO_ROOT/.otta.yml" ]; then
  # shellcheck source=scripts/otta-deploy-config.sh
  . "$READINESS_SCRIPT_DIR/otta-deploy-config.sh"
  if DEPLOY_ENVIRONMENTS="$(list_deploy_environments "$REPO_ROOT/.otta.yml" 2>/dev/null)"; then
    DEPLOY_WORKFLOW_COUNT=0
    for DEPLOY_ENVIRONMENT in $DEPLOY_ENVIRONMENTS; do
      DEPLOY_EXECUTOR="$(deploy_config_value "$REPO_ROOT/.otta.yml" "$DEPLOY_ENVIRONMENT" executor)"
      if [ "$DEPLOY_EXECUTOR" = github-workflow ]; then
        DEPLOY_WORKFLOW_COUNT=$((DEPLOY_WORKFLOW_COUNT + 1))
        echo "Deploy workflow safety — environment=$DEPLOY_ENVIRONMENT"
        if ! bash "$READINESS_SCRIPT_DIR/otta-deploy-readiness.sh" \
          --otta-yml "$REPO_ROOT/.otta.yml" --environment "$DEPLOY_ENVIRONMENT"; then
          DEPLOY_READINESS_RC=1
        fi
      fi
    done
    if [ "$DEPLOY_WORKFLOW_COUNT" -eq 0 ]; then
      echo "Deploy workflow safety: not applicable (no github-workflow environment)"
    fi
  else
    echo "FAIL deploy configuration — malformed or unresolved environment"
    DEPLOY_READINESS_RC=1
  fi
else
  echo "Deploy workflow safety: not applicable (no .otta.yml)"
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo "----------------------------------------"
if [ "$score" -ge 8 ]; then
  echo "Your repo: $score/8 production-ready 🟢"
else
  MARKER="🔴"
  [ "$score" -ge 5 ] && MARKER="🟡" || true
  echo "Your repo: $score/8 production-ready $MARKER → setup unlocks → 8/8 🟢"
fi

exit "$DEPLOY_READINESS_RC"
