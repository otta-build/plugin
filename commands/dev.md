---
description: Run the Otta pipeline interactively (developer-in-the-loop) — the builder can ask you mid-build
argument-hint: <issue-number>
---

Run the Otta shipping pipeline for issue **#$1** **interactively, in this session** — so you can answer questions and give direction while it builds. (For an autonomous, unattended run that can't ask you, use `/otta:build` instead.)

**Do NOT use the Workflow tool.** Run the stages yourself through the harness's native subagent primitives, and **pause to involve the developer whenever a stage needs a decision.** That ability is the whole point of this mode.

**Codex subagent mapping.** Treat Task/Agent wording below as a role contract, not a requirement for Claude-only tools. In Codex, use `spawn_agent` to start each named role with instructions to read the resolved plugin's `agents/<role>.md`, then use `wait_agent` before advancing to its dependent stage. Relay review findings, questions, or repair requests to an existing agent with `send_message` or `followup_task`, then wait again. Keep build → review → qa → devops sequential, and never spawn devops until review, qa, and the gate pass. Other harnesses use their equivalent spawn, feedback, and wait primitives.

For Codex, include the resolved absolute plugin root in every subagent prompt and require the role to inline-inject `OTTA_PLUGIN_ROOT` on each plugin command; do not assume the subagent inherits the parent's environment. If collaboration/subagent primitives are unavailable, execute each `agents/<role>.md` contract sequentially in the current agent, explicitly completing build before review, review before qa, and qa before devops. Report this as same-agent staged execution, not as subagent work.

**Name every dispatch.** Pass an explicit `name` to each Task/Agent call (e.g. `otta-builder-$1`, `otta-reviewer-$1`, `otta-qa-$1`, `otta-devops-$1`) instead of leaving it unnamed. Names must match `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$` (no `#`) so `SendMessage({to: <name>})` can resume them later. Without a name, background-agent notifications ("Teammate @<hash> finished") show an opaque hash instead of which stage just completed. For Codex task identifiers use `otta_build_$1`, `otta_review_$1`, `otta_qa_$1`, and `otta_ship_$1`.

## Progress presentation

Follow [the shared progress protocol](../docs/progress-protocol.md) with interactive delivery. Append Deploy and Verify only when resolved policy performs deployment.

### Claude Code adapter

Create one native Task/Todo projection with TaskCreate or TodoCreate — one task per selected pipeline stage (`build`, `spec-review`, `verify`, `ship`) — then advance each with `TaskUpdate` only at a meaningful transition, keeping `activeForm` aligned with the active stage. When `/goal` is available, set the session goal from the issue's acceptance criteria at run start, so the run carries an explicit completion condition. Native Tasks and named Agent rows are ambient progress; do not print a duplicate checklist or routine narration when they are available. Without `TaskCreate`/`TaskUpdate`/`/goal`, fall back to the documented markdown checklist — this degrades gracefully on any harness lacking these primitives.

### Codex adapter

Create one native plan with `update_plan` and reuse it for the run. Keep exactly one stage `in_progress`; only active or blocked stage text carries detail. Update only at a meaningful transition. Native agent rows and the goal footer already show runtime activity, so do not repeat them in prose.

Without native progress tooling, render the selected compact Markdown stages once. For either adapter, emit transcript messages only for decisions, failures or blockers, material risk changes, and completion. When a stage fails or is blocked, mark it `blocked` with the concrete reason and next action.

1. **Seed.** If `.pr-body.md` is missing, run:
   `bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/seed-pr-body.sh" $1`
   Read it. If the issue has no acceptance criteria, ask the developer to add them before continuing.

2. **Learn.** Resolve the run's independent consult/capture policy and consult active, non-expired repo rules **before** the builder writes code:

   ```bash
   bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-learning-policy.sh" prepare
   ```

   Read `.otta/run/learning-receipt.json`. When its consultation status is `consulted`, read `.otta/run/consulted-learnings.md` and include those rules in the builder dispatch. A skipped/unavailable consultation is non-blocking; preserve its explicit reason in the checklist. `OTTA_LEARN_CONSULT=true|false` and `OTTA_LEARN_CAPTURE=true|false` are per-run overrides and resolve independently. The receipt contains policy/provenance/identifiers only, never raw session content. Pulse may still provide issue history when configured, but it does not replace `LEARNINGS.md` as rule truth.

3. **Build.** Dispatch the `otta:builder` subagent (`name: "otta-builder-$1"`) to implement test-first against the ACs. **If the builder returns a question, NEEDS_CONTEXT, or a real design decision, surface it to the developer, get the answer, then re-dispatch the builder with it.** Do not guess on the developer's behalf for genuine decisions.

3.5. **Visual verify (frontend changes only).** If the build touched UI/frontend files (components, pages, styles), invoke the `run` skill now to launch the app and observe the golden path in a real browser before spec review — typecheck and unit tests verify code correctness, not that the feature looks/works right. Skip this step entirely for backend-only, CLI-only, or non-UI changes.

4. **Spec Review.** Dispatch `otta:reviewer` (`name: "otta-reviewer-$1"`). If it reports gaps, send them to the builder (ask the developer first if a gap is ambiguous), then re-review. **Claude Code fix loop:** resume the existing named builder with `SendMessage({to: "otta-builder-$1"})` carrying the reviewer's feedback — do not spawn a fresh builder; that would lose its worktree/branch state. The Codex `send_message`/`followup_task` path above is unchanged.

5. **Verify.** Dispatch `otta:qa` (`name: "otta-qa-$1"`) to run `bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-gate.sh"` (this routes the verdict through the resolved capture policy) and adversarially verify each AC. If a gate or AC fails, surface it — fix with the builder, or ask the developer how to proceed.

6. **Ship.** Only when the gate passed and every AC passed: dispatch `otta:devops` (`name: "otta-devops-$1"`) to commit and `gh pr create --body-file .pr-body.md`. Confirm the PR target (staging vs main) with the developer if unsure.

7. **Deploy+verify (per policy).** Resolve natural target intent or `deploy.default`, then pass the resolved deployment environment identically in every harness: `bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-deploy-verify.sh" <pr-number> --environment <name>`. Legacy flat contracts omit the flag and retain the existing `human-approve`, `merge-on-green`, and provider-verification behavior. When `.otta.yml` configures `executor: github-workflow`, `human-approve` first prints the immutable PR head and production target; only after explicit approval rerun with `--approved-head <exact-pr-head> --environment <name>`. Otta then merges at most once, dispatches the repository-owned workflow exactly once for the merge SHA, polls terminal success, and verifies `health_url` reports that SHA. The workflow must be the sole infrastructure mutation authority and use serialized production concurrency. See `/otta:ship` for recovery and rollback commands.

Throughout: **when in doubt, ask — don't assume.** Report the result at the end (PR URL, or where you stopped and why).

> **Tier rule:** for tiny (≤2-file, no new public behavior) changes use `/otta:fix` (gated, light review) instead of this full pipeline.
