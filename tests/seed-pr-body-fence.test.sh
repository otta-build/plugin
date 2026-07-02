#!/usr/bin/env bash
# Regression test for scripts/seed-pr-body.sh's ```acceptance fence placement.
# Bug: the fence opened before GIVEN/WHEN/THEN and only closed after
# "## Out of scope" / "## Verification" (and even after a first fix attempt,
# after the AC checkbox list), so those sections — including the AC checkbox
# list itself — rendered as flat monospace text on GitHub instead of real
# markdown headers/checkboxes.
# Fix: close the fence right after GIVEN/WHEN/THEN — ONLY GIVEN/WHEN/THEN
# stays inside the fence. The AC checkbox list, Out of scope, and
# Verification are all sibling sections outside the fence. The post-merge
# section is also renamed "## Acceptance" -> "## Acceptance Evidence".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$HERE/../scripts/seed-pr-body.sh"
CHECK="$HERE/../scripts/check-pr-body.sh"

command -v jq >/dev/null || { echo "skip: jq not available"; exit 0; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "✗ $1" >&2; exit 1; }

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo '{"nameWithOwner":"acme/widgets"}'; exit 0; fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo '{"number":42,"title":"Example issue","body":"- [ ] AC1: first thing\n- [ ] AC2: second thing"}'
  exit 0
fi
exit 1
EOF
chmod +x "$TMPDIR/bin/gh"

( cd "$TMPDIR" && PATH="$TMPDIR/bin:$PATH" bash "$SEED" 42 >/dev/null )

OUT="$TMPDIR/.pr-body.md"
[ -f "$OUT" ] || fail "seed-pr-body.sh did not create .pr-body.md"

# Exactly 2 fence markers (one open, one close) — AC1: fence closes right
# after GIVEN/WHEN/THEN, before the AC checkbox list.
fence_count="$(grep -c '```' "$OUT")"
[ "$fence_count" -eq 2 ] || fail "expected exactly 2 \`\`\` fence markers, found $fence_count"

# Everything between the two fence markers must be ONLY GIVEN/WHEN/THEN —
# NOT the AC checkbox list, "## Out of scope", or "## Verification".
between="$(awk '/```/{c++; next} c==1' "$OUT")"
echo "$between" | grep -qE '^\s*- \[' && fail "the AC checkbox list is still inside the fence"
echo "$between" | grep -q '## Out of scope' && fail "'## Out of scope' is still inside the fence"
echo "$between" | grep -q '## Verification' && fail "'## Verification' is still inside the fence"
echo "$between" | grep -qE '^(GIVEN|WHEN|THEN)' || fail "GIVEN/WHEN/THEN missing from inside the fence"

# The AC checkbox list must appear AFTER the closing fence, as real markdown.
after="$(awk '/```/{c++; next} c==2' "$OUT")"
echo "$after" | grep -qE '^\s*- \[ \] AC1' || fail "AC1 checkbox is not rendered outside the fence"
echo "$after" | grep -qE '^\s*- \[ \] AC2' || fail "AC2 checkbox is not rendered outside the fence"

# Out of scope / Verification must appear AFTER the closing fence, as real ## headers.
grep -q '^## Out of scope' "$OUT" || fail "'## Out of scope' is not a top-level heading outside the fence"
grep -q '^## Verification' "$OUT" || fail "'## Verification' is not a top-level heading outside the fence"

# Post-merge section renamed to "## Acceptance Evidence".
grep -q '^## Acceptance Evidence' "$OUT" || fail "post-merge section not renamed to '## Acceptance Evidence'"
grep -qE '^## Acceptance$' "$OUT" && fail "old '## Acceptance' heading still present"

# check-pr-body.sh must still pass against the new shape.
( cd "$TMPDIR" && bash "$CHECK" ) >/dev/null || fail "check-pr-body.sh failed against the new fence shape"

echo "✓ seed-pr-body-fence: fence closes after GIVEN/WHEN/THEN, sections render outside it, heading renamed"
