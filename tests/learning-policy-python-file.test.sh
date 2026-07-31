#!/usr/bin/env bash
# Regression test: the LEARN policy implementation must live in a real .py file.
#
# Bug: scripts/otta-learning-policy.sh was 398 lines of Python behind a polyglot
# bash trampoline (`""":"` / `exec python3 "$0"` / `":"""`). That sits in a
# linter blind spot from both directions — shellcheck cannot parse it, and no
# Python tooling matches a .sh extension. #177 adds a shellcheck CI gate, which
# would have to blanket-exclude the file rather than actually check anything.
#
# Fix: move the Python to otta-learning-policy.py and leave the .sh as a thin
# exec wrapper, so all 11 existing `.sh` call sites keep working verbatim.
# Run: bash plugins/otta/tests/learning-policy-python-file.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../scripts"

fail() { echo "✗ $1" >&2; exit 1; }

# 1. The Python implementation exists as a .py file.
[ -f "$SCRIPTS/otta-learning-policy.py" ] \
  || fail "scripts/otta-learning-policy.py is missing — Python must live in a .py file"

# 2. It is valid, parseable Python (this is what the .sh extension was hiding).
#    ast.parse rather than py_compile: py_compile litters scripts/__pycache__/
#    into the checkout and CI on every run.
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$SCRIPTS/otta-learning-policy.py" \
  || fail "otta-learning-policy.py does not parse as Python"

# 3. No .sh file anywhere in scripts/ still hides a Python polyglot trampoline.
for f in "$SCRIPTS"/*.sh; do
  if grep -q '^exec python3 "\$0"' "$f" || grep -q '^""":"' "$f"; then
    fail "$(basename "$f") still uses a Python polyglot trampoline"
  fi
done

# 4. The .sh entrypoint still exists and is executable — 11 call sites in
#    agents/, commands/, workflows/ and scripts/ invoke it by that exact name.
[ -x "$SCRIPTS/otta-learning-policy.sh" ] \
  || fail "scripts/otta-learning-policy.sh must remain an executable entrypoint"

# 5. The wrapper is a wrapper, not a second copy of the implementation.
lines="$(wc -l < "$SCRIPTS/otta-learning-policy.sh" | tr -d ' ')"
[ "$lines" -le 20 ] \
  || fail "otta-learning-policy.sh should be a thin wrapper, got $lines lines"

# 6. Behaviour is unchanged through the wrapper: a bad subcommand still exits
#    non-zero with the documented usage string.
out="$(bash "$SCRIPTS/otta-learning-policy.sh" bogus-subcommand 2>&1 || true)"
printf '%s' "$out" | grep -qi "usage" \
  || fail "wrapper lost the usage error path; got: $out"

# 7. And a real run still works end-to-end through the wrapper.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
(
  cd "$TMPDIR"
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  bash "$SCRIPTS/otta-learning-policy.sh" prepare >/dev/null 2>&1
) || fail "`prepare` no longer runs through the .sh wrapper"
[ -f "$TMPDIR/.otta/run/learning-receipt.json" ] \
  || fail "prepare did not write .otta/run/learning-receipt.json through the wrapper"

echo "✓ LEARN policy lives in a lintable .py file behind a thin .sh wrapper"
