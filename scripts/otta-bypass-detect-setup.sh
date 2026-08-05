#!/usr/bin/env bash
# otta-bypass-detect-setup.sh [--dry-run] [--runner <value>]
#                              [--default-branch <name>] [--allowlist <csv>]
# Installs .github/workflows/otta-bypass-detect.yml — on every push to the
# default branch, resolves each pushed commit to an associated pull request
# via the commits/{sha}/pulls API and opens an issue for any commit that has
# none (otta-build/plugin#202). Idempotent: skips if the file already exists.
# --dry-run prints without writing.
#
# Opt-in only: nothing here runs unless a repo installs this workflow.
#
# The runner is INFERRED from the repo's existing workflows rather than
# assumed, and the default branch is resolved from repository metadata —
# same reasoning as scripts/otta-release-setup.sh's --runner inference
# (otta-build/pulse#153): a hardcoded assumption fails silently on a repo
# that doesn't match it. Both can be overridden with a flag.
#
# The generated workflow embeds scripts/otta-bypass-detect.sh verbatim inside
# its `run:` step, between sentinel comments, so the installed file is
# self-contained (no scripts/ dependency in the consuming repo) while staying
# byte-identical to the script this repo unit-tests directly.
set -euo pipefail

DRY_RUN=0
RUNNER=""
DEFAULT_BRANCH=""
ALLOWLIST="github-actions[bot]"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --runner)
      [ "$#" -ge 2 ] || { echo "ERROR: --runner needs a value" >&2; exit 2; }
      RUNNER="$2"; shift 2 ;;
    --default-branch)
      [ "$#" -ge 2 ] || { echo "ERROR: --default-branch needs a value" >&2; exit 2; }
      DEFAULT_BRANCH="$2"; shift 2 ;;
    --allowlist)
      [ "$#" -ge 2 ] || { echo "ERROR: --allowlist needs a value" >&2; exit 2; }
      ALLOWLIST="$2"; shift 2 ;;
    *) echo "usage: otta-bypass-detect-setup.sh [--dry-run] [--runner <value>] [--default-branch <name>] [--allowlist <csv>]" >&2; exit 2 ;;
  esac
done

WORKFLOW_DIR=".github/workflows"
WORKFLOW_FILE="${WORKFLOW_DIR}/otta-bypass-detect.yml"
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT_SCRIPT="${SETUP_DIR}/otta-bypass-detect.sh"

[ -f "$DETECT_SCRIPT" ] || { echo "ERROR: ${DETECT_SCRIPT} not found — reinstall the otta plugin." >&2; exit 1; }

# Most common `runs-on:` value across the repo's other workflows — see
# scripts/otta-release-setup.sh's detect_runner for the original rationale.
detect_runner() {
  local vals
  [ -d "$WORKFLOW_DIR" ] || return 1
  vals="$(
    grep -hE '^[[:space:]]*runs-on:[[:space:]]*\S' \
      "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml 2>/dev/null \
      | sed -E 's/^[[:space:]]*runs-on:[[:space:]]*//; s/[[:space:]]+$//' \
      | grep -vF '${{' \
      || true
  )"
  [ -n "$vals" ] || return 1
  printf '%s\n' "$vals" | sort | uniq -c | sort -rn | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//'
}

RUNNER_SOURCE="--runner flag"
if [ -z "$RUNNER" ]; then
  if RUNNER="$(detect_runner)" && [ -n "$RUNNER" ]; then
    RUNNER_SOURCE="inferred from existing workflows in $WORKFLOW_DIR"
  else
    RUNNER="ubuntu-latest"
    RUNNER_SOURCE="default — nothing could be inferred from $WORKFLOW_DIR"
  fi
fi

BRANCH_SOURCE="--default-branch flag"
if [ -z "$DEFAULT_BRANCH" ]; then
  if command -v gh >/dev/null 2>&1 \
    && DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)" \
    && [ -n "$DEFAULT_BRANCH" ]; then
    BRANCH_SOURCE="inferred from GitHub repository metadata"
  elif DEFAULT_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" \
    && [ -n "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
    BRANCH_SOURCE="inferred from origin/HEAD"
  elif DEFAULT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    && [ -n "$DEFAULT_BRANCH" ]; then
    BRANCH_SOURCE="current branch fallback — no repository default could be resolved"
  else
    DEFAULT_BRANCH="main"
    BRANCH_SOURCE="default — no repository default or current branch could be resolved"
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "Would write: ${WORKFLOW_FILE}"
  echo "  runner: ${RUNNER}  (${RUNNER_SOURCE})"
  echo "  default branch: ${DEFAULT_BRANCH}  (${BRANCH_SOURCE})"
  echo "  allowlist: ${ALLOWLIST}"
  exit 0
fi

if [ -f "$WORKFLOW_FILE" ]; then
  echo "✓ ${WORKFLOW_FILE} already exists — skipped (idempotent)."
  exit 0
fi

mkdir -p "$WORKFLOW_DIR"

{
  printf 'name: otta-bypass-detect\n'
  printf '# Detects commits pushed directly to the default branch that never\n'
  printf '# became a pull request (otta-build/plugin#202). Opt-in — installed by\n'
  printf '# otta-bypass-detect-setup.sh. Edit `env.ALLOWLIST` below to change which\n'
  printf '# actors (e.g. release bots) are exempt for this repo.\n'
  printf 'on:\n'
  printf '  push:\n'
  printf '    branches: [%s]\n' "$DEFAULT_BRANCH"
  printf 'permissions:\n'
  printf '  issues: write\n'
  printf '  contents: read\n'
  printf '  pull-requests: read   # needed for GET commits/{sha}/pulls\n'
  printf 'jobs:\n'
  printf '  detect:\n'
  printf '    runs-on: %s\n' "$RUNNER"
  printf '    env:\n'
  printf '      ALLOWLIST: "%s"\n' "$ALLOWLIST"
  printf '      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n'
  printf '      GH_REPO: ${{ github.repository }}\n'
  printf '      BEFORE_SHA: ${{ github.event.before }}\n'
  printf '      AFTER_SHA: ${{ github.event.after }}\n'
  printf '    steps:\n'
  printf '      - uses: actions/checkout@v4\n'
  printf '        with:\n'
  printf '          fetch-depth: 0   # need full history to diff before..after (incl. force-push fallback)\n'
  printf '      - name: Detect gate-bypassing commits\n'
  printf '        run: |\n'
  printf '          # --- otta-bypass-detect.sh begin ---\n'
  sed -E 's/^/          /' "$DETECT_SCRIPT"
  printf '          # --- otta-bypass-detect.sh end ---\n'
} > "$WORKFLOW_FILE"

echo "✓ Installed ${WORKFLOW_FILE} — opens an issue for any commit on ${DEFAULT_BRANCH} with no associated PR."
echo "  runner: ${RUNNER}  (${RUNNER_SOURCE})"
echo "  default branch: ${DEFAULT_BRANCH}  (${BRANCH_SOURCE})"
echo "  allowlist: ${ALLOWLIST}  — edit env.ALLOWLIST in the file to change it"
