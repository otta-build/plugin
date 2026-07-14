# Cross-Harness Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Claude Code and Codex one quiet Otta progress protocol rendered through each harness's best native progress surface, then verify and release it for both clients.

**Architecture:** `docs/progress-protocol.md` owns shared profiles, transitions, attention events, and the durable-truth boundary. Canonical command documents adapt that protocol to Claude Task/Workflow primitives or a Codex native plan. Bash contract tests lock both branches before instruction changes.

**Tech Stack:** Markdown plugin contracts, Bash structural tests, Claude Code plugin commands, Codex plugin skills, GitHub Actions, Otta gate and auto-release.

---

## File Map

- Create `docs/progress-protocol.md`: shared normative progress contract.
- Create `tests/cross-harness-progress.test.sh`: focused regression for both adapters.
- Modify `commands/fix.md`: tiny `Build → Gate → PR` profile and escalation.
- Modify `commands/dev.md`: Claude Task/Todo and Codex plan adapters.
- Modify `commands/build.md`: Claude Workflow and Codex plan adapters.
- Modify `commands/status.md`: evidence-backed resumption rules.
- Modify `README.md`: both developer experiences and state examples.
- Modify `.pr-body.md`: #139 verification evidence.

### Task 1: Add the failing progress contract

**Files:**
- Create: `tests/cross-harness-progress.test.sh`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
PROTOCOL="$REPO/docs/progress-protocol.md"
FIX="$REPO/commands/fix.md"
DEV="$REPO/commands/dev.md"
BUILD="$REPO/commands/build.md"
STATUS="$REPO/commands/status.md"
README="$REPO/README.md"
fail() { echo "✗ $1" >&2; exit 1; }
require() { grep -Eiq "$2" "$1" || fail "$3"; }
reject() { if grep -Eiq "$2" "$1"; then fail "$3"; fi; }

[ -f "$PROTOCOL" ] || fail "missing shared progress protocol"
require "$PROTOCOL" 'read-only.*no.*progress' 'read-only profile must stay silent'
require "$PROTOCOL" 'tiny fix.*Build.*Gate.*PR' 'tiny profile must be Build/Gate/PR'
require "$PROTOCOL" 'interactive delivery.*Seed.*Learn.*Build.*Review.*QA.*Ship' 'interactive stages missing'
require "$PROTOCOL" 'autonomous delivery.*Seed.*Learn.*Build.*Review.*QA.*Ship' 'autonomous stages missing'
require "$PROTOCOL" 'Deploy.*Verify' 'deployment stages missing'
require "$PROTOCOL" 'decision required' 'decision event missing'
require "$PROTOCOL" 'failure or blocker' 'blocker event missing'
require "$PROTOCOL" 'material risk change' 'risk event missing'
require "$PROTOCOL" 'projection.*not.*source of truth|not.*source of truth.*projection' 'truth boundary missing'

require "$FIX" 'Build.*Gate.*PR' 'fix profile missing'
require "$FIX" 'scope expand|eligibility.*no longer|switch to.*otta:(dev|build)' 'fix escalation missing'
require "$DEV" 'Claude Code adapter' 'dev Claude adapter missing'
require "$DEV" 'TaskCreate|TodoCreate|native Task' 'dev must preserve native Tasks'
require "$DEV" 'Codex adapter' 'dev Codex adapter missing'
require "$DEV" 'update_plan|native plan' 'dev Codex plan missing'
require "$DEV" 'meaningful transition' 'dev transition rule missing'
require "$DEV" 'routine narration|redundant narration' 'dev quiet rule missing'
require "$BUILD" 'Workflow.*primary.*progress|primary.*progress.*Workflow' 'build Workflow UI missing'
require "$BUILD" 'second competing|competing checklist|duplicate checklist' 'build duplicate-UI rule missing'
require "$BUILD" 'Codex adapter' 'build Codex adapter missing'
require "$BUILD" 'update_plan|native plan' 'build Codex plan missing'
require "$STATUS" 'resume|resum' 'resumption missing'
require "$STATUS" 'source of truth|durable evidence' 'durable truth missing'
require "$STATUS" 'contradict|conflict' 'conflict rule missing'
require "$README" 'Claude Code.*Task|Task.*Claude Code' 'README Claude UI missing'
require "$README" 'Codex.*plan|plan.*Codex' 'README Codex UI missing'
require "$README" 'QA blocked' 'README blocked example missing'
require "$README" 'Resumed|resume' 'README resumed example missing'
require "$README" 'Completion|completed|shipped' 'README completion example missing'
reject "$DEV" 'while the builder works' 'dev prescribes routine narration'
reject "$BUILD" 'while the builder works' 'build prescribes routine narration'
echo "✓ cross-harness-progress: shared protocol and both adapters are locked"
```

- [ ] **Step 2: Make it executable and prove RED**

Run: `chmod +x tests/cross-harness-progress.test.sh && bash tests/cross-harness-progress.test.sh`

Expected: FAIL with `missing shared progress protocol`.

- [ ] **Step 3: Commit the regression**

Run: `git add tests/cross-harness-progress.test.sh && git commit -m "test(#139): define cross-harness progress contract"`

### Task 2: Implement the shared protocol and tiny profile

**Files:**
- Create: `docs/progress-protocol.md`
- Modify: `commands/fix.md`

- [ ] **Step 1: Create the normative protocol**

```markdown
# Otta progress protocol

Harness-native progress is a projection, not the source of truth. Durable Otta ledger, PR, check, and deployment evidence remains authoritative.

## Profiles

| Profile | Entry point | Visible stages |
| --- | --- | --- |
| Read-only | no delivery command or skill | no Otta delivery progress |
| Tiny fix | `/otta:fix` or `$otta-fix` | Build → Gate → PR |
| Interactive delivery | `/otta:dev` or `$otta-dev` | Seed → Learn → Build → Review → QA → Ship |
| Autonomous delivery | `/otta:build` or `$otta-build` | Seed → Learn → Build → Review → QA → Ship |

Append Deploy → Verify only when repository policy performs deployment. Command routing selects the profile; do not add a second model classifier.

## State and transitions

Each stage is pending, in_progress, completed, or blocked. Exactly one may be in_progress. Update native progress only for a meaningful transition: stage start, completion, blocker, recovery, profile escalation, or evidence-backed resumption change. Do not emit routine narration, polling commentary, or prose that restates native UI.

## Attention events

- Decision required — ask the smallest unblocking question.
- Failure or blocker — name stage, reason, and next action.
- Material risk change — name what changed and how execution changes.
- Completion — report evidence and remaining human action.

## Resumption

Reconstruct resumed state from the Otta status path. Never assume a resumed run starts at Seed or Build. Conflicting evidence blocks optimistic advancement. If durable lookup is unavailable, label the projection session-only.

## Fallback

Without native progress tooling, render the selected compact stages once in Markdown, then emit only attention events.
```

- [ ] **Step 2: Add this section to `commands/fix.md` after the tier table**

```markdown
## Progress presentation

Follow [the shared progress protocol](../docs/progress-protocol.md) with `Build → Gate → PR`. Use native Task or plan tooling when available and update it only at meaningful transitions. Do not narrate routine in-stage work.

If scope exceeds two files or changes public behavior, emit one material risk-change event and switch to `/otta:dev` or `/otta:build` (Codex: `$otta-dev` or `$otta-build`) before continuing. Never preserve the compact profile by weakening Review, QA, or gates.
```

- [ ] **Step 3: Prove partial GREEN and commit**

Run: `bash tests/cross-harness-progress.test.sh; test $? -ne 0`

Expected: test advances past protocol/fix and fails on `dev Claude adapter missing`.

Run: `bash tests/fix-command.test.sh`

Expected: PASS.

Run: `git add docs/progress-protocol.md commands/fix.md && git commit -m "feat(#139): define adaptive progress protocol"`

### Task 3: Implement interactive adapters

**Files:**
- Modify: `commands/dev.md`

- [ ] **Step 1: Replace the fixed stage-checklist section with**

```markdown
## Progress presentation

Follow [the shared progress protocol](../docs/progress-protocol.md) with interactive delivery. Append Deploy and Verify only when resolved policy performs deployment.

### Claude Code adapter

Create one native Task/Todo projection with TaskCreate or TodoCreate. Update it only at a meaningful transition and keep `activeForm` aligned with the active stage. Native Tasks and named Agent rows are ambient progress; do not print a duplicate checklist or routine narration.

### Codex adapter

Create one native plan with `update_plan` and reuse it for the run. Keep exactly one stage `in_progress`; only active or blocked stage text carries detail. Update only at meaningful transitions. Native agent rows and the goal footer already show runtime activity, so do not repeat them in prose.

Without native progress tooling, render the compact Markdown stages once. Emit transcript messages only for decisions, failures/blockers, material risk changes, and completion.
```

- [ ] **Step 2: Add stable Codex task names**

Add: `For Codex task identifiers use otta_build_$1, otta_review_$1, otta_qa_$1, and otta_ship_$1.`

- [ ] **Step 3: Test and commit**

Run: `bash tests/cross-harness-progress.test.sh || true; bash tests/pipeline-checklist.test.sh; bash tests/codex-plugin-parity.test.sh`

Expected: existing suites pass; focused test next fails in `commands/build.md`.

Run: `git add commands/dev.md && git commit -m "feat(#139): adapt interactive progress by harness"`

### Task 4: Implement autonomous and resumption adapters

**Files:**
- Modify: `commands/build.md`
- Modify: `commands/status.md`

- [ ] **Step 1: Replace the fixed build checklist section with**

```markdown
## Progress presentation

Follow [the shared progress protocol](../docs/progress-protocol.md) with autonomous delivery. Append Deploy and Verify only when resolved policy performs deployment.

### Claude Code adapter

When Workflow is available, its native phase display is the primary progress surface. Map phases to shared stages and do not create a second competing checklist or narrate routine phase activity. Without Workflow, use one native Task/Todo projection updated only at meaningful transitions.

### Codex adapter

When Workflow is unavailable, create one native plan with `update_plan` before builder dispatch and reuse it through builder → reviewer → qa → devops. Keep exactly one stage `in_progress`, update only at meaningful transitions, and do not repeat plan, agent, polling, or tool activity in prose.

Without native progress tooling, render compact Markdown stages once. Emit transcript messages only for decisions, failures/blockers, material risk changes, and completion.
```

- [ ] **Step 2: Append resumption rules to `commands/status.md`**

```markdown
### Resumption projection

This status resolution is the durable evidence source for native progress. On resume, resolve issue, linked PR, checks, ledger verdicts, deploy policy, and deploy audit before marking stages active or completed. Never reset to Seed or Build merely because a new session invoked the workflow.

If evidence conflicts, report the contradiction and keep the stage blocked or unknown; do not advance optimistically. With insufficient evidence, omit speculative state and label any projection session-only.
```

- [ ] **Step 3: Test and commit**

Run: `bash tests/cross-harness-progress.test.sh || true; bash tests/pipeline-checklist.test.sh; bash tests/codex-plugin-parity.test.sh; bash tests/otta-status.test.sh`

Expected: existing suites pass; focused test next fails at README examples.

Run: `git add commands/build.md commands/status.md && git commit -m "feat(#139): add quiet autonomous progress and resumption"`

### Task 5: Document both experiences

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace `Pipeline stage state` with a `Pipeline progress` section containing**

```markdown
Otta uses one protocol and each harness's best native surface:

- Claude Code interactive runs use Task items and named Agent rows.
- Claude Code autonomous runs use Workflow phases.
- Codex uses one native plan plus agent rows and the goal footer.
- `/otta:status` and `$otta-status` expose durable detail on demand.

Native progress is a projection, not the source of truth. Resumed runs reconstruct it from ledger, PR, check, and deployment evidence.

Normal: `✔ Seed  ✔ Learn  ● Build — progress contracts  ○ Review  ○ QA  ○ Ship`

Blocked:
`QA blocked · preview SHA 9ac21e7 does not match PR head b724ad1`
`Action: rebuild the preview for the current head.`

Resumed:
`Resumed #139 · Build and Review verified from durable evidence`
`● QA — running the Otta gate`

Completion:
`Shipped #139 · PR #N · gate, review, and QA passed`
`Deploy policy: human approval required`
```

- [ ] **Step 2: Prove GREEN and commit**

Run: `bash tests/cross-harness-progress.test.sh && bash tests/pipeline-checklist.test.sh && bash tests/codex-plugin-parity.test.sh && bash tests/fix-command.test.sh && bash tests/otta-status.test.sh`

Expected: all pass.

Run: `git add README.md && git commit -m "docs(#139): explain native progress across harnesses"`

### Task 6: Full verification and client smokes

**Files:**
- Modify: `.pr-body.md`

- [ ] **Step 1: Run every plugin test**

Run: `fail=0; for t in tests/*.test.sh; do bash "$t" || fail=1; done; exit "$fail"`

Expected: all scripts pass.

- [ ] **Step 2: Run syntax and diff checks**

Run: `bash -n tests/cross-harness-progress.test.sh && git diff --check origin/main...HEAD`

Expected: exit `0`, no diff-check output.

- [ ] **Step 3: Smoke Claude Code plugin loading**

Run: `claude --version && claude --plugin-dir "$PWD" -p 'Load Otta and summarize without executing which native progress surfaces /otta:dev and /otta:build use, plus the durable status command.' --output-format text`

Expected: Task/Todo for dev, Workflow for build, `/otta:status` for detail, and no custom sticky-panel claim.

- [ ] **Step 4: Smoke Codex plugin loading**

Run: `codex --version && codex exec --skip-git-repo-check -C "$PWD" 'Inspect Otta skills and canonical commands without changing files. State the native progress surface for $otta-dev and $otta-build and the durable status skill.'`

Expected: one native plan for dev/build, native agent activity, `$otta-status` for detail, and no custom TUI claim.

- [ ] **Step 5: Seed #139 evidence**

Run: `bash scripts/seed-pr-body.sh --force 139`

Add focused test, full-suite, Claude smoke, and Codex smoke evidence to `.pr-body.md`; then commit it if tracked.

### Task 7: Gate, review, QA, ship, and release

- [ ] **Step 1: Run local gate**

Run: `OTTA_PLUGIN_ROOT="$PWD" bash scripts/otta-gate.sh`

Expected: PASS.

- [ ] **Step 2: Apply `agents/reviewer.md` independently**

Review issue #139, design, plan, and `origin/main...HEAD`; resolve every finding and rerun verification.

Expected: COMPLIANT with every AC mapped to evidence.

- [ ] **Step 3: Apply `agents/qa.md` adversarially**

Rerun gate, focused test, full suite, and both client smokes; resolve every failure.

Expected: PASS with no unverified AC.

- [ ] **Step 4: Push and open PR**

Run: `git push -u origin feat/issue-139-cross-harness-progress`

Run: `gh pr create --repo otta-build/plugin --base main --head feat/issue-139-cross-harness-progress --title 'feat(dx): adaptive quiet progress for Claude Code and Codex (#139)' --body-file .pr-body.md`

- [ ] **Step 5: Verify checks and merge**

Run: `gh pr checks --repo otta-build/plugin --watch --interval 10`

Expected: CI and Otta Gate green.

Run: `gh pr merge --repo otta-build/plugin --squash --delete-branch`

- [ ] **Step 6: Watch auto-release**

Run: `RUN_ID="$(gh run list --repo otta-build/plugin --workflow auto-release.yml --limit 1 --json databaseId -q '.[0].databaseId')"; gh run watch "$RUN_ID" --repo otta-build/plugin --exit-status`

Expected: success and a minor release newer than `v1.1.3` because the merged title is `feat`.

- [ ] **Step 7: Verify released artifacts**

Run: `gh release view --repo otta-build/plugin --json tagName,url,publishedAt`

Run: `git fetch origin --tags; TAG="$(git tag --sort=-version:refname | head -1)"; git show "$TAG:.claude-plugin/plugin.json" | jq -r .version; git show "$TAG:.codex-plugin/plugin.json" | jq -r .version`

Expected: identical manifest versions and a GitHub Release URL.
