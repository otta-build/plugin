#!/usr/bin/env bash
# otta-bypass-detect.test.sh — tests for scripts/otta-bypass-detect.sh (issue #202)
# Covers all 6 acceptance criteria for the gate-bypass detector:
#   AC1: no-PR commit by a non-allowlisted author -> issue opened, names SHA/author/subject
#   AC2: commit with an associated PR -> no issue
#   AC3: allowlisted author -> no issue; allowlist is a parameter (repo-configurable)
#   AC4: re-run on the same SHA -> no duplicate issue (search-before-create)
#   AC5: covered by otta-bypass-detect-setup.test.sh (opt-in installer)
#   AC6: PR association uses the commits/{sha}/pulls API, not the commit message
#
# Self-contained: sources the script's functions and mocks `git`/`gh` as shell
# functions (no live GitHub call). Pattern matches tests/otta-deploy-verify.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-bypass-detect.sh"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✓ $1"; pass=$((pass+1)); else echo "  ✗ $1 — expected [$2], got [$3]"; fail=$((fail+1)); fi; }

[ -f "$SCRIPT" ] || { echo "✗ script not found: $SCRIPT" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SCRIPT"

echo "otta-bypass-detect:"

REPO="acme/widgets"

# ---------------------------------------------------------------------------
# AC1: no PR, no allowlist match -> an issue is opened naming SHA/author/subject
# ---------------------------------------------------------------------------
CALLS="$(mktemp)"
gh() {
  printf 'gh %s\n' "$*" >> "$CALLS"
  case "$*" in
    "api repos/$REPO/commits/deadbeef1234567890000000000000000000000/pulls --jq length")
      echo "0" ;;
    "issue list --repo $REPO --state all --search"*)
      echo "" ;;
    "issue create --repo $REPO"*) echo "https://github.com/$REPO/issues/9" ;;
  esac
}
: > "$CALLS"
_process_commit "$REPO" "deadbeef1234567890000000000000000000000" "Mallory" "sneak in a fix" "github-actions[bot]" >/dev/null
check "AC1: opens an issue for an unassociated, non-allowlisted commit" 1 "$(grep -c '^gh issue create' "$CALLS")"

# The created issue's title+body span multiple lines in the call log (the
# body is a heredoc), so check the whole captured call rather than one line.
CREATE_ARGS="$(cat "$CALLS")"
case "$CREATE_ARGS" in *"deadbeef1234567890000000000000000000000"*) check "AC1: issue references the SHA" yes yes ;; *) check "AC1: issue references the SHA" yes no ;; esac
case "$CREATE_ARGS" in *"Mallory"*) check "AC1: issue references the author" yes yes ;; *) check "AC1: issue references the author" yes no ;; esac
case "$CREATE_ARGS" in *"sneak in a fix"*) check "AC1: issue references the commit subject" yes yes ;; *) check "AC1: issue references the commit subject" yes no ;; esac
unset -f gh

# ---------------------------------------------------------------------------
# AC2: commit has an associated PR -> no issue opened
# ---------------------------------------------------------------------------
CALLS="$(mktemp)"
gh() {
  printf 'gh %s\n' "$*" >> "$CALLS"
  case "$*" in
    "api repos/$REPO/commits/cafef00d1234567890000000000000000000000/pulls --jq length")
      echo "1" ;;
  esac
}
: > "$CALLS"
_process_commit "$REPO" "cafef00d1234567890000000000000000000000" "Alice" "add feature" "" >/dev/null
check "AC2: commit with a PR opens no issue" 0 "$(grep -c '^gh issue create' "$CALLS")"
check "AC2: commit with a PR never queries issue search" 0 "$(grep -c '^gh issue list' "$CALLS")"
unset -f gh

# ---------------------------------------------------------------------------
# AC3: allowlisted author -> no issue; allowlist is caller-supplied (per-repo)
# ---------------------------------------------------------------------------
CALLS="$(mktemp)"
gh() { printf 'gh %s\n' "$*" >> "$CALLS"; }
: > "$CALLS"
_process_commit "$REPO" "0000000111122223333444455556666777788889" "release-bot[bot]" "chore: release v1.2.3" "release-bot[bot],github-actions[bot]" >/dev/null
check "AC3: allowlisted author opens no issue" 0 "$(grep -c '^gh issue create' "$CALLS")"
check "AC3: allowlisted author never calls the pulls API (short-circuits first)" 0 "$(grep -c '^gh api' "$CALLS")"

# Allowlist is a parameter, not a hardcoded name: a DIFFERENT allowlisted actor
# for a hypothetical other repo also short-circuits.
: > "$CALLS"
_process_commit "$REPO" "1111222233334444555566667777888899990000" "deploy-svc" "version bump" "deploy-svc" >/dev/null
check "AC3: allowlist is configurable to an arbitrary actor name" 0 "$(grep -c '^gh api' "$CALLS")"
unset -f gh

# ---------------------------------------------------------------------------
# AC4: re-running on the same SHA does not open a duplicate issue
# ---------------------------------------------------------------------------
CALLS="$(mktemp)"
gh() {
  printf 'gh %s\n' "$*" >> "$CALLS"
  case "$*" in
    "api repos/$REPO/commits/aaaa111122223333444455556666777788889999/pulls --jq length")
      echo "0" ;;
    "issue list --repo $REPO --state all --search"*)
      echo "77" ;;   # an issue for this SHA already exists
  esac
}
: > "$CALLS"
_process_commit "$REPO" "aaaa111122223333444455556666777788889999" "Mallory" "sneak in another fix" "" >/dev/null
check "AC4: existing bypass issue for the SHA is searched before create" 1 "$(grep -c '^gh issue list' "$CALLS")"
check "AC4: existing bypass issue for the SHA -> no duplicate create" 0 "$(grep -c '^gh issue create' "$CALLS")"
unset -f gh

# ---------------------------------------------------------------------------
# AC6: PR association comes from the commits/{sha}/pulls API, not the message.
# A commit message that LOOKS merged (contains "(#123)") must still get an
# issue if the pulls API says there is no associated PR.
# ---------------------------------------------------------------------------
CALLS="$(mktemp)"
gh() {
  printf 'gh %s\n' "$*" >> "$CALLS"
  case "$*" in
    "api repos/$REPO/commits/bbbb111122223333444455556666777788889999/pulls --jq length")
      echo "0" ;;
    "issue list --repo $REPO --state all --search"*) echo "" ;;
    "issue create --repo $REPO"*) echo "https://github.com/$REPO/issues/10" ;;
  esac
}
: > "$CALLS"
_process_commit "$REPO" "bbbb111122223333444455556666777788889999" "Trent" "fix: patch the widget (#123)" "" >/dev/null
check "AC6: a commit-message PR reference does not suppress the issue (API is authoritative)" 1 "$(grep -c '^gh issue create' "$CALLS")"
case "$(grep '^gh api' "$CALLS")" in *"commits/bbbb111122223333444455556666777788889999/pulls"*) check "AC6: association was checked via commits/{sha}/pulls" yes yes ;; *) check "AC6: association was checked via commits/{sha}/pulls" yes no ;; esac
unset -f gh

# ---------------------------------------------------------------------------
# Review finding #2: the commits/{sha}/pulls lookup itself can fail (e.g. a
# 403 from missing `pull-requests: read`). That must NOT be treated as "no
# PR" — it must be its own outcome: no issue opened (a control that cries
# wolf on every push gets uninstalled), a clear stderr message naming the
# SHA, and a non-zero exit so the workflow run goes red and a human notices.
# ---------------------------------------------------------------------------
CALLS="$(mktemp)"
gh() {
  printf 'gh %s\n' "$*" >> "$CALLS"
  case "$*" in
    "api repos/$REPO/commits/ffff111122223333444455556666777788889999/pulls --jq length")
      echo "HTTP 403: Resource not accessible by integration" >&2
      return 1 ;;
  esac
}
: > "$CALLS"
ERR_OUT="$(_process_commit "$REPO" "ffff111122223333444455556666777788889999" "Trent" "some change" "" 2>&1 1>/dev/null)"
PROC_RC=$?
check "could-not-determine: _process_commit exits non-zero" 1 "$([ "$PROC_RC" -ne 0 ] && echo 1 || echo 0)"
check "could-not-determine: opens no issue" 0 "$(grep -c '^gh issue create' "$CALLS")"
check "could-not-determine: never reaches dedup search" 0 "$(grep -c '^gh issue list' "$CALLS")"
case "$ERR_OUT" in *"ffff111122223333444455556666777788889999"*) check "could-not-determine: stderr names the SHA" yes yes ;; *) check "could-not-determine: stderr names the SHA" yes no ;; esac
unset -f gh

# ---------------------------------------------------------------------------
# _commits_for_push: multi-commit, force-push, and new-branch (before=zero) handling
# ---------------------------------------------------------------------------
ZERO="0000000000000000000000000000000000000000"

# New branch push (before = all-zeros): only the head commit is checked.
# Call shape: git log -1 --format=<fmt> <after-sha>  ($4 is the ref).
git() {
  case "$1 $2" in
    "log -1") echo "$4	Grace	initial import" ;;
  esac
}
OUT="$(_commits_for_push "$ZERO" "9999888877776666555544443333222211110000")"
check "before=zero: only the head commit is reported" 1 "$(printf '%s\n' "$OUT" | grep -c .)"
case "$OUT" in *"9999888877776666555544443333222211110000"*) check "before=zero: reported commit is the head SHA" yes yes ;; *) check "before=zero: reported commit is the head SHA" yes no ;; esac
unset -f git

# Normal multi-commit push: rev-list resolves, git log lists both commits oldest-first.
git() {
  case "$1" in
    rev-list) return 0 ;;
    log) printf 'sha1\tBob\tfirst\nsha2\tBob\tsecond\n' ;;
  esac
}
OUT="$(_commits_for_push "before1" "after1")"
check "multi-commit push: both commits are reported" 2 "$(printf '%s\n' "$OUT" | grep -c .)"
unset -f git

# ---------------------------------------------------------------------------
# Review finding #3: `--no-merges` filtered out the exact commit this feature
# exists to catch — `git merge feature && git push origin main` bypasses PRs
# entirely and produces a merge commit. The API check already handles
# GitHub's own "Merge pull request" commits correctly (they ARE associated),
# so filtering merges out before the API even sees them was wrong.
# ---------------------------------------------------------------------------
LOG_CALLS="$(mktemp)"
git() {
  case "$1" in
    rev-list) return 0 ;;
    log) printf '%s\n' "$*" >> "$LOG_CALLS"; echo "mergesha	Mallory	Merge branch 'feature' into main" ;;
  esac
}
: > "$LOG_CALLS"
_commits_for_push "before2" "after2" >/dev/null
case "$(cat "$LOG_CALLS")" in *"--no-merges"*) check "merge commits: git log is NOT filtered with --no-merges" yes no ;; *) check "merge commits: git log is NOT filtered with --no-merges" yes yes ;; esac
unset -f git

# A local `git merge && push` merge commit with no associated PR must still
# get an issue — this is the canonical bypass.
CALLS="$(mktemp)"
gh() {
  printf 'gh %s\n' "$*" >> "$CALLS"
  case "$*" in
    "api repos/$REPO/commits/mergenopr1111222233334444555566667777888/pulls --jq length") echo "0" ;;
    "issue list --repo $REPO --state all --search"*) echo "" ;;
    "issue create --repo $REPO"*) echo "https://github.com/$REPO/issues/11" ;;
  esac
}
: > "$CALLS"
_process_commit "$REPO" "mergenopr1111222233334444555566667777888" "Mallory" "Merge branch 'feature' into main" "" >/dev/null
check "merge commit with no PR: opens an issue" 1 "$(grep -c '^gh issue create' "$CALLS")"
unset -f gh

# A merge commit that DOES have an associated PR (e.g. GitHub's own "Merge
# pull request #N" commit) must not.
CALLS="$(mktemp)"
gh() {
  printf 'gh %s\n' "$*" >> "$CALLS"
  case "$*" in
    "api repos/$REPO/commits/mergewithpr222233334444555566667777888/pulls --jq length") echo "1" ;;
  esac
}
: > "$CALLS"
_process_commit "$REPO" "mergewithpr222233334444555566667777888" "Alice" "Merge pull request #9 from acme/widgets/feature" "" >/dev/null
check "merge commit with a PR: opens no issue" 0 "$(grep -c '^gh issue create' "$CALLS")"
unset -f gh

# Force-push where `before` is no longer reachable: falls back to the head
# commit alone and warns, instead of crashing the whole workflow.
git() {
  case "$1" in
    rev-list) return 1 ;;
    log) echo "afterforce	Carol	force pushed history" ;;
  esac
}
FORCE_OUT="$(_commits_for_push "gone" "afterforce" 2>/tmp/otta-bypass-force-stderr)"
check "force-push: falls back to reporting only the head commit" 1 "$(printf '%s\n' "$FORCE_OUT" | grep -c .)"
case "$FORCE_OUT" in *afterforce*) check "force-push: reported commit is the new head" yes yes ;; *) check "force-push: reported commit is the new head" yes no ;; esac
grep -qi "force" /tmp/otta-bypass-force-stderr && check "force-push: warns on stderr" yes yes || check "force-push: warns on stderr" yes no
rm -f /tmp/otta-bypass-force-stderr
unset -f git

echo ""
if [ "$fail" -eq 0 ]; then
  echo "✓ otta-bypass-detect: all $pass checks passed"
else
  echo "✗ otta-bypass-detect: $fail check(s) failed ($pass passed)"
  exit 1
fi
