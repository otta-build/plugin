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

# 8 named decision steps, each requiring a co-occurring AskUserQuestion
check_step_has_aqu "Confirm or override.*base\|## 2\." "base/staging branches"
check_step_has_aqu "Deploy automation\|## 3\." "deploy.auto policy"
check_step_has_aqu "Required CI\|## 4\." "ci.required"
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

echo "✓ setup-wizard: all checks passed (AC1–AC6 + #28 AC2/AC3/AC5/AC6)"

# ---------------------------------------------------------------------------
# Issue #70 — append-context + hosted-Pulse-no-secret
# ---------------------------------------------------------------------------

APPEND_SCRIPT="$HERE/../scripts/otta-append-context.sh"
TELEMETRY_SCRIPT="$HERE/../scripts/otta-telemetry-setup.sh"

# #70 AC1/AC2: appending to an existing file
TMPDIR70="$(mktemp -d)"
trap 'rm -rf "$TMPDIR70"' EXIT

echo "existing content" > "$TMPDIR70/CLAUDE.md"
bash "$APPEND_SCRIPT" "$TMPDIR70/CLAUDE.md" html \
  || fail "#70 AC1: otta-append-context.sh exited non-zero"
grep -q "existing content" "$TMPDIR70/CLAUDE.md" \
  || fail "#70 AC1: original content was clobbered"
grep -q "otta:begin" "$TMPDIR70/CLAUDE.md" \
  || fail "#70 AC1: otta:begin block not appended to CLAUDE.md"

echo "existing agents content" > "$TMPDIR70/AGENTS.md"
bash "$APPEND_SCRIPT" "$TMPDIR70/AGENTS.md" html \
  || fail "#70 AC2: otta-append-context.sh exited non-zero on AGENTS.md"
grep -q "existing agents content" "$TMPDIR70/AGENTS.md" \
  || fail "#70 AC2: original content clobbered in AGENTS.md"
grep -q "otta:begin" "$TMPDIR70/AGENTS.md" \
  || fail "#70 AC2: otta:begin block not appended to AGENTS.md"

# Test .cursor/rules with hash-comment delimiters
mkdir -p "$TMPDIR70/.cursor"
echo "existing cursor content" > "$TMPDIR70/.cursor/rules"
bash "$APPEND_SCRIPT" "$TMPDIR70/.cursor/rules" hash \
  || fail "#70 AC2: otta-append-context.sh exited non-zero on .cursor/rules"
grep -q "existing cursor content" "$TMPDIR70/.cursor/rules" \
  || fail "#70 AC2: original content clobbered in .cursor/rules"
grep -q "# otta:begin" "$TMPDIR70/.cursor/rules" \
  || fail "#70 AC2: # otta:begin block not appended to .cursor/rules"

# #70 AC3: idempotent — running twice keeps block once AND file is byte-stable
echo "fresh file" > "$TMPDIR70/idem.md"
bash "$APPEND_SCRIPT" "$TMPDIR70/idem.md" html          # run 1
cp "$TMPDIR70/idem.md" "$TMPDIR70/idem_after_run1.md"
bash "$APPEND_SCRIPT" "$TMPDIR70/idem.md" html          # run 2
COUNT=$(grep -c "otta:begin" "$TMPDIR70/idem.md" || true)
[ "$COUNT" -eq 1 ] \
  || fail "#70 AC3: otta:begin appears $COUNT times after two runs (expected 1)"
diff -q "$TMPDIR70/idem_after_run1.md" "$TMPDIR70/idem.md" > /dev/null 2>&1 \
  || fail "#70 AC3: file is not byte-stable between run 1 and run 2 (blank lines accumulating)"

# #70 AC4: hosted Pulse path — no auth header in curl call
MOCKDIR="$(mktemp -d)"
CURL_ARGS_FILE="$MOCKDIR/curl_args"
cat > "$MOCKDIR/curl" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$CURL_ARGS_FILE"
printf '{"token":"test-token-abc"}\n'
MOCK
chmod +x "$MOCKDIR/curl"
mkdir -p "$TMPDIR70/hosted-run/.claude"
(
  cd "$TMPDIR70/hosted-run"
  # Unset OTTA_PULSE_URL so hosted path is exercised even if env has it set
  env -u OTTA_PULSE_URL \
    PATH="$MOCKDIR:$PATH" CURL_ARGS_FILE="$CURL_ARGS_FILE" \
    bash "$TELEMETRY_SCRIPT" owner/repo \
  || true
)
if [ -f "$CURL_ARGS_FILE" ]; then
  if grep -q "\-H" "$CURL_ARGS_FILE"; then
    fail "#70 AC4: hosted Pulse call included -H header (should be headerless)"
  fi
else
  fail "#70 AC4: mock curl was never called"
fi

# #70 AC5: self-hosted path with no secret must exit non-zero
TMPDIR70B="$(mktemp -d)"
if OTTA_PULSE_URL="http://self-hosted.example" \
     bash "$TELEMETRY_SCRIPT" owner/repo 2>/dev/null; then
  fail "#70 AC5: self-hosted path without secret should exit non-zero, but exited 0"
fi
rm -rf "$TMPDIR70B"

echo "✓ setup-wizard: #70 AC1–AC5 passed"
