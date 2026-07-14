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
#
# NOTE (OTT-36 v2 schema, issue #94): the v1-schema base/staging, deploy.auto,
# and ci.required steps were removed from the wizard because write-otta-contract.sh
# (the v2 .otta.yml author) does not emit those fields — see commands/setup.md
# step 2 (now "Deploy target and project", mapping --deploy-target/--deploy-project)
# and issue #94's acceptance criteria. Their teach-blurb assertions are retired
# below rather than kept as false regression signals.
#
# deploy target/project step (v2 replacement for base/staging + deploy.auto)
grep -qi "write-otta-contract\|deploy\.target\|deploy\.project" "$SETUP" \
  || fail "AC2: deploy target/project teach-blurb missing (v2 deploy fields)"
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
# AC3: AskUserQuestion directives — one per decision step, co-occurring in
#      the same section as the step's heading (not just anywhere in the file).
# ---------------------------------------------------------------------------

# Helper: assert AskUserQuestion appears in the section starting at the first
# line matching HEADING_PATTERN, ending at the next "## " or "---" line.
check_step_has_aqu() {
  local heading_pattern="$1"
  local step_name="$2"
  local start
  start="$(grep -in "$heading_pattern" "$SETUP" | head -1 | cut -d: -f1)"
  [ -n "$start" ] || fail "AC3(co-occur): step '$step_name' heading not found in setup.md"
  local found
  found="$(awk "NR==$start{p=1} NR>$start && /^## |^---/{p=0} p{print}" "$SETUP" \
           | grep -c "AskUserQuestion" || true)"
  [ "$found" -ge 1 ] \
    || fail "AC3(co-occur): step '$step_name' section has no AskUserQuestion directive — every decision step must ask via AskUserQuestion"
}

# Decision steps, each requiring a co-occurring AskUserQuestion.
# NOTE (OTT-36 v2 / issue #94): old steps 3 (deploy.auto policy) and 4
# (ci.required) were removed — write-otta-contract.sh never emitted those
# fields. Step 2 is now "Deploy target and project" (v2 --deploy-target /
# --deploy-project), replacing the old base/staging + deploy.auto steps.
check_step_has_aqu "Deploy target and project\|## 2\." "deploy target/project"
check_step_has_aqu "Onboard.*Pulse\|## 5\." "Pulse App"
check_step_has_aqu "Harden against credential\|## 6\." "sandbox.credentials"
check_step_has_aqu "Scaffold.*CI\|## 7\." "CI workflow scaffold"
check_step_has_aqu "local gate hook\|## 8\." "local gate hook"
check_step_has_aqu "Stream.*telemetry\|## 9\." "telemetry"

# Global count: ≥8 (one per decision step)
AQU_COUNT="$(grep -c "AskUserQuestion" "$SETUP" || true)"
[ "$AQU_COUNT" -ge 8 ] \
  || fail "AC3: expected AskUserQuestion directive for each of 8+ decision steps, found $AQU_COUNT"

# Recommended/safe default is FIRST in each question
grep -qi "recommended\|safe default" "$SETUP" \
  || fail "AC3: setup.md must mark the recommended/safe default option in each AskUserQuestion call"

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

# ---------------------------------------------------------------------------
# AC2/AC3 (issue #28): Four awesome-wizard features
# ---------------------------------------------------------------------------

# AC3 (meta-flex): setup.md intro + why-doc carry the proof-by-self-application line
grep -qiE "#26|AC3|proof by self.application|self.application" "$SETUP" \
  || fail "AC3(#28): setup.md missing meta-flex / proof-by-self-application line referencing #26/AC3"
grep -qiE "#26|AC3|proof by self.application|self.application" "$DOCS" \
  || fail "AC3(#28): docs/why-otta-setup.md missing meta-flex / proof-by-self-application line"

# AC2 (gate-demo AskUserQuestion co-occurrence): gate demo offered via AskUserQuestion in step 0
grep -qiE "otta-gate-demo|Watch the gate|10s demo|gate.*demo|demo.*gate" "$SETUP" \
  || fail "AC2(#28): setup.md missing gate-demo AskUserQuestion offer"
check_step_has_aqu "## 0\.\|Before we start\|Before.*start" "gate demo (step 0)"

# AC5 (readiness shown at START and END): otta-readiness referenced before Part A AND after payoff
READINESS_LINES="$(grep -n "otta-readiness" "$SETUP")"
[ -n "$READINESS_LINES" ] || fail "AC5(#28): otta-readiness.sh not referenced in setup.md at all"

PART_A_LINE="$(grep -n "## Part A" "$SETUP" | head -1 | cut -d: -f1)"
PAYOFF_LINE="$(grep -n "## 11\.\|Ready.*payoff\|the payoff" "$SETUP" | head -1 | cut -d: -f1)"
[ -n "$PART_A_LINE" ] || fail "AC5(#28): could not locate '## Part A' in setup.md"
[ -n "$PAYOFF_LINE" ] || fail "AC5(#28): could not locate payoff section in setup.md"

FIRST_READINESS_LINE="$(echo "$READINESS_LINES" | head -1 | cut -d: -f1)"
LAST_READINESS_LINE="$(echo "$READINESS_LINES" | tail -1 | cut -d: -f1)"

[ "$FIRST_READINESS_LINE" -lt "$PART_A_LINE" ] \
  || fail "AC5(#28): readiness score not shown at START (before Part A line $PART_A_LINE; first readiness ref is line $FIRST_READINESS_LINE)"
[ "$LAST_READINESS_LINE" -gt "$PAYOFF_LINE" ] \
  || fail "AC5(#28): readiness score not shown at END (after payoff line $PAYOFF_LINE; last readiness ref is line $LAST_READINESS_LINE)"

# AC6 (first-PR AskUserQuestion co-occurrence): first-PR step uses AskUserQuestion in step 13
grep -qiE "Ship your first|first.*gated PR|otta:start.*issue|first PR in" "$SETUP" \
  || fail "AC6(#28): setup.md missing first-PR AskUserQuestion at end"
check_step_has_aqu "## 13\.\|Ship your first|First PR in" "first-PR (step 13)"

# ---------------------------------------------------------------------------
# AC (issue #70a): context-file append behavior — delimiter-based, not skip
# ---------------------------------------------------------------------------
# B1b and B6 must instruct append + in-place update, not "only if absent".
grep -qi "<!-- otta:begin -->\|otta:begin\|otta:end" "$SETUP" \
  || fail "AC(#70a): setup.md B1b/B6 must mention the otta:begin/otta:end delimiter block"
grep -qi "append\|update.*in.*place\|in.*place.*update" "$SETUP" \
  || fail "AC(#70a): setup.md must instruct to append / update-in-place (not just skip existing files)"
grep -qi "update.*in.place\|idempotent.*re.run\|re.run.*idempotent\|not.*duplicat" "$SETUP" \
  || fail "AC(#70a): setup.md must describe idempotent re-run (no duplicate blocks)"

# ---------------------------------------------------------------------------
# Hosted Pulse token flow reuses pulse.env and verifies installation status.
# ---------------------------------------------------------------------------
grep -qi "pulse.env.*token\|token.*pulse.env" "$SETUP" \
  || fail "setup.md must describe hosted repo-token reuse from .otta/pulse.env"
grep -qi "installation-status\|repository access.*checks:write\|checks:write.*repository access" "$SETUP" \
  || fail "setup.md must describe hosted installation-status verification"
grep -q -- '--instructions-only' "$SETUP" \
  || fail "setup.md must show browser instructions without starting the blocking verification poll"
grep -q -- '--verify' "$SETUP" \
  || fail "setup.md must run wiring/verification only after browser consent"
INSTRUCTIONS_LINE="$(grep -n -- '--instructions-only' "$SETUP" | head -1 | cut -d: -f1)"
CONFIRM_LINE="$(grep -n -E 'confirm.*install|install.*confirm|After the user confirms' "$SETUP" | head -1 | cut -d: -f1)"
VERIFY_LINE="$(grep -n -- '--verify' "$SETUP" | head -1 | cut -d: -f1)"
[ -n "$CONFIRM_LINE" ] && [ "$INSTRUCTIONS_LINE" -lt "$CONFIRM_LINE" ] && [ "$CONFIRM_LINE" -lt "$VERIFY_LINE" ] \
  || fail "setup.md order must be instructions -> user confirmation -> blocking verification"
grep -qi "self.hosted.*secret\|secret.*self.hosted\|self.hosted.*webhook\|webhook.*self.hosted" "$SETUP" \
  || fail "AC(#70b): setup.md B5 must clarify that webhook secret is only for self-hosted instances"

# AC5 (#131): the recorded Codex adapter choice must be executed in B5, and
# the active mode-0600 config.toml must be disclosed in the write summary.
WRITE_SUMMARY_SECTION="$(sed -n '/## 10\./,/## Part B:/p' "$SETUP")"
B5_SECTION="$(sed -n '/### B5\./,/### B6\./p' "$SETUP")"
printf '%s' "$WRITE_SUMMARY_SECTION" | grep -q '\$CODEX_HOME/config.toml\|~/.codex/config.toml' \
  || fail "AC5(#131): setup write summary must include active Codex config.toml"
printf '%s' "$B5_SECTION" | grep -Fq 'otta-codex-setup.sh" --derive "$REPO"' \
  || fail "AC5(#131): B5 must run Codex --derive setup for hosted Pulse"
printf '%s' "$B5_SECTION" | grep -Fq 'OTTA_PULSE_WEBHOOK_SECRET="$WEBHOOK_SECRET"' \
  || fail "AC5(#131): B5 must pass the Codex self-hosted secret through the environment"
! printf '%s' "$B5_SECTION" | grep -Fq 'otta-codex-setup.sh" --derive "$REPO" "$WEBHOOK_SECRET"' \
  || fail "AC5(#131): B5 must not place the Codex webhook secret in argv"

echo "✓ setup-wizard: all checks passed (AC1–AC6 + #28 AC2/AC3/AC5/AC6 + #70 AC)"
