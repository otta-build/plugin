# Cross-Harness Progress Design

Issue: [otta-build/plugin#139](https://github.com/otta-build/plugin/issues/139)

## Summary

Otta will expose one shared workflow-progress protocol through the best native presentation available in Claude Code and Codex. Claude Code keeps its Task and Workflow progress surfaces. Codex uses one quiet native plan projection. Both harnesses suppress routine stage narration, interrupt only for attention-worthy events, and reconstruct resumed progress from durable Otta evidence.

Otta's ledger and status commands remain the source of truth. Harness UI is a disposable projection of that truth.

## Goals

- Give Claude Code and Codex users equally clear workflow state without forcing identical UI.
- Preserve Claude Code's richer native Task and Workflow experience.
- Reduce Codex transcript noise while keeping the active stage legible.
- Select stage sets deterministically from the invoked Otta workflow and deploy policy.
- Make decisions, failures, risk changes, and completion immediately actionable.
- Restore an evidence-backed progress projection after a session resumes.
- Release the improvement only after contract tests and harness-specific smoke checks pass.

## Non-goals

- Add custom Claude Code or Codex client UI.
- Make a plugin-owned sticky panel or custom status-line field.
- Replace `/otta:status`, `$otta-status`, or the Otta ledger with transient UI state.
- Change the underlying build, review, QA, gate, ship, or deploy contracts.
- Make the two harnesses visually identical.

## Shared Progress Protocol

The protocol defines workflow profiles, stage states, transition rules, attention events, and resumption behavior. Harness adapters decide how to render that protocol.

### Deterministic profiles

| Profile | Entry point | Visible stages |
| --- | --- | --- |
| Read-only | No delivery skill or command is invoked | No Otta pipeline progress |
| Tiny fix | `/otta:fix` or `$otta-fix` | Build, Gate, PR |
| Interactive delivery | `/otta:dev` or `$otta-dev` | Seed, Learn, Build, Review, QA, Ship |
| Autonomous delivery | `/otta:build` or `$otta-build` | Seed, Learn, Build, Review, QA, Ship |
| Deployment delivery | Any mutable profile whose resolved policy performs deployment | Append Deploy and Verify |

This routing is command-driven, not an open-ended model classification. The existing tiny-fix eligibility rules still decide whether `/otta:fix` or `$otta-fix` is appropriate. If scope expands beyond that eligibility, Otta reports a material risk change and moves to the standard delivery profile.

### Stage states

Every visible stage has one of four states:

- `pending`
- `in_progress`
- `completed`
- `blocked`, with a concrete reason and next action

Only one stage may be `in_progress`. A blocked workflow has no in-progress stage until the blocker is resolved.

### Meaningful transitions

Harness progress UI updates only when:

- the active stage changes;
- a stage completes;
- a stage becomes blocked or recovers;
- scope expansion changes the workflow profile;
- resumed evidence changes the reconstructed state.

Routine tool calls, polling, elapsed-time messages, and commentary that restates the current stage do not update or duplicate progress.

## Claude Code Adapter

### Interactive `/otta:dev`

- Create native Task/Todo items for the selected profile.
- Update the native item only at meaningful transitions.
- Keep explicit, human-readable agent names for builder, reviewer, QA, and DevOps.
- Do not print a duplicate Markdown checklist when native tasks are available.
- Do not narrate routine work already represented by the task list or agent activity.

### Autonomous `/otta:build`

- Treat the native Workflow phase display as the primary live progress surface.
- Do not create a second competing transcript checklist when Workflow supplies phase state.
- Map Workflow phase changes to the shared protocol.
- Return a compact blocked or completion result when the detached workflow ends.

### Claude fallback

If neither native Task/Todo nor Workflow progress is available, render the selected compact stage list once in Markdown and update it only through attention events.

## Codex Adapter

- Create one native Codex plan for the selected profile.
- Update that same plan only at meaningful transitions.
- Keep only the active or blocked stage descriptive; other labels remain short.
- Use short, recognizable subagent task names such as `otta_build_139` and `otta_review_139`.
- Rely on Codex's native agent rows and goal footer for ambient runtime activity.
- Do not narrate routine work already represented by the plan, agent rows, or tool output.

Example:

```text
✔ Seed
✔ Learn
● Build — adaptive progress contracts
○ Review
○ QA
○ Ship
```

Codex clients without native plan tooling use the shared Markdown fallback.

## Attention Events

Both adapters emit a compact transcript message only for:

1. **Decision required** — the smallest question that unblocks progress.
2. **Failure or blocker** — stage, concrete reason, and next action.
3. **Material risk change** — what changed and how the profile or execution changes.
4. **Completion** — the final evidence handoff.

Examples:

```text
QA blocked · preview SHA 9ac21e7 does not match PR head b724ad1
Action: rebuild the preview for the current head.
```

```text
Scope expanded · tiny-fix eligibility no longer holds because public behavior changed.
Switching to the standard Review and QA gates.
```

These events must not duplicate information that is already sufficiently visible in the immediately preceding native UI update.

## Resumption and Source of Truth

Before projecting a resumed workflow, Otta reads the existing ledger/status path.

- Completed evidence marks a stage completed.
- Recorded failure marks the corresponding stage blocked.
- An in-flight stage is shown only when supported by current agent, PR, check, or deployment evidence.
- Missing or contradictory evidence is shown as unknown and reconciled through the status workflow rather than optimistic advancement.
- Terminal shipped or blocked evidence is preserved across sessions.

The adapters must not assume a resumed invocation begins at Seed or Build. If durable status lookup is unavailable, they label the projection session-only and avoid reconstructed-state claims.

## Detailed Status Surface

`/otta:status` and `$otta-status` remain the detailed, on-demand views. They expose issue and acceptance criteria, current profile and stage, agent state, tests, gates, PR and CI state, deploy policy, verification evidence, blocker history, and next action.

Progress adapters point users to the appropriate status entry point rather than duplicating detailed evidence during every stage transition.

## Completion Handoff

The final response includes:

- outcome: shipped or blocked;
- issue and PR link when present;
- focused test and nearest gate evidence;
- review and QA verdicts;
- deploy policy and verified commit/version when applicable;
- remaining human action, or an explicit statement that none remains.

Claude Code and Codex use the same semantic handoff fields even if their native formatting differs.

## Implementation Boundaries

- Canonical command documents own shared protocol language and harness branching.
- Claude Code uses command registration from `.claude-plugin/plugin.json` plus native Task, Agent, and Workflow primitives.
- Codex skill adapters continue to load the canonical commands through `.codex-plugin/plugin.json` and `skills/otta-*/SKILL.md`.
- Tests verify both harness branches so a shared-command edit cannot improve one by regressing the other.

## Error Handling

- Missing native progress tooling activates the one-time Markdown fallback.
- Conflicting durable evidence blocks optimistic advancement and surfaces the conflict.
- If work moves from read-only to mutable, the appropriate delivery entry point must establish progress before the first mutation.
- If tiny-fix scope expands, stop that path and move to interactive or autonomous delivery without skipping Review or QA.
- A progress-presentation failure never weakens delivery gates.

## Test and Release Strategy

Write the smallest failing contract test before editing workflow instructions. Focused tests prove:

- entry points map to deterministic profiles;
- Claude interactive mode uses one native Task/Todo projection without duplicate narration;
- Claude autonomous mode uses Workflow phases without a competing checklist;
- Codex uses one native plan projection and meaningful-transition updates;
- both adapters implement the same attention-event policy;
- resumed workflows consult durable status before projection;
- both status commands remain the detailed evidence surface;
- documentation includes normal, blocked, resumed, and completion examples for both harnesses.

After the focused tests pass:

1. Run the full plugin test suite.
2. Run a Claude Code smoke workflow that proves native Task or Workflow progress and captures the transcript evidence.
3. Run a Codex smoke workflow that proves native plan progress and captures the transcript evidence.
4. Run the Otta gate, reviewer, and QA contracts.
5. Publish the next plugin version only when both harness smokes and all gates pass.

## Success Criteria

- Claude Code retains its native workflow advantages and emits less duplicate prose.
- Codex shows a compact, accurate stage projection without transcript chatter.
- Tiny fixes do not display standard Review and QA stages while retaining their existing gate contract.
- Read-only work creates no Otta delivery progress.
- Blocked runs expose the reason and next action without transcript archaeology.
- Resumed runs show evidence-backed state instead of visually resetting.
- One shared protocol remains testable across both harnesses without pretending their clients are identical.
