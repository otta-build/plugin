#!/usr/bin/env bash
# Regression: the generated release workflow must use a runner the target repo
# can actually schedule on.
#
# Bug: otta-release-setup.sh hardcoded `runs-on: ubuntu-latest`. On a repo that
# cannot use GitHub-hosted runners — e.g. otta-build/pulse, a private repo in a
# free org with hosted minutes exhausted, whose workflows all use
# [self-hosted, linux] — the generated job never picks up a runner. The repo is
# never tagged and nothing reports an error.
#
# That silence is the expensive part: setup prints "✓ Installed", the file
# exists, the repo looks configured, and tagging simply never happens. Downstream
# deploy_tag never fires and DORA deployment frequency reads zero rather than
# "not instrumented" (otta-build/pulse#153).
# Run: bash tests/release-setup-runner.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/otta-release-setup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# A repo whose existing workflows declare $2 as their runs-on value.
mk_repo() { # $1 = name, $2 = runs-on value (empty = no workflows at all)
  local d="$TMP/$1"
  mkdir -p "$d"
  if [ -n "${2:-}" ]; then
    mkdir -p "$d/.github/workflows"
    printf 'name: ci\non: [push]\njobs:\n  test:\n    runs-on: %s\n    steps:\n      - run: true\n' \
      "$2" > "$d/.github/workflows/ci.yml"
    printf 'name: deploy\non: [push]\njobs:\n  go:\n    runs-on: %s\n    steps:\n      - run: true\n' \
      "$2" > "$d/.github/workflows/deploy.yml"
  fi
  printf '%s' "$d"
}

generated_runs_on() { # $1 = repo dir
  grep -E '^[[:space:]]*runs-on:' "$1/.github/workflows/otta-release.yml" \
    | head -1 | sed -E 's/^[[:space:]]*runs-on:[[:space:]]*//; s/[[:space:]]+$//'
}

# 1. Self-hosted repo → generated workflow must match, not ubuntu-latest.
R="$(mk_repo selfhosted '[self-hosted, linux]')"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "setup failed on a self-hosted repo"
got="$(generated_runs_on "$R")"
[ "$got" = "[self-hosted, linux]" ] \
  || fail "expected inherited '[self-hosted, linux]', got '$got'"

# 2. Hosted repo → ubuntu-latest, as before.
R="$(mk_repo hosted 'ubuntu-latest')"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "setup failed on a hosted repo"
got="$(generated_runs_on "$R")"
[ "$got" = "ubuntu-latest" ] || fail "expected 'ubuntu-latest', got '$got'"

# 3. No workflows to learn from → fall back to ubuntu-latest, and SAY so.
#    A silent assumption here is the whole bug.
R="$(mk_repo bare '')"
out="$( cd "$R" && bash "$SCRIPT" 2>&1 )" || fail "setup failed on a repo with no workflows"
got="$(generated_runs_on "$R")"
[ "$got" = "ubuntu-latest" ] || fail "expected fallback 'ubuntu-latest', got '$got'"
printf '%s' "$out" | grep -qi 'ubuntu-latest' \
  || fail "fallback must report the assumed runner on stdout; got: $out"

# 4. --runner overrides inference.
R="$(mk_repo override 'ubuntu-latest')"
( cd "$R" && bash "$SCRIPT" --runner 'macos-14' >/dev/null 2>&1 ) || fail "--runner failed"
got="$(generated_runs_on "$R")"
[ "$got" = "macos-14" ] || fail "--runner should win over inference, got '$got'"

# 5. A matrix expression must NOT be copied verbatim — ${{ matrix.os }} does not
#    resolve in the generated file, which has no matrix. Fall back instead.
R="$(mk_repo matrix '${{ matrix.os }}')"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "setup failed on a matrix repo"
got="$(generated_runs_on "$R")"
[ "$got" = "ubuntu-latest" ] || fail "matrix expression must not be inherited, got '$got'"
grep -q 'matrix' "$R/.github/workflows/otta-release.yml" \
  && fail "generated workflow must not contain an unresolvable matrix reference"

# 6. --dry-run prints without writing, and reflects the detected runner.
R="$(mk_repo dry '[self-hosted, linux]')"
out="$( cd "$R" && bash "$SCRIPT" --dry-run 2>&1 )" || fail "--dry-run failed"
[ -f "$R/.github/workflows/otta-release.yml" ] && fail "--dry-run must not write the workflow"
printf '%s' "$out" | grep -qF '[self-hosted, linux]' \
  || fail "--dry-run output must show the detected runner; got: $out"

# 7. Idempotent skip still wins over everything.
R="$(mk_repo idem 'ubuntu-latest')"
mkdir -p "$R/.github/workflows"
printf 'existing\n' > "$R/.github/workflows/otta-release.yml"
( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "idempotent path failed"
[ "$(cat "$R/.github/workflows/otta-release.yml")" = "existing" ] \
  || fail "existing otta-release.yml must not be overwritten"

echo "✓ release-setup infers the runner, honours --runner, and never assumes silently"
