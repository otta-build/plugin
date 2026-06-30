#!/usr/bin/env bash
# seed-pr-body.sh <issue-number> [--force]
#
# Self-contained: fetches a GitHub issue, extracts its acceptance-criteria
# checkboxes, and seeds .pr-body.md with the canonical Otta acceptance block.
# No external engine / private repo required — just `gh` + `jq`.
set -euo pipefail

ISSUE="${1:-}"
FORCE="${2:-}"
if [ -z "$ISSUE" ]; then
  echo "usage: seed-pr-body.sh <issue-number> [--force]" >&2
  exit 2
fi

command -v gh >/dev/null || { echo "ERROR: gh CLI not found. Install: https://cli.github.com" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not found. Install jq." >&2; exit 1; }

OUT=".pr-body.md"
if [ -f "$OUT" ] && [ "$FORCE" != "--force" ]; then
  echo "$OUT already exists. Re-run with --force to overwrite." >&2
  exit 1
fi

# Current repo — works in any checkout, no config file needed.
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
JSON="$(gh issue view "$ISSUE" --repo "$REPO" --json number,title,body)"
TITLE="$(echo "$JSON" | jq -r .title)"
BODY="$(echo "$JSON" | jq -r .body)"

# Extract AC checkboxes (lines beginning with "- [ ]" or "- [x]").
# Layer tags ([data-layer], [ui-layer], [e2e]) are preserved as part of the line text.
AC_BLOCK="$(echo "$BODY" | grep -E '^\s*- \[[ xX]\]' || true)"
[ -z "$AC_BLOCK" ] && AC_BLOCK="- [ ] AC1: <!-- fill in from issue #${ISSUE} -->"

# If any layer-tagged ACs are present, add a layer key note for builders.
LAYER_NOTE=""
if echo "$AC_BLOCK" | grep -qiE '\[(data-layer|ui-layer|e2e)\]'; then
  LAYER_NOTE="
<!-- AC layer key:
     [data-layer] — schema + mutations + unit tests, no UI required
     [ui-layer]   — requires working page/component visible in the app
     [e2e]        — requires full user flow: link → action → observable result
     Evidence required: [data-layer] → unit test OK; [ui-layer]/[e2e] → preview URL or e2e tool. -->"
fi

cat > "$OUT" <<EOF
## Summary

<!-- 1-3 bullets: what this PR does (issue: ${TITLE}) -->

\`\`\`acceptance
GIVEN <!-- starting state / context -->
WHEN  <!-- the action or trigger -->
THEN  <!-- observable, verifiable outcome -->

${AC_BLOCK}
${LAYER_NOTE}
## Out of scope
- <!-- things explicitly NOT built in this issue -->

## Verification
- unit: <!-- test file / command, or "n/a — reason" -->
- e2e: <!-- e2e spec / flow, or "n/a — reason" -->
- preview: <!-- deployed-env observation, or "n/a — no preview env" -->
\`\`\`

## Acceptance

<!-- After merge, echo each AC with evidence:
- [x] AC1: <restated> — <evidence: test name / preview obs>
-->

<!-- idea origin (where this work came from) — Pulse reads this for the idea→version chain.
     Replace with the real origin if different: intercom:..., sentry:..., linear:... -->
idea_ref: issue:#${ISSUE}

<!-- If no test is practical, add: [test-impractical: <reason>] -->

Fixes #${ISSUE}
EOF

echo "✓ seeded $OUT from #${ISSUE} ($(echo "$AC_BLOCK" | grep -c '^\s*- \[' || echo 0) AC checkbox(es))"
echo "  repo: $REPO"
