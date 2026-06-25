#!/usr/bin/env bash
# setup-wizard.test.sh — structural regression for the /otta:setup guided wizard (issue #26).
# Asserts setup.md contains:
#   - spine intro (gates guarantee quality / Pulse learns / DORA+cost)
#   - per-step teach-blurb (pain→benefit) + AskUserQuestion directive
#   - write-summary step
#   - telemetry data-destination disclosure (pulse.otta.build) — v0.13.1 regression guard
#   - docs/why-otta-setup.md exists
# Run: bash tests/setup-wizard.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$HERE/../commands/setup.md"
DOCS="$HERE/../docs/why-otta-setup.md"
fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$SETUP" ] || fail "setup.md not found at $SETUP"

# ---------------------------------------------------------------------------
# AC1: Spine intro — gates guarantee quality, Pulse learns, DORA+cost
# ---------------------------------------------------------------------------
grep -qi "gate" "$SETUP" || fail "AC1: spine intro missing 'gate' (quality guarantee)"
grep -qi "pulse" "$SETUP" || fail "AC1: spine intro missing 'Pulse'"
grep -qi "DORA\|dora" "$SETUP" || fail "AC1: spine intro missing DORA mention"
grep -qi "why Otta\|why-otta\|gated.*quality\|quality.*gate\|AI agents code\|AI agent" "$SETUP" \
  || fail "AC1: spine intro section not present (look for 'why Otta' or 'gated quality' framing)"

# ---------------------------------------------------------------------------
# AC2: Teach-blurbs — each decision step must state pain AND benefit
# Base/staging step
grep -qi "branch flow\|route PRs\|auto-target\|staging.*promot\|promot.*staging" "$SETUP" \
  || fail "AC2: base/staging teach-blurb missing (branch flow / PR routing benefit)"
# deploy.auto step
grep -qi "safety level\|accidental.*prod\|never accidental\|pipeline drive" "$SETUP" \
  || fail "AC2: deploy.auto teach-blurb missing (safety level / no accidental prod)"
# ci.required step
grep -qi "production.ready\|production-ready\|agents can.t merge red\|authoritative" "$SETUP" \
  || fail "AC2: ci.required teach-blurb missing (authoritative gate / agents can't merge red)"
# Pulse App step
grep -qi "amnesia\|DORA\|escape.*detect\|LEARN.*data\|data.*LEARN" "$SETUP" \
  || fail "AC2: Pulse App teach-blurb missing (amnesia / DORA / LEARN data)"
# sandbox.credentials step
grep -qi "pipeline runs.*Bash\|Bash.*near.*secret\|can.t read.*aws\|exfiltrat" "$SETUP" \
  || fail "AC2: sandbox.credentials teach-blurb missing (Bash near secrets)"
# CI workflow step
grep -qi "no CI\|CI.*never.*green\|gate.*real\|gate never green" "$SETUP" \
  || fail "AC2: CI workflow teach-blurb missing (no CI → gate never green)"
# local gate hook step
grep -qi "pre-push\|pre.push.*gate\|slow loop\|fewer red PR" "$SETUP" \
  || fail "AC2: local gate hook teach-blurb missing (pre-push / slow loop)"
# telemetry step
grep -qi "can.t improve.*can.t see\|per.tool.*timing\|per.stage.*timing\|\$/PR\|tokens.*per" "$SETUP" \
  || fail "AC2: telemetry teach-blurb missing (can't improve what you can't see / per-tool timing)"

# ---------------------------------------------------------------------------
# AC3: AskUserQuestion directives — at least one per decision step
# Check the keyword appears enough times (one per distinct step)
AQU_COUNT="$(grep -c "AskUserQuestion" "$SETUP" || true)"
[ "$AQU_COUNT" -ge 8 ] \
  || fail "AC3: expected AskUserQuestion directive for each of 8+ decision steps, found $AQU_COUNT"

# Each named step must have its own AskUserQuestion call
for label in "base" "deploy.auto\|deploy auto\|auto.*policy\|pipeline.*drive" \
             "ci.required\|ci required" "sandbox\|credential" \
             "Pulse\|pulse-install" "CI workflow\|ci-test\|scaffold" \
             "local.*hook\|hook.*local\|pre-push" "Telemetry\|telemetry"; do
  grep -qi "$label" "$SETUP" || fail "AC3: decision step not present in setup.md: $label"
done

# The file must instruct the agent to call AskUserQuestion (not just mention it as a UI concept)
grep -q "AskUserQuestion" "$SETUP" || fail "AC3: AskUserQuestion never referenced in setup.md"

# Recommended/default option is FIRST per step — check at least the base step and telemetry step
grep -qi "recommended\|default.*first\|first.*option\|first.*chip\|safe default" "$SETUP" \
  || fail "AC3: setup.md must note that the recommended/safe option is first in each AskUserQuestion call"

# ---------------------------------------------------------------------------
# AC4: Write-summary step exists, the optional write blocks come AFTER it,
#      and a payoff line follows.
# ---------------------------------------------------------------------------
grep -qi "confirm\|summary.*write\|write.*summary\|here.*will write\|here is what\|about to write" "$SETUP" \
  || fail "AC4: write-summary / confirm step missing"
grep -qi "payoff\|gated.*quality\|quality.*gate.*memory\|self-improving factory\|measured.*factory\|factory.*learn" "$SETUP" \
  || fail "AC4: payoff line missing at end (gated quality + memory + visibility + safety)"

# Line-order guard: the sandbox settings.json write block must appear AFTER the
# write-summary heading — so optional writes follow confirmation, not precede it.
SUMMARY_LINE="$(grep -n "confirm.*proceed\|write.*confirm\|here.*will write\|Write-summary\|write-summary\|Confirm setup\|Confirm before" "$SETUP" | head -1 | cut -d: -f1)"
SETTINGS_WRITE_LINE="$(grep -n '"sandbox"' "$SETUP" | head -1 | cut -d: -f1)"
[ -n "$SUMMARY_LINE" ] || fail "AC4(order): could not locate write-summary heading line"
[ -n "$SETTINGS_WRITE_LINE" ] || fail "AC4(order): could not locate settings.json write block"
[ "$SETTINGS_WRITE_LINE" -gt "$SUMMARY_LINE" ] \
  || fail "AC4(order): sandbox settings.json write (line $SETTINGS_WRITE_LINE) must appear after write-summary (line $SUMMARY_LINE)"

# ---------------------------------------------------------------------------
# AC5 (regression guard): telemetry data-destination disclosure from v0.13.1
# The exact hosted Pulse URL must still appear, and the process-level scope note
# ---------------------------------------------------------------------------
grep -q "pulse\.otta\.build" "$SETUP" \
  || fail "AC5: v0.13.1 telemetry destination disclosure missing — 'pulse.otta.build' must appear"
grep -qi "Otta receives\|otta.*receives\|data.*destination\|destination.*data" "$SETUP" \
  || fail "AC5: disclosure that Otta receives the telemetry must be present"
grep -qi "process.level\|process level\|every.*Claude Code.*session\|every session" "$SETUP" \
  || fail "AC5: process-level scope disclosure (every CC session emits) must be present"

# ---------------------------------------------------------------------------
# AC6: docs/why-otta-setup.md exists and contains value content
# ---------------------------------------------------------------------------
[ -f "$DOCS" ] || fail "AC6: docs/why-otta-setup.md not found at $DOCS"
grep -qi "pain\|benefit\|gate\|DORA" "$DOCS" \
  || fail "AC6: docs/why-otta-setup.md must contain pain/benefit value copy"
# setup.md must link to docs/why-otta-setup.md
grep -q "why-otta-setup" "$SETUP" \
  || fail "AC6: setup.md must link to docs/why-otta-setup.md"

echo "✓ setup-wizard: all checks passed (AC1–AC6)"
