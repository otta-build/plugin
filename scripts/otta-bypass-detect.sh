#!/usr/bin/env bash
# otta-bypass-detect.sh — detects commits landed on the default branch with no
# associated pull request (otta-build/plugin#202).
#
# On a free GitHub org, private repos cannot have branch protection at all, so
# the gate holds by convention only. A commit that never became a PR is also
# invisible to Pulse's escape-rate metric (it's not in that denominator).
# Prevention needs a paid plan or a public repo; this script is the detection
# half, and works on every tier.
#
# PR association is resolved authoritatively via the commits/{sha}/pulls API
# (GET /repos/{repo}/commits/{sha}/pulls) — never by parsing the commit
# message, which is spoofable and unreliable (squash-merge messages, manual
# "(#123)" text, etc.).
#
# Not installed anywhere by default: this file is inlined verbatim into a
# generated .github/workflows file by scripts/otta-bypass-detect-setup.sh, the
# opt-in installer. A repo that hasn't run that installer sees no change.
#
# The pure/gh-calling functions below are sourced and unit-tested by
# tests/otta-bypass-detect.test.sh with a mocked `git`/`gh` — no live
# GitHub call in tests. Pattern matches scripts/otta-deploy-verify.sh.
#
# Usage (when run directly, e.g. from the generated workflow):
#   GH_REPO=owner/repo BEFORE_SHA=<sha> AFTER_SHA=<sha> ALLOWLIST="bot1,bot2" \
#     bash otta-bypass-detect.sh
#   # or source it to call the individual functions in tests.

_ZERO_SHA="0000000000000000000000000000000000000000"

# Is $1 (a commit author name/login) in the comma-separated allowlist $2?
# Pure — no gh/git call. Whitespace around entries is trimmed so a
# human-edited "bot1, bot2" list works the same as "bot1,bot2".
_is_allowlisted() {
  local actor="$1" csv="$2" entry
  [ -n "$csv" ] || return 1
  IFS=',' read -ra _otta_bypass_entries <<< "$csv"
  for entry in "${_otta_bypass_entries[@]}"; do
    entry="$(printf '%s' "$entry" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -n "$entry" ] || continue
    [ "$entry" = "$actor" ] && return 0
  done
  return 1
}

# Does commit $2 in repo $1 have at least one associated pull request?
# Authoritative source: GET /repos/{repo}/commits/{sha}/pulls — length > 0.
#
# Three distinct outcomes, not two: the API call can fail (missing
# `pull-requests: read`, rate-limited, network blip) and that must never be
# read as "no PR" — silently treating an unknown as a bypass would open an
# issue on every push once the lookup starts failing (inverts AC2). Return
# 0 = has a PR, 1 = confirmed no PR, 2 = could not determine.
_commit_has_pr() {
  local repo="$1" sha="$2" count
  if count="$(gh api "repos/$repo/commits/$sha/pulls" --jq length 2>/dev/null)" \
      && [[ "$count" =~ ^[0-9]+$ ]]; then
    [ "$count" -gt 0 ]
    return
  fi
  return 2
}

# Has a bypass issue already been filed for commit $2 in repo $1? Searched by
# a stable marker in the body (not workflow-run state — the workflow will
# legitimately re-run on the same commit, e.g. a manual re-dispatch).
#
# GitHub's search index is not instantaneous, so two near-simultaneous runs
# racing on the same SHA could both search before either create lands,
# producing two issues. Low severity in practice (re-runs aren't sub-second)
# but worth knowing if a duplicate is ever seen despite this check.
_bypass_issue_exists() {
  local repo="$1" sha="$2" existing
  existing="$(gh issue list --repo "$repo" --state all \
    --search "\"Bypass-SHA: $sha\"" --json number -q '.[0].number // empty' 2>/dev/null)" || existing=""
  [ -n "$existing" ]
}

_bypass_issue_body() {
  local repo="$1" sha="$2" author="$3" subject="$4"
  cat <<EOF
A commit landed on the default branch of \`$repo\` with no associated pull request.

- **SHA:** \`$sha\`
- **Author:** $author
- **Subject:** $subject
- **Commit:** https://github.com/$repo/commit/$sha

Branch protection can't require PRs here (free-org private repo, or no
protection configured), so the gate holds by convention only — this issue
exists so a bypass is visible instead of silent.

If this is expected release automation, add \`$author\` to the \`allowlist\`
env in \`.github/workflows/otta-bypass-detect.yml\`.

<!-- Bypass-SHA: $sha -->
EOF
}

_open_bypass_issue() {
  local repo="$1" sha="$2" author="$3" subject="$4" short="${2:0:7}"
  gh issue create --repo "$repo" \
    --title "Direct push bypassed the gate: $short by $author — $sha" \
    --body "$(_bypass_issue_body "$repo" "$sha" "$author" "$subject")"
}

# Orchestrates one commit: allowlist -> PR association -> dedup -> file.
# $1=owner/repo $2=sha $3=author $4=subject $5=allowlist(csv)
_process_commit() {
  local repo="$1" sha="$2" author="$3" subject="$4" allowlist="$5" pr_rc
  if _is_allowlisted "$author" "$allowlist"; then
    echo "skip: $sha — allowlisted author '$author'"
    return 0
  fi

  _commit_has_pr "$repo" "$sha" && pr_rc=0 || pr_rc=$?
  case "$pr_rc" in
    0)
      echo "skip: $sha — has an associated PR"
      return 0
      ;;
    2)
      echo "otta-bypass-detect: ERROR — could not determine PR association for $sha (commits/{sha}/pulls lookup failed); not filing an issue blind. Check repo permissions (needs pull-requests: read) and re-run." >&2
      return 2
      ;;
  esac
  # pr_rc == 1: confirmed no PR — continue to dedup/file.

  if _bypass_issue_exists "$repo" "$sha"; then
    echo "skip: $sha — bypass issue already filed"
    return 0
  fi
  _open_bypass_issue "$repo" "$sha" "$author" "$subject"
  echo "opened: bypass issue for $sha"
}

# Echoes "sha<TAB>author<TAB>subject" per pushed commit, oldest first.
#
# Uses `git rev-list`/`git log` over the actual ref graph rather than the
# webhook payload's `commits[]` array, which GitHub caps at 20 entries — this
# way a push of any size is covered without a documented gap.
#
# Edge cases:
#   - New branch / first push to a branch (before = all-zeros): there is no
#     prior state to diff against, so only the pushed head commit is checked.
#   - Force-push where `before` is no longer reachable (history rewritten and
#     the old tip already GC'd): `git rev-list` fails to resolve the range.
#     Falls back to checking only the new head commit and warns on stderr,
#     rather than aborting the whole run.
_commits_for_push() {
  local before="$1" after="$2"
  if [ -z "$before" ] || [ "$before" = "$_ZERO_SHA" ]; then
    git log -1 --format=$'%H\t%an\t%s' "$after"
    return
  fi
  if ! git rev-list "$before..$after" >/dev/null 2>&1; then
    echo "otta-bypass-detect: WARNING — $before is unreachable (force-push rewrote history); checking only the pushed head $after." >&2
    git log -1 --format=$'%H\t%an\t%s' "$after"
    return
  fi
  # No --no-merges: a local `git merge feature && git push` produces a merge
  # commit that bypasses PRs entirely — exactly what this feature exists to
  # catch. The API check downstream already handles GitHub's own "Merge pull
  # request" commits correctly (they ARE associated, so no issue is opened);
  # filtering merges out here would drop the genuine bypass case instead.
  git log --reverse --format=$'%H\t%an\t%s' "$before..$after"
}

_run() {
  local repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
  local before="${BEFORE_SHA:-}" after="${AFTER_SHA:-}"
  local allowlist="${ALLOWLIST:-}"
  local sha author subject rc=0

  if [ -z "$repo" ]; then
    echo "otta-bypass-detect: GH_REPO/GITHUB_REPOSITORY not set" >&2
    return 2
  fi
  if [ -z "$after" ]; then
    echo "otta-bypass-detect: AFTER_SHA not set" >&2
    return 2
  fi

  while IFS=$'\t' read -r sha author subject; do
    [ -n "$sha" ] || continue
    _process_commit "$repo" "$sha" "$author" "$subject" "$allowlist" || rc=1
  done < <(_commits_for_push "$before" "$after")

  return "$rc"
}

# Only execute when run directly; sourcing exposes the functions above for
# tests without applying strict mode to the caller's shell.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  _run
fi
