---
description: Start work on a GitHub issue the Otta way — seed .pr-body.md with acceptance criteria
argument-hint: <issue-number>
---

Start the Otta shipping loop for issue **#$1**.

1. Run the bundled seeder to create `.pr-body.md` from the issue's acceptance criteria:

   ```bash
   bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/seed-pr-body.sh" $1 --force
   ```

2. Read the seeded `.pr-body.md`. If the issue had no `- [ ]` acceptance checkboxes, the AC block is a placeholder — **stop and ask the user to add testable acceptance criteria to the issue first**, then re-run. ACs that can't become a check aren't ACs.

3. Confirm the plan with the user in one or two lines: what you'll build, and which acceptance criteria it satisfies.

4. **Task protocol (harness-native).** If `TaskCreate` is available, create one task per pipeline stage — `build`, `spec-review`, `verify`, `ship` — via `TaskCreate`, then advance each task's status with `TaskUpdate` at every stage transition (`pending` → `in_progress` → `completed`/`blocked`), keeping `activeForm` aligned with the active stage. If `/goal` is available, set the session goal from the issue's acceptance criteria (`/goal <acceptance-criteria summary>`) so the run has an explicit, harness-tracked completion condition. Where `TaskCreate`/`TaskUpdate`/`/goal` are unavailable, fall back to the documented markdown checklist instead — this degrades gracefully on any harness without native task tools.

   **Codex adapter.** Where Codex's persisted goal system is available, set the goal from the issue's acceptance criteria at pipeline start (`/goal <acceptance-criteria summary>`) alongside the existing `update_plan` protocol — persisted goals survive pause/resume, so the run keeps an explicit completion condition across usage-limit-aware continuations. On Codex versions without persisted goals, fall back to `update_plan` only.

Then begin implementing — write the smallest failing test first (TDD), implement, keep the `.pr-body.md` Verification section honest as you go. When ready to push, use `/otta:ship`.
