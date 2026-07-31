#!/usr/bin/env bash
# otta-learning-policy.sh — stable entrypoint for the LEARN policy resolver.
#
# The implementation is Python and lives in otta-learning-policy.py. It used to
# sit in this file behind a polyglot bash trampoline, which hid 398 lines of
# Python from every linter in both directions — shellcheck cannot parse it, and
# no Python tooling matches a .sh extension.
#
# This wrapper stays because eleven call sites in agents/, commands/,
# workflows/ and scripts/ invoke `otta-learning-policy.sh` by name. It passes
# the script directory as argv[1], exactly as the old trampoline did.
set -euo pipefail
HERE="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
exec python3 "$HERE/otta-learning-policy.py" "$HERE" "$@"
