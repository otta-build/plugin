---
description: Set up a cloud routine that runs the Otta pipeline autonomously on a schedule (laptop-off)
---

Set up an autonomous Otta routine only when the active harness actually provides persistent scheduling.

**Claude Code with the `/schedule` skill:** create a **nightly dev-loop routine** for this repository. Claude Code routines run on Anthropic infrastructure and can continue while the laptop is closed. Use this prompt verbatim as the routine's instructions:

> Pick the highest-priority open GitHub issue in this repo that has an acceptance block (a ` ```acceptance ` fenced block or `- [ ]` AC checkboxes) and no open PR. Run the Otta shipping pipeline on it: seed `.pr-body.md` from its acceptance criteria, implement test-first, verify against the project gate and every AC, and open a PR (`Fixes #N` + an `idea_ref`) targeting `staging` if `.otta.yml` names one, else `main`. Open at most one PR. If no suitable issue exists, do nothing. Never merge.

Default schedule: **weeknights**. Confirm the cadence, repository, and environment with the user before saving (the routine commits and opens PRs as them).

Set `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1` in the routine's Claude Code launch environment: nobody is watching a scheduled run, so the advisor tool's per-subagent, uncached transcript re-read is a nondeterministic cost/latency multiplier not worth paying unattended.

**Codex alternative:** Codex does not provide a persistent cloud scheduler through this plugin. Offer the user the copy-ready routine prompt above for an existing CI/scheduler, or offer to adapt it to an automation system the user explicitly names and authorizes. Do not claim that a schedule was saved, will run laptop-off, or can open PRs autonomously unless an available scheduling system confirms creation.

Other useful triggers the user can add on the routine's page at claude.ai/code/routines:
- **GitHub `pull_request.opened`** → an Otta review routine (apply the acceptance-gate review checklist, comment inline).
- **API `/fire`** → wire Sentry/alerting to open a fix-PR from a stack trace.

For the Claude path, tell the user routines need Claude Code on the web enabled and count against their daily routine cap.
