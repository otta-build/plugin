---
description: Run the Otta TDD shipping pipeline (build → spec-review → verify → ship) for an issue as a workflow
argument-hint: <issue-number>
---

Run the Otta shipping pipeline for issue **#$1** as a dynamic workflow.

First make sure the workspace is seeded — if `.pr-body.md` doesn't exist yet, run `/otta:start $1` to seed the acceptance criteria.

## Progress presentation

Follow [the shared progress protocol](../docs/progress-protocol.md) with autonomous delivery. Append Deploy and Verify only when resolved policy performs deployment.

### Claude Code adapter

When Workflow is available, its native phase display is the primary progress surface. Map phases to the shared stages and do not create a second competing checklist or narrate routine phase activity. Without Workflow, use one native Task/Todo projection updated only at a meaningful transition.

### Codex adapter

When Workflow is unavailable, create one native plan with `update_plan` before builder dispatch and reuse it through the `builder → reviewer → qa → devops` chain. Keep exactly one stage `in_progress`, update only at a meaningful transition, and do not repeat plan, agent, polling, or tool activity in prose.

Without native progress tooling, render the compact Markdown stages once. For either adapter, emit transcript messages only for decisions, failures or blockers, material risk changes, and completion. Mark a blocked stage with its concrete reason and next action.

Then **learn before building** by resolving the same repo-native policy used by every delivery path:

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-learning-policy.sh" prepare
```

Read `.otta/run/learning-receipt.json`; when consulted, supply `.otta/run/consulted-learnings.md` to the builder. Consultation skips fail open with their explicit reason. `OTTA_LEARN_CONSULT=true|false` and `OTTA_LEARN_CAPTURE=true|false` independently override repo defaults for this run. Pulse history is optional context; `LEARNINGS.md` remains rule truth.

## Orchestration compatibility

When the `Workflow` tool is available, invoke it with the bundled pipeline script (this is an explicit, user-invoked opt-in to orchestration):

```
Workflow({
  scriptPath: "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/workflows/otta-build.mjs",
  args: { issue: "$1", pluginRoot: "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}" }
})
```

`pluginRoot` lets each stage call the real otta engine scripts (`seed-pr-body.sh`, `otta-gate.sh` — which also captures the verdict to the LEARN ledger) instead of generic instructions.

When `Workflow` is unavailable (including Codex), do not call it. Run the same `builder → reviewer → qa → devops` dependency chain sequentially with the harness's native collaboration/subagent primitives:

Before each Codex dispatch, include the resolved absolute plugin root in every subagent prompt. Tell the role to retain that path as execution state and inline-inject `OTTA_PLUGIN_ROOT` for every plugin command it invokes; do not rely on environment inheritance between the parent and subagent.

1. Use `spawn_agent` for the builder, instructing it to read the resolved plugin's `agents/builder.md`, implement test-first, and return evidence. Use `wait_agent` before starting review.
2. Spawn the reviewer with `agents/reviewer.md`, then wait. If it finds gaps, relay them to the existing builder with `send_message` or `followup_task`, wait for the repair, and re-run review. Preserve the same three-attempt/repeated-blocker bounds as the bundled workflow.
3. Spawn qa with `agents/qa.md`, then wait for its gate and acceptance evidence. Relay failures to the builder and repeat bounded review/qa as needed.
4. Spawn devops with `agents/devops.md` only after reviewer and qa pass every acceptance criterion. Wait for the PR result before deploy verification.

On a harness with differently named primitives, use its equivalent spawn, feedback, and wait operations while preserving the same sequential dependencies. Never open the PR when review, qa, or the gate is failing.

If neither Workflow nor collaboration/subagent primitives are available, run the four role contracts sequentially in the current agent: read `agents/builder.md`, complete and record its stage; then separately read and apply reviewer, qa, and devops in order. Preserve the same stage gates, bounded repair loop, and role separation. Do not pretend subagents ran, and do not advance while a prior role is failing.

The workflow runs four stages, each a focused subagent. Spec repair is bounded
to three attempts by default (`args.maxRevisions` may override it), and stops
early when the same normalized blockers repeat twice:
1. **Build** — `builder` implements test-first (TDD)
2. **Spec Review** — `reviewer` checks every AC is met, nothing extra (one fix loop)
3. **Verify** — `qa` runs the gate and adversarially verifies each AC has real evidence
4. **Ship** — `devops` opens the PR (`Fixes #N` + `idea_ref`) — **only if** the gate passed and every AC passed

When it finishes, report the result: shipped (PR URL) or blocked (which AC/gate failed). The pipeline never opens a PR for work that didn't pass verify.

**Deploy+verify (per policy).** After the PR is open, the deploy stage runs per `.otta.yml` `deploy.auto`: `bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-deploy-verify.sh" <pr-number>`. The default `human-approve` (and an absent `deploy` block) stops at the green PR — unchanged behavior. `merge-on-green` / `merge-and-deploy` poll the Otta Gate to green (surfacing the blocking sub-check on stall rather than hanging), then merge; `merge-and-deploy` also verifies the deploy by provider SHA-match. Production hands-off requires an explicit `deploy.allow_production: true` opt-in. See `/otta:ship` for the policy table.

> **Tier rule:** for tiny (≤2-file, no new public behavior) changes use `/otta:fix` (gated, light review) instead of this full pipeline.

> **Routing rule:** read-only investigations do not require an Otta issue/PR.
> Any task that changes code, configuration, infrastructure, durable docs, or
> external state uses this pipeline (or `/otta:fix` for the tiny tier).
