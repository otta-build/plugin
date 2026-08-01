#!/usr/bin/env bash
# Regression test: don't install the merge=ours driver in repos that have
# deliberately gitignored .pr-body.md.
#
# Bug: install-merge-ours.sh unconditionally appends `.pr-body.md merge=ours`
# to .gitattributes, and seed-pr-body.sh calls it on every seed. The driver
# exists to stop merge-train conflicts on a TRACKED .pr-body.md. In a repo that
# untracked and gitignored the file (otta-build/dev#78), the entry is dead
# config — and appending it dirties a tracked file on every seed, so unrelated
# PRs pick up a spurious one-line diff unless a human notices and reverts it.
# That happened during otta-build/dev#81.
#
# The signal is "gitignored", not "untracked". At /otta:setup time the body
# usually doesn't exist yet, and setup.md documents the driver as always
# installed — so merely-absent must still install it. Only an explicit
# .gitignore entry means the repo opted into the untracked-body model.
# Run: bash plugins/otta/tests/merge-ours-skips-ignored.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/install-merge-ours.sh"
SEED="$HERE/../scripts/seed-pr-body.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "✗ $1" >&2; exit 1; }

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git config user.email t@t.t
    git config user.name t
    printf '* text=auto eol=lf\n' > .gitattributes
    git add .gitattributes
    git commit -qm seed
  )
}

attrs_has_driver() { grep -qF '.pr-body.md merge=ours' "$1/.gitattributes"; }

# 1. Repo that gitignored .pr-body.md → driver must NOT be installed, and
#    .gitattributes must be left byte-identical.
IGN="$TMPDIR/ignored"
make_repo "$IGN"
(
  cd "$IGN"
  printf '.pr-body.md\n' > .gitignore
  git add .gitignore && git commit -qm "ignore pr-body"
)
before="$(cat "$IGN/.gitattributes")"
( cd "$IGN" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "install-merge-ours.sh should exit 0 when skipping"
after="$(cat "$IGN/.gitattributes")"
attrs_has_driver "$IGN" && fail "driver installed in a repo that gitignored .pr-body.md"
[ "$before" = "$after" ] || fail ".gitattributes was modified in a repo that gitignored .pr-body.md"

# 2. It must say why it skipped — a silent no-op is indistinguishable from a bug.
msg="$( cd "$IGN" && bash "$SCRIPT" 2>&1 || true )"
printf '%s' "$msg" | grep -qi "ignor" \
  || fail "skip must explain itself (mention the file is gitignored); got: $msg"

# 3. Repo where .pr-body.md is merely ABSENT (not ignored) → still installs.
#    This is the /otta:setup case; setup.md documents the driver as always
#    written, so absence must not be read as opting out.
ABS="$TMPDIR/absent"
make_repo "$ABS"
( cd "$ABS" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "install failed in a repo with no .pr-body.md"
attrs_has_driver "$ABS" || fail "driver must still install when .pr-body.md is merely absent"

# 4. Repo with a TRACKED .pr-body.md → still installs (unchanged behaviour).
TRK="$TMPDIR/tracked"
make_repo "$TRK"
(
  cd "$TRK"
  printf 'body\n' > .pr-body.md
  git add .pr-body.md && git commit -qm "track pr-body"
)
( cd "$TRK" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "install failed in a repo tracking .pr-body.md"
attrs_has_driver "$TRK" || fail "driver must install when .pr-body.md is tracked"

# 5. End-to-end through seed-pr-body.sh, which is where the dirty diff actually
#    appeared. Stub `gh`/`jq` so no network is involved; we only care that the
#    seed run leaves .gitattributes untouched in an ignoring repo.
BIN="$TMPDIR/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/demo" ;;
  *"issue view"*) printf '{"number":1,"title":"demo","body":"- [ ] AC1: thing"}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"
before="$(cat "$IGN/.gitattributes")"
( cd "$IGN" && PATH="$BIN:$PATH" bash "$SEED" 1 --force >/dev/null 2>&1 ) \
  || fail "seed-pr-body.sh failed in a repo that gitignores .pr-body.md"
[ "$(cat "$IGN/.gitattributes")" = "$before" ] \
  || fail "seed-pr-body.sh dirtied .gitattributes in a repo that gitignores .pr-body.md"

# 6. Repo that UNTRACKED .pr-body.md without adding a .gitignore rule (#198).
#    The driver only ever acts on a TRACKED path, so the entry is dead config
#    here too — and otta-engine's own regression test fails the build on a
#    leftover `.pr-body.md merge=ours`. Gitignored was too narrow a signal.
UNTRK="$TMPDIR/untracked"
make_repo "$UNTRK"
printf 'body\n' > "$UNTRK/.pr-body.md"
before="$(cat "$UNTRK/.gitattributes")"
( cd "$UNTRK" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "install-merge-ours.sh should exit 0 when skipping an untracked body"
attrs_has_driver "$UNTRK" && fail "driver installed for an UNTRACKED .pr-body.md — the entry can never apply"
[ "$(cat "$UNTRK/.gitattributes")" = "$before" ] || fail ".gitattributes was modified for an untracked .pr-body.md"

# 7. The checks must resolve against the repo root, not the caller's cwd.
#    Run from a subdirectory of the ignoring repo: a cwd-relative check-ignore
#    looks up "sub/.pr-body.md", misses the rule, and installs the entry anyway.
mkdir -p "$IGN/sub"
before="$(cat "$IGN/.gitattributes")"
( cd "$IGN/sub" && bash "$SCRIPT" >/dev/null 2>&1 ) || fail "install-merge-ours.sh failed when run from a subdirectory"
attrs_has_driver "$IGN" && fail "driver installed when run from a subdirectory of an ignoring repo"
[ "$(cat "$IGN/.gitattributes")" = "$before" ] || fail ".gitattributes dirtied when run from a subdirectory"

echo "✓ merge=ours installs only where .pr-body.md is actually tracked-or-undecided"
