---
description: Run the Otta TDD shipping pipeline (build → spec-review → verify → ship) for an issue as a workflow
argument-hint: <issue-number>
---

Run the Otta shipping pipeline for issue **#$1** as a dynamic workflow.

First make sure the workspace is seeded — if `.pr-body.md` doesn't exist yet, run `/otta:start $1` to seed the acceptance criteria.

**Stage checklist (create before launching the Workflow).** Before dispatching the Workflow tool, create a task/todo checklist using the harness's native task tool (TaskCreate / TodoCreate if available). One item per pipeline stage: `Seed`, `Learn`, `Build`, `Review`, `QA`, `Ship`, `Deploy`. Mark `Seed` and `Learn` completed (they run before the Workflow), then update the remaining items as the Workflow reports stage transitions. If no native task tool is available, render the checklist as a markdown block in chat. Stage failures annotate the item with the failure reason (e.g. `✗ QA — gate failed: ...`).

Then **learn before building**: run the `learn-from-pulse` skill (the `idea_ref` now exists in `.pr-body.md`). It consults Pulse for this idea's prior shipped work, escaped defects, and loop verdicts so the pipeline doesn't repeat a failure the factory already caught. If Pulse isn't configured it no-ops. Fold anything it surfaces into `.pr-body.md` as a guarding AC before the workflow runs.

Then invoke the **Workflow** tool with the bundled pipeline script (this is an explicit, user-invoked opt-in to orchestration):

```
Workflow({
  scriptPath: "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/workflows/otta-build.mjs",
  args: { issue: "$1", pluginRoot: "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}" }
})
```

`pluginRoot` lets each stage call the real otta engine scripts (`seed-pr-body.sh`, `otta-gate.sh` — which also captures the verdict to the LEARN ledger) instead of generic instructions.

The workflow runs four stages, each a focused subagent. Spec repair is bounded
to three attempts by default (`args.maxRevisions` may override it), and stops
early when the same normalized blockers repeat twice:
1. **Build** — `builder` implements test-first (TDD)
2. **Spec Review** — `reviewer` checks every AC is met, nothing extra (one fix loop)
3. **Verify** — `qa` runs the gate and adversarially verifies each AC has real evidence
4. **Ship** — `devops` opens the PR (`Fixes #N` + `idea_ref`) — **only if** the gate passed and every AC passed

When it finishes, report the result: shipped (PR URL) or blocked (which AC/gate failed). The pipeline never opens a PR for work that didn't pass verify.

**Deploy+verify (per policy).** After the PR is open, the deploy stage runs per `.otta.yml` `deploy.auto`: `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/otta-deploy-verify.sh" <pr-number>`. The default `human-approve` (and an absent `deploy` block) stops at the green PR — unchanged behavior. `merge-on-green` / `merge-and-deploy` poll the Otta Gate to green (surfacing the blocking sub-check on stall rather than hanging), then merge; `merge-and-deploy` also verifies the deploy by provider SHA-match. Production hands-off requires an explicit `deploy.allow_production: true` opt-in. See `/otta:ship` for the policy table.

> **Tier rule:** for tiny (≤2-file, no new public behavior) changes use `/otta:fix` (gated, light review) instead of this full pipeline.

> **Routing rule:** read-only investigations do not require an Otta issue/PR.
> Any task that changes code, configuration, infrastructure, durable docs, or
> external state uses this pipeline (or `/otta:fix` for the tiny tier).
