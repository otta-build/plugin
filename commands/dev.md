---
description: Run the Otta pipeline interactively (developer-in-the-loop) — the builder can ask you mid-build
argument-hint: <issue-number>
---

Run the Otta shipping pipeline for issue **#$1** **interactively, in this session** — so you can answer questions and give direction while it builds. (For an autonomous, unattended run that can't ask you, use `/otta:build` instead.)

**Do NOT use the Workflow tool.** Run the stages yourself, dispatching each subagent via the Task tool, and **pause to involve the developer whenever a stage needs a decision.** That ability is the whole point of this mode.

**Name every dispatch.** Pass an explicit `name` to each Task/Agent call (e.g. `otta-builder-#$1`, `otta-reviewer-#$1`, `otta-qa-#$1`, `otta-devops-#$1`) instead of leaving it unnamed. Without a name, background-agent notifications ("Teammate @<hash> finished") show an opaque hash instead of which stage just completed.

1. **Seed.** If `.pr-body.md` is missing, run:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/seed-pr-body.sh" $1`
   Read it. If the issue has no acceptance criteria, ask the developer to add them before continuing.

2. **Learn.** Run the `learn-from-pulse` skill now — after `.pr-body.md` is seeded (so the `idea_ref` exists) and **before** the builder writes code. It consults Pulse for this idea's prior shipped work, escaped defects, and loop verdicts, so the build doesn't repeat a failure the factory already caught. If Pulse isn't configured it no-ops and the loop continues.

3. **Build.** Dispatch the `otta:builder` subagent (`name: "otta-builder-#$1"`) to implement test-first against the ACs. **If the builder returns a question, NEEDS_CONTEXT, or a real design decision, surface it to the developer, get the answer, then re-dispatch the builder with it.** Do not guess on the developer's behalf for genuine decisions.

4. **Spec Review.** Dispatch `otta:reviewer` (`name: "otta-reviewer-#$1"`). If it reports gaps, send them to the builder (ask the developer first if a gap is ambiguous), then re-review.

5. **Verify.** Dispatch `otta:qa` (`name: "otta-qa-#$1"`) to run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-gate.sh"` (this also captures the verdict to the LEARN ledger) and adversarially verify each AC. If a gate or AC fails, surface it — fix with the builder, or ask the developer how to proceed.

6. **Ship.** Only when the gate passed and every AC passed: dispatch `otta:devops` (`name: "otta-devops-#$1"`) to commit and `gh pr create --body-file .pr-body.md`. Confirm the PR target (staging vs main) with the developer if unsure.

7. **Deploy+verify (per policy).** After the PR is open, run the deploy stage per `.otta.yml` `deploy.auto`: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-deploy-verify.sh" <pr-number>`. With the default `human-approve` (or an absent `deploy` block) this stops at the green PR — today's behavior. `merge-on-green` / `merge-and-deploy` poll the gate to green, then merge (and, for `merge-and-deploy`, verify the deploy by provider SHA-match). Production hands-off requires `deploy.allow_production: true`. See `/otta:ship` for the full policy.

Throughout: **when in doubt, ask — don't assume.** Report the result at the end (PR URL, or where you stopped and why).

> **Tier rule:** for tiny (≤2-file, no new public behavior) changes use `/otta:fix` (gated, light review) instead of this full pipeline.
