#!/usr/bin/env bash
# write-otta-contract.sh [--output <file>] [--seo-geo] [--deploy-target <target>]
#   [--deploy-project <project>] [--deploy-executor none|github-workflow]
#   [--deploy-workflow <file-or-id>] [--pulse] [--otel <endpoint>]
#
# Writes the v2 .otta.yml contract — the single per-repo interface every loop
# + Paperclip dispatch reads (OTT-36 / Autonomous Marketing Operating Plan §2).
#
# Schema (6 keys — locked; do not add extras):
#   tracker:   { kind: linear, team: <team> }  or  { kind: gh }
#   autonomy:  auto | human-gated
#   deploy:    { target, project, auto[, GitHub workflow executor fields] }
#   gates:     [pr-body-acceptance, test-coverage, review-thread]
#   telemetry: { pulse: <true|false>, otel: <endpoint|null> }
#   loops:     [dev_loop]  (+seo_geo when --seo-geo is passed)
#
# AUTONOMY DETECTION — mirrors otta-engine/src/selfloop/repo_tier.py
#   is_autonomy_eligible().  Source of truth: repo_tier.py.
#   The python3/node parse path mirrors it exactly. The grep-only fallback
#   (used only when NEITHER python3 nor node exists) is a fail-closed
#   APPROXIMATION: a valid multi-line package.json without `workspaces` may
#   resolve to human-gated instead of auto. Fail-closed (never fail-open).
#   Rule: root astro.config.{mjs,ts,js} present AND no "workspaces" key in
#   root package.json → autonomy: auto; anything else → human-gated.
#   Fails closed: missing file, malformed JSON → human-gated (never raises).
#
# TRACKER DETECTION (in priority order):
#   1. LINEAR_TEAM env var → { kind: linear, team: $LINEAR_TEAM }
#   2. .selfloop.yml `team:` line → { kind: linear, team: <value> }
#   3. fallback → { kind: gh }
#
# Exit 0 always; missing data produces safe placeholder values (FILL IN comments).
set -euo pipefail

OUTPUT_FILE=""
SEO_GEO=false
DEPLOY_TARGET="null"
DEPLOY_PROJECT="null"
DEPLOY_AUTO="human-approve"
DEPLOY_EXECUTOR="none"
DEPLOY_WORKFLOW=""
DEPLOY_REF="main"
DEPLOY_SHA_INPUT="commit_sha"
DEPLOY_PROVIDER="none"
DEPLOY_VERIFY="sha-match"
DEPLOY_HEALTH_URL=""
DEPLOY_HEALTH_COMMIT_FIELD="commit"
DEPLOY_DEFAULT_ENVIRONMENT=""
DEPLOY_STAGING_WORKFLOW=""
DEPLOY_PRODUCTION_WORKFLOW=""
DEPLOY_STAGING_HEALTH_URL=""
DEPLOY_PRODUCTION_HEALTH_URL=""
ALLOW_PRODUCTION=false
PULSE=false
OTEL_ENDPOINT="null"
LEARN_ENABLED=false
LEARN_EXPIRY_DAYS=180
LEARN_CADENCE="weekly"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)              OUTPUT_FILE="$2"; shift 2 ;;
    --seo-geo)             SEO_GEO=true; shift ;;
    --deploy-target)       DEPLOY_TARGET="$2"; shift 2 ;;
    --deploy-project)      DEPLOY_PROJECT="$2"; shift 2 ;;
    --deploy-auto)         DEPLOY_AUTO="$2"; shift 2 ;;
    --deploy-executor)     DEPLOY_EXECUTOR="$2"; shift 2 ;;
    --deploy-workflow)     DEPLOY_WORKFLOW="$2"; shift 2 ;;
    --deploy-ref)          DEPLOY_REF="$2"; shift 2 ;;
    --deploy-sha-input)    DEPLOY_SHA_INPUT="$2"; shift 2 ;;
    --deploy-provider)     DEPLOY_PROVIDER="$2"; shift 2 ;;
    --deploy-verify)       DEPLOY_VERIFY="$2"; shift 2 ;;
    --deploy-health-url)   DEPLOY_HEALTH_URL="$2"; shift 2 ;;
    --deploy-health-commit-field) DEPLOY_HEALTH_COMMIT_FIELD="$2"; shift 2 ;;
    --deploy-default-environment) DEPLOY_DEFAULT_ENVIRONMENT="$2"; shift 2 ;;
    --deploy-staging-workflow) DEPLOY_STAGING_WORKFLOW="$2"; shift 2 ;;
    --deploy-production-workflow) DEPLOY_PRODUCTION_WORKFLOW="$2"; shift 2 ;;
    --deploy-staging-health-url) DEPLOY_STAGING_HEALTH_URL="$2"; shift 2 ;;
    --deploy-production-health-url) DEPLOY_PRODUCTION_HEALTH_URL="$2"; shift 2 ;;
    --allow-production)    ALLOW_PRODUCTION=true; shift ;;
    --pulse)               PULSE=true; shift ;;
    --otel)                OTEL_ENDPOINT="$2"; shift 2 ;;
    --learn)               LEARN_ENABLED=true; shift ;;
    --learn-expiry-days)   LEARN_EXPIRY_DAYS="$2"; shift 2 ;;
    --learn-cadence)       LEARN_CADENCE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Validate deploy-auto value
case "$DEPLOY_AUTO" in
  human-approve|merge-on-green|merge-and-deploy) ;;
  *) echo "unknown --deploy-auto value: $DEPLOY_AUTO (must be human-approve|merge-on-green|merge-and-deploy)" >&2; exit 1 ;;
esac

if [ -n "$DEPLOY_DEFAULT_ENVIRONMENT" ]; then
  case "$DEPLOY_DEFAULT_ENVIRONMENT" in
    staging) [ -n "$DEPLOY_STAGING_WORKFLOW" ] || { echo "default staging environment requires --deploy-staging-workflow" >&2; exit 1; } ;;
    production) [ -n "$DEPLOY_PRODUCTION_WORKFLOW" ] || { echo "default production environment requires --deploy-production-workflow" >&2; exit 1; } ;;
    *) echo "unknown --deploy-default-environment value: $DEPLOY_DEFAULT_ENVIRONMENT (must be staging|production)" >&2; exit 1 ;;
  esac
  if [ -n "$DEPLOY_STAGING_WORKFLOW" ] && [ -z "$DEPLOY_STAGING_HEALTH_URL" ]; then
    echo "named staging environment requires --deploy-staging-health-url" >&2
    exit 1
  fi
  if [ -n "$DEPLOY_PRODUCTION_WORKFLOW" ] && [ -z "$DEPLOY_PRODUCTION_HEALTH_URL" ]; then
    echo "named production environment requires --deploy-production-health-url" >&2
    exit 1
  fi
elif [ -n "$DEPLOY_STAGING_WORKFLOW" ] || [ -n "$DEPLOY_PRODUCTION_WORKFLOW" ]; then
  echo "named deployment workflows require --deploy-default-environment" >&2
  exit 1
fi

case "$DEPLOY_EXECUTOR" in
  none) ;;
  github-workflow)
    [ -n "$DEPLOY_WORKFLOW" ] || {
      echo "--deploy-executor github-workflow requires --deploy-workflow" >&2
      exit 1
    }
    ;;
  *) echo "unknown --deploy-executor value: $DEPLOY_EXECUTOR (must be none|github-workflow)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 1. TRACKER — detect linear team or fall back to gh
# ---------------------------------------------------------------------------
TRACKER_KIND="gh"
TRACKER_TEAM=""

# Priority 1: LINEAR_TEAM env var
if [ -n "${LINEAR_TEAM:-}" ]; then
  TRACKER_KIND="linear"
  TRACKER_TEAM="$LINEAR_TEAM"
# Priority 2: .selfloop.yml team: field
elif [ -f ".selfloop.yml" ]; then
  _team="$(grep -m1 '^team:' .selfloop.yml 2>/dev/null | sed 's/^team:[[:space:]]*//' | tr -d '"\x27' || true)"
  if [ -n "$_team" ]; then
    TRACKER_KIND="linear"
    TRACKER_TEAM="$_team"
  fi
fi

if [ "$TRACKER_KIND" = "linear" ]; then
  TRACKER_YAML="{ kind: linear, team: $TRACKER_TEAM }"
else
  TRACKER_YAML="{ kind: gh }"
fi

# ---------------------------------------------------------------------------
# 2. AUTONOMY — mirrors repo_tier.py is_autonomy_eligible() (python3/node path
#    exact; grep-only fallback is a fail-closed approximation — see header).
#    Source of truth: otta-engine/src/selfloop/repo_tier.py
#    Rule: root astro.config.{mjs,ts,js} present AND no "workspaces" key in
#    root package.json → auto; else human-gated. Fails closed.
# ---------------------------------------------------------------------------
AUTONOMY="human-gated"

_has_root_astro=false
for ext in mjs ts js; do
  if [ -f "astro.config.$ext" ]; then
    _has_root_astro=true
    break
  fi
done

if $_has_root_astro; then
  if [ ! -f "package.json" ]; then
    # No package.json → no workspaces key possible → eligible
    AUTONOMY="auto"
  else
    # Parse package.json; fail closed on malformed JSON
    if command -v python3 >/dev/null 2>&1; then
      _has_workspaces="$(python3 -c "
import json, sys
try:
    d = json.load(open('package.json'))
    print('true' if 'workspaces' in d else 'false')
except Exception:
    print('error')
" 2>/dev/null || echo "error")"
    elif command -v node >/dev/null 2>&1; then
      _has_workspaces="$(node -e "
try {
  const d = JSON.parse(require('fs').readFileSync('package.json','utf8'));
  console.log('workspaces' in d ? 'true' : 'false');
} catch(e) { console.log('error'); }
" 2>/dev/null || echo "error")"
    else
      # Grep-based fallback: look for "workspaces" as a JSON key.
      # Fail closed: if we can't parse, treat as has-workspaces.
      if grep -q '"workspaces"' package.json 2>/dev/null; then
        _has_workspaces="true"
      else
        # Can't confirm absence without a real parser; check basic JSON validity
        # by looking for obvious non-JSON content. Fail closed on doubt.
        if grep -qE '^\s*[^{]' package.json 2>/dev/null; then
          _has_workspaces="error"
        else
          _has_workspaces="false"
        fi
      fi
    fi

    if [ "$_has_workspaces" = "false" ]; then
      AUTONOMY="auto"
    fi
    # "true" → human-gated (has workspaces)
    # "error" → human-gated (fail closed — malformed JSON)
  fi
fi

# ---------------------------------------------------------------------------
# 3. DEPLOY
# ---------------------------------------------------------------------------
if [ "$DEPLOY_TARGET" = "null" ]; then
  DEPLOY_TARGET_YAML="null  # FILL IN: cloudflare-pages | vercel | coolify | none"
else
  DEPLOY_TARGET_YAML="$DEPLOY_TARGET"
fi

if [ "$DEPLOY_PROJECT" = "null" ]; then
  DEPLOY_PROJECT_YAML="null  # FILL IN: project name on the deploy platform"
else
  DEPLOY_PROJECT_YAML="$DEPLOY_PROJECT"
fi

DEPLOY_AUTO_YAML="$DEPLOY_AUTO"
if $ALLOW_PRODUCTION; then
  ALLOW_PRODUCTION_YAML="true"
else
  ALLOW_PRODUCTION_YAML=""  # omit unless explicitly enabled
fi

# ---------------------------------------------------------------------------
# 4. GATES — always the same 3 (locked per the Autonomous Marketing Plan §2)
# ---------------------------------------------------------------------------
GATES_YAML="[pr-body-acceptance, test-coverage, review-thread]"

# ---------------------------------------------------------------------------
# 5. TELEMETRY
# ---------------------------------------------------------------------------
if $PULSE; then
  PULSE_YAML="true"
else
  PULSE_YAML="false"
fi

if [ "$OTEL_ENDPOINT" = "null" ]; then
  OTEL_YAML="null"
else
  OTEL_YAML="\"$OTEL_ENDPOINT\""
fi

# ---------------------------------------------------------------------------
# 6. LOOPS
# ---------------------------------------------------------------------------
if $SEO_GEO; then
  LOOPS_YAML="[dev_loop, seo_geo]"
else
  LOOPS_YAML="[dev_loop]"
fi

# ---------------------------------------------------------------------------
# Emit the v2 contract
# ---------------------------------------------------------------------------
{
  printf '%s\n' "# .otta.yml — v2 delivery contract (written by write-otta-contract.sh)"
  printf '%s\n' "# The single per-repo interface every loop + Paperclip dispatch reads."
  printf '%s\n' "# OTT-36 / Autonomous Marketing Operating Plan §2"
  printf '%s\n' "# Review FILL IN fields, then commit."
  printf '\n'
  printf '%s\n' 'version: "1"'
  printf 'tracker: %s\n' "$TRACKER_YAML"
  printf 'autonomy: %s\n' "$AUTONOMY"
  printf '%s\n' "deploy:"
  if [ -n "$DEPLOY_DEFAULT_ENVIRONMENT" ]; then
    printf '  default: %s\n' "$DEPLOY_DEFAULT_ENVIRONMENT"
    printf '%s\n' '  environments:'
    if [ -n "$DEPLOY_STAGING_WORKFLOW" ]; then
      printf '%s\n' '    staging:'
      printf '%s\n' '      auto: merge-and-deploy'
      printf '%s\n' '      target: staging'
      printf '%s\n' '      executor: github-workflow'
      printf '      workflow: %s\n' "$DEPLOY_STAGING_WORKFLOW"
      printf '%s\n' '      ref: staging'
      printf '      sha_input: %s\n' "$DEPLOY_SHA_INPUT"
      printf '      provider: %s\n' "$DEPLOY_PROVIDER"
      printf '      verify: %s\n' "$DEPLOY_VERIFY"
      printf '      health_url: %s\n' "$DEPLOY_STAGING_HEALTH_URL"
      printf '      health_commit_field: %s\n' "$DEPLOY_HEALTH_COMMIT_FIELD"
    fi
    if [ -n "$DEPLOY_PRODUCTION_WORKFLOW" ]; then
      printf '%s\n' '    production:'
      printf '%s\n' '      auto: human-approve'
      printf '%s\n' '      target: production'
      printf '%s\n' '      executor: github-workflow'
      printf '      workflow: %s\n' "$DEPLOY_PRODUCTION_WORKFLOW"
      printf '      ref: %s\n' "$DEPLOY_REF"
      printf '      sha_input: %s\n' "$DEPLOY_SHA_INPUT"
      printf '      provider: %s\n' "$DEPLOY_PROVIDER"
      printf '      verify: %s\n' "$DEPLOY_VERIFY"
      printf '      health_url: %s\n' "$DEPLOY_PRODUCTION_HEALTH_URL"
      printf '      health_commit_field: %s\n' "$DEPLOY_HEALTH_COMMIT_FIELD"
    fi
  else
    printf '  target:  %s\n' "$DEPLOY_TARGET_YAML"
    printf '  project: %s\n' "$DEPLOY_PROJECT_YAML"
    printf '  auto: %s\n' "$DEPLOY_AUTO_YAML"
    if [ -n "$ALLOW_PRODUCTION_YAML" ]; then
      printf '  allow_production: %s\n' "$ALLOW_PRODUCTION_YAML"
    fi
    if [ "$DEPLOY_EXECUTOR" != "none" ]; then
      printf '  executor: %s\n' "$DEPLOY_EXECUTOR"
      printf '  workflow: %s\n' "$DEPLOY_WORKFLOW"
      printf '  ref: %s\n' "$DEPLOY_REF"
      printf '  sha_input: %s\n' "$DEPLOY_SHA_INPUT"
      printf '  provider: %s\n' "$DEPLOY_PROVIDER"
      printf '  verify: %s\n' "$DEPLOY_VERIFY"
      printf '  health_url: %s\n' "$DEPLOY_HEALTH_URL"
      printf '  health_commit_field: %s\n' "$DEPLOY_HEALTH_COMMIT_FIELD"
    fi
  fi
  printf 'gates: %s\n' "$GATES_YAML"
  printf '%s\n' "telemetry:"
  printf '  pulse: %s\n' "$PULSE_YAML"
  printf '  otel:  %s\n' "$OTEL_YAML"
  printf 'loops: %s\n' "$LOOPS_YAML"
  if $LEARN_ENABLED; then
    printf '%s\n' "learn:"
    printf '  enabled: true\n'
    printf '  consult: true\n'
    printf '  capture: true\n'
    printf '  expiry_days: %s\n' "$LEARN_EXPIRY_DAYS"
    printf '  cadence: %s\n' "$LEARN_CADENCE"
  else
    printf '%s\n' "# learn: (self-learning opt-in — uncomment and set enabled: true to activate)"
    printf '%s\n' "#   enabled: false"
    printf '%s\n' "#   consult: false  # independently overridable per run"
    printf '%s\n' "#   capture: false  # independently overridable per run"
    printf '%s\n' "#   expiry_days: 180"
    printf '%s\n' "#   cadence: weekly  # or daily"
  fi
  printf '%s\n' "# models: (advanced — pin specific model IDs per task; omit to use defaults)"
  printf '%s\n' "#   builder: claude-fable-5"
  printf '%s\n' "#   reviewer: claude-fable-5"
} | if [ -n "$OUTPUT_FILE" ]; then
  cat > "$OUTPUT_FILE"
  echo "wrote $OUTPUT_FILE" >&2
else
  cat
fi
