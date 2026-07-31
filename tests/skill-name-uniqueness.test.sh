#!/usr/bin/env bash
# Regression test: every skill must declare a unique `name:` in its frontmatter.
#
# Bug: skills/otta-dev.md and skills/otta-dev/SKILL.md BOTH declared
# `name: otta-dev` with different descriptions — one a reference doc for
# builders/reviewers, one the workflow trigger. Two skills claiming one name is
# ambiguous for anything resolving a skill by name.
#
# This guards the general invariant, so a future collision fails here too.
# Run: bash plugins/otta/tests/skill-name-uniqueness.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="$HERE/../skills"

fail() { echo "✗ $1" >&2; exit 1; }

[ -d "$SKILLS" ] || fail "skills/ directory is missing"

# Collect "<name> <file>" for every markdown file that declares frontmatter.
pairs="$(
  find "$SKILLS" -name '*.md' -type f | sort | while IFS= read -r f; do
    # `name:` from the leading frontmatter block only (first 10 lines).
    n="$(head -10 "$f" | grep -m1 -E '^name:[[:space:]]*\S' | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]+$//' || true)"
    [ -n "$n" ] && printf '%s\t%s\n' "$n" "${f#"$SKILLS"/}"
  done
)"

[ -n "$pairs" ] || fail "no skill declared a name: — the parser is broken, not the skills"

dupes="$(printf '%s\n' "$pairs" | cut -f1 | sort | uniq -d)"
if [ -n "$dupes" ]; then
  echo "✗ duplicate skill name(s):" >&2
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    echo "  name: $d" >&2
    printf '%s\n' "$pairs" | awk -F'\t' -v d="$d" '$1==d {print "    " $2}' >&2
  done <<EOF
$dupes
EOF
  exit 1
fi

count="$(printf '%s\n' "$pairs" | wc -l | tr -d ' ')"
echo "✓ all $count skill names are unique"
