# Adaptive Codex Progress Design

Issue: [otta-build/plugin#139](https://github.com/otta-build/plugin/issues/139)

## Summary

Otta will present staged workflow progress inside Codex through progressive disclosure. The native Codex plan is a quiet, session-local projection of the current workflow. Otta's ledger and status evidence remain the durable source of truth. Detailed evidence stays available through `$otta-status`.

The plugin will select the smallest stage set appropriate to the work, update the plan only at meaningful transitions, and interrupt the transcript only for decisions, failures, material risk changes, and completion.

## Goals

- Make the active Otta stage understandable without reading the transcript.
- Reduce redundant stage narration during long-running agent work.
- Avoid imposing the full delivery pipeline on read-only or tiny tasks.
- Make blocked states immediately actionable.
- Restore an accurate progress projection after a session resumes.
- Use only Codex-native plugin capabilities; require no Codex TUI changes.

## Non-goals

- Add a sticky panel, custom status-line field, or other Codex TUI component.
- Replace `$otta-status` or the Otta ledger with session-local plan state.
- Hide tool calls, failures, decisions, or evidence required for a truthful handoff.
- Change the underlying build, review, QA, gate, ship, or deploy contracts.

## Progress Profiles

Otta chooses one profile before creating a native plan:

| Profile | Trigger | Visible stages |
| --- | --- | --- |
| Read-only | Investigation or explanation with no intended mutation | No Otta pipeline plan |
| Tiny fix | Existing fast-path eligibility: at most two files and no new public behavior | Build, Gate, PR |
| Standard delivery | Ordinary issue-linked implementation | Seed, Learn, Build, Review, QA, Ship |
| Deployment delivery | Standard delivery where repository policy requires deployment | Seed, Learn, Build, Review, QA, Ship, Deploy, Verify |

The profile is a presentation decision only. It does not weaken gates. If scope expands beyond the selected profile, Otta changes the profile and emits a material risk-change event explaining why.

## Native Plan Projection

For mutable workflows, Otta creates one native Codex plan. It updates that plan only when:

- the active stage changes;
- a stage completes;
- a stage becomes blocked or recovers;
- scope expansion changes the progress profile.

Each stage label is short and outcome-oriented. Only the active or blocked stage carries detail.

Example normal state:

```text
✔ Seed
✔ Learn
● Build — deploy adapter
○ Review
○ QA
○ Ship
○ Deploy
○ Verify
```

Otta does not emit routine prose such as "while the builder works" or repeat facts already visible in the plan or native tool output.

## Attention Events

Otta emits a compact transcript message only for these events:

1. **Decision required** — state the decision and the smallest question that unblocks it.
2. **Failure or blocker** — state the failed stage, concrete reason, and next action.
3. **Material risk change** — state what changed and how the workflow or stage profile changes.
4. **Completion** — provide the final evidence handoff.

Examples:

```text
QA blocked · preview SHA 9ac21e7 does not match PR head b724ad1
Action: rebuild the preview for the current head.
```

```text
Scope expanded · tiny fix is no longer valid because public behavior changed.
Switching to Standard delivery with Review and QA.
```

## Resumption and Source of Truth

The native plan is not durable truth. When starting or resuming a workflow, Otta first reads available durable evidence through the existing ledger/status path and derives the current projection from it.

The projection rules are:

- completed evidence marks a stage completed;
- a recorded failure marks the corresponding stage blocked;
- an in-flight stage is shown only when supported by current agent, PR, check, or deployment evidence;
- missing or contradictory evidence is shown as unknown and requires `$otta-status` reconciliation rather than optimistic advancement;
- terminal shipped or blocked evidence is preserved across sessions.

Otta must not assume that a resumed invocation begins at Seed or Build.

## Detailed Status Surface

`$otta-status` remains the detailed, on-demand view. It may show:

- issue and acceptance criteria;
- current profile and stage;
- active or completed agents;
- test and gate evidence;
- PR and CI state;
- deploy policy and verification evidence;
- blocker history and next action.

The workflow instructions point users to `$otta-status` instead of duplicating this evidence in every transition message.

## Completion Handoff

The final response is compact but complete. It includes:

- outcome: shipped or blocked;
- issue and PR link when present;
- focused test and nearest gate evidence;
- review and QA verdicts;
- deploy policy and verified commit/version when applicable;
- the remaining human action, or an explicit statement that none remains.

## Error Handling

- If native plan tooling is unavailable, render the selected compact stage list once in Markdown and emit only attention events afterward.
- If durable status lookup is unavailable, label the projection as session-only and do not claim reconstructed state.
- If evidence conflicts, stop optimistic stage advancement, mark the affected stage blocked, and direct the user to the conflicting evidence.
- If the task changes from read-only to mutable, create the appropriate plan before performing the first mutation.

## Test Strategy

Add contract tests over the canonical command and skill instructions. The tests will prove that:

- each work class maps to the intended progress profile;
- routine in-stage narration is prohibited;
- plan updates are restricted to meaningful transitions;
- attention events cover decisions, blockers, risk changes, and completion;
- resumed workflows consult durable status before constructing a projection;
- `$otta-status` remains the detailed evidence surface;
- documentation includes normal, blocked, resumed, and completion examples.

The focused contract suite must fail against the current plugin instructions before implementation. After the smallest instruction and documentation changes, run the focused suite plus the repository's nearest full test target.

## Success Criteria

- A long standard delivery run produces no redundant progress prose between stage transitions.
- A tiny fix does not display standard Review and QA stages while retaining its existing gate contract.
- Read-only work creates no Otta delivery checklist.
- A blocked run exposes the reason and next action without requiring transcript archaeology.
- A resumed run shows evidence-backed current state instead of resetting visually.
