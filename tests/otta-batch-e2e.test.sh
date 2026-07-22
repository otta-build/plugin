#!/usr/bin/env bash
# REAL end-to-end test of the concurrency infrastructure /otta:batch depends on:
# many lanes each doing REAL `git worktree add` off a REAL bare remote, under the
# real mkdir lock, with real per-lane branches, real ledger writes, real teardown,
# and real edge cases. (The otta-batch.mjs fan-out itself needs the Workflow
# runtime and is proven separately by a live run; this covers everything a bash
# CI can execute for real.)
# Run: bash tests/otta-batch-e2e.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT_SCRIPT="$HERE/../scripts/otta-worktree.sh"
LEDGER_SCRIPT="$HERE/../scripts/ledger-append.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "✗ $1" >&2; exit 1; }

# --- real repo: bare origin + working clone with one commit on main ---
ORIGIN="$TMP/origin.git"; git init -q --bare "$ORIGIN"
WORK="$TMP/work"; git clone -q "$ORIGIN" "$WORK"
cd "$WORK"; git config user.email t@t.t; git config user.name t
echo "base" > base.txt; git add base.txt; git commit -q -m init; git push -q origin HEAD:main
export OTTA_WORKTREE_DIR="$TMP/wts"
export OTTA_LEDGER_DIR="$TMP/ledger"

wt_count() { find "$TMP/wts" -maxdepth 1 -type d -name "*-$1" 2>/dev/null | wc -l | tr -d ' '; }

# === 1. REAL 16-lane concurrent fan-out: each lane creates its worktree AND
#        commits a distinct file to its own branch — proves true isolation. ===
pids=""
for n in $(seq 1 16); do
  (
    cd "$WORK"
    wt="$(bash "$WT_SCRIPT" "$n" main 2>/dev/null)" || exit 1
    cd "$wt"
    echo "lane-$n" > "lane-$n.txt"
    git add "lane-$n.txt"
    git commit -q -m "lane $n work"
    # each lane also appends its verdict to the shared ledger
    OTTA_NO_CAPTURE=1 bash "$LEDGER_SCRIPT" --source qa --event loop_verdict \
      --score 1 --feedback "lane $n ok" --project "acme/web" >/dev/null 2>&1
  ) &
  pids="$pids $!"
done
ok=0; for p in $pids; do wait "$p" && ok=$((ok+1)); done
[ "$ok" = "16" ] || fail "only $ok/16 real lanes completed"

# Isolation: each branch otta/<n> must contain ONLY its own lane file (+ base),
# never another lane's file. This is the core batch guarantee.
for n in $(seq 1 16); do
  files="$(git -C "$WORK" ls-tree --name-only "otta/$n" 2>/dev/null | sort | tr '\n' ' ')"
  [ "$files" = "base.txt lane-$n.txt " ] || fail "branch otta/$n leaked cross-lane files: [$files]"
done

# Ledger: 16 concurrent appends → 16 intact JSON lines (no interleave).
LF="$TMP/ledger/acme-web.jsonl"
[ "$(wc -l < "$LF" | tr -d ' ')" = "16" ] || fail "ledger: expected 16 lines, got $(wc -l < "$LF")"
while IFS= read -r line; do printf '%s' "$line" | jq -e . >/dev/null 2>&1 || fail "corrupt ledger line"; done < "$LF"
echo "  ✓ 16 real lanes: isolated branches + intact ledger"

# === 2. EDGE: duplicate issue → idempotent reuse, not a second worktree. ===
before="$(wt_count 1)"
( cd "$WORK" && bash "$WT_SCRIPT" 1 main >/dev/null 2>&1 )
[ "$(wt_count 1)" = "$before" ] || fail "duplicate issue 1 created a second worktree"
echo "  ✓ duplicate issue reuses its worktree (idempotent)"

# === 3. EDGE: worktree path pre-occupied by a non-empty non-worktree dir →
#        must REFUSE (never clobber user files). ===
mkdir -p "$TMP/wts/occupied"
# derive the exact path this issue would use, then pre-fill it with a stray file
slug="$(cd "$WORK" && git config --get remote.origin.url | sed -E 's#.*/##; s/\.git$//')"
occ="$TMP/wts/${slug}-99"; mkdir -p "$occ"; echo "user data" > "$occ/precious.txt"
if ( cd "$WORK" && bash "$WT_SCRIPT" 99 main >/dev/null 2>&1 ); then
  fail "should refuse to create worktree over a non-empty non-worktree dir"
fi
[ -f "$occ/precious.txt" ] || fail "user file was clobbered"
echo "  ✓ refuses to clobber a non-empty pre-existing path"

# === 4. EDGE: one lane fails (bad base ref) while others succeed — failure is
#        isolated, the good lanes still produce worktrees. ===
pids=""; goodok=0
for spec in "201:main" "202:no-such-base" "203:main"; do
  n="${spec%%:*}"; base="${spec##*:}"
  ( cd "$WORK" && bash "$WT_SCRIPT" "$n" "$base" >/dev/null 2>&1 ) &
  pids="$pids $!"
done
i=0; for p in $pids; do i=$((i+1)); wait "$p" && goodok=$((goodok+1)); done
[ "$(wt_count 201)" = "1" ] || fail "good lane 201 did not produce a worktree"
[ "$(wt_count 203)" = "1" ] || fail "good lane 203 did not produce a worktree"
echo "  ✓ a failing lane does not take down its siblings"

# === 5. EDGE: teardown. --remove clears one; --prune 0 GCs the rest. ===
( cd "$WORK" && bash "$WT_SCRIPT" --remove 1 >/dev/null 2>&1 )
# --remove retains an empty tombstone dir for Stop hooks; the .git pointer is gone
[ -e "$TMP/wts/${slug}-1/.git" ] && fail "--remove left the worktree registered"
( cd "$WORK" && bash "$WT_SCRIPT" --prune 0 >/dev/null 2>&1 )
live="$(git -C "$WORK" worktree list | grep -c "$TMP/wts" || true)"
[ "$live" = "0" ] || fail "--prune 0 left $live registered worktrees"
echo "  ✓ --remove + --prune 0 tear down all lanes"

echo "✓ otta-batch e2e: 16-lane isolation, dedup, clobber-refusal, failure-isolation, teardown"
