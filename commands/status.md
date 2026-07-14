---
description: Show pipeline status (Idea → Build → Gate → CI → Release/Deploy) for an issue or PR, or a dashboard across all open issues
argument-hint: [issue-or-pr-number]
---

Show where work sits in the Otta pipeline (Idea → Build → Gate → CI → Release/Deploy) right now: a stage-by-stage checklist for a single **#$1**, or — if no argument is given — a dashboard across all open issues. Read-only: this command never writes, merges, or pushes anything.

## Dashboard mode (no `$1`)

If `$1` is empty/absent, don't require an issue number — instead enumerate open issues and render a compact one-row-per-issue table:

1. `REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"`.
2. `gh issue list --repo "$REPO" --state open --limit 20 --json number,title,createdAt` — capped at **20 issues** by default to avoid unbounded API calls. If there are more open issues than the cap, note the cap in your response (e.g. "showing 20 of N open issues").
3. For **each** issue returned, resolve its 5 stages using the exact same steps 1–6 below (Idea/Build/Gate/CI/Release resolution, including the optional Pulse corroboration) that single-issue mode uses — don't duplicate that logic, just apply it per issue.
4. Build one JSON object shaped like:
   ```json
   {
     "issues": [
       {"issue": "82", "title": "...", "createdAt": "2026-06-20T00:00:00Z", "stages": { "idea": {"status": "..."}, "build": {"status": "..."}, "gate": {"status": "..."}, "ci": {"status": "..."}, "release": {"status": "..."} }},
       ...
     ]
   }
   ```
   (`detail` per stage is optional in dashboard mode — omit it to keep rows compact; the renderer falls back to `pending` for missing statuses. Always include `createdAt` from step 2 — it drives the sort in step 5.)
5. Pipe it into the same renderer: `echo "$JSON" | bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-status.sh"`. It detects the `"issues"` array and renders one compact row per issue (issue #, title, one glyph per stage — Idea/Build/Gate/CI/Release in that order) instead of the full 5-line checklist.

   **Sort rule (most-blocked/stalest first):** the renderer sorts rows itself — you don't need to pre-sort. Each issue is bucketed by rank: **rank 0** if any stage is `fail`, **rank 1** if any stage is `pending` and none `fail`, **rank 2** if every stage is `pass`. Rows are ordered by rank ascending (0 before 1 before 2), then within the same rank by `createdAt` ascending — older issues first — falling back to numeric issue number ascending when `createdAt` is missing.
6. Report the rendered table verbatim to the developer as your response.

## Single-issue mode (`$1` given)

1. **Resolve the repo + the item.** `REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"`. Try `gh pr view $1 --repo "$REPO" --json number,title,state,url,mergedAt,body` first — if `$1` is a PR, that's your Build+Release source directly and its body's `Fixes #N` / `Closes #N` gives you the issue. If it errors (not a PR), treat `$1` as an issue number instead.

2. **Idea stage.** `gh issue view <issue> --repo "$REPO" --json number,state,title`. `pass` if the issue exists (open or closed); `fail` only if the lookup 404s. Prefer the real `idea_ref` from `.pr-body.md` in the current checkout if it's seeded for this issue; otherwise use `issue:#<issue>`.

3. **Build stage — find the linked PR** (skip if step 1 already resolved a PR directly):
   ```bash
   gh api "repos/$REPO/issues/<issue>/timeline" --paginate \
     --jq '.[] | select(.event=="cross-referenced" and .source.issue.pull_request) | .source.issue.number' | tail -1
   ```
   No PR found yet → `build: pending`, and every later stage is also `pending` (nothing to check). A PR found/open → `build: pass`; a PR found but closed unmerged → `build: fail`.

4. **Gate + CI stages.** `gh pr checks <pr-number> --repo "$REPO" --json name,state,bucket` (or `gh pr checks <pr-number>` if `--json` isn't supported by the installed `gh` version — fall back to parsing the plain-text table). Map the check named `Otta Gate` (or its sub-checks) to the **Gate** stage, and the CI workflow check (e.g. `CI` / `ci.yml`) to the **CI** stage. `bucket`/state `pass`→pass, `fail`→fail, anything in-progress/queued→pending. This is the gh-only detail text (e.g. `"Otta Gate: 2/3 sub-checks failing"`); step 6 below enriches it with Pulse feedback when configured.

5. **Release/Deploy stage.** From the PR JSON: `mergedAt` unset → `pending`. `mergedAt` set → check `gh release list --repo "$REPO" -L 5` for a tag containing the merge commit, or fall back to the `.otta.yml` `deploy.auto` policy text (e.g. "merged, deploy policy: human-approve — no auto-deploy configured") when there's nothing further to verify. Merged with a matching release → `pass`. This is the gh-only detail text; step 6 below enriches it with Pulse `/lifecycle` ship info when configured.

6. **Pulse `/grade` + `/lifecycle` (opt-in).** Only if both `OTTA_PULSE_URL` and `OTTA_PULSE_TOKEN` are set (check env, then `./.otta/pulse.env`). If unset, skip this step entirely and note in the Gate stage detail: `"Pulse not configured — gate status from gh checks only"`. Never treat "not configured" as an error, and a failed/timed-out call must never block rendering — swallow it and fall through to the gh-only detail text from steps 4/5.

   **Gate stage — `/grade` verdict feedback:**
   ```bash
   curl -fsS -m 5 "${OTTA_PULSE_URL%/}/grade?repo=$REPO&limit=50" \
     -H "x-pulse-token: ${OTTA_PULSE_TOKEN}"
   ```
   Pipe the response into the renderer's `format-gate-detail` subcommand with the PR's head branch (the same branch used for `gh pr checks` in step 4):
   ```bash
   GATE_DETAIL="$(curl -fsS -m 5 "${OTTA_PULSE_URL%/}/grade?repo=$REPO&limit=50" -H "x-pulse-token: ${OTTA_PULSE_TOKEN}" \
     | bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-status.sh" format-gate-detail "<head-branch>")"
   ```
   If `$GATE_DETAIL` is non-empty (e.g. `"gate failed: tsc failed: 2 errors"` or `"gate passed"`), use it as the Gate stage `detail` instead of the gh-only text. If empty (no matching verdict, or the call failed), keep the gh-only detail from step 4 unchanged.

   **Release stage — `/lifecycle` ship info:**
   ```bash
   RELEASE_DETAIL="$(curl -fsS -m 5 "${OTTA_PULSE_URL%/}/lifecycle?repo=$REPO&limit=100" -H "x-pulse-token: ${OTTA_PULSE_TOKEN}" \
     | bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-status.sh" format-release-detail "<issue>")"
   ```
   If `$RELEASE_DETAIL` is non-empty (e.g. `"merged + shipped v0.23.0 (2026-07-01T09:00:00Z)"`), use it as the Release stage `detail` instead of the gh-only text. If empty, keep the gh-only detail from step 5 unchanged.

7. **Render.** Build one JSON object shaped like:
   ```json
   {
     "issue": "$1",
     "stages": {
       "idea":    {"status": "pass|fail|pending", "detail": "..."},
       "build":   {"status": "pass|fail|pending", "detail": "..."},
       "gate":    {"status": "pass|fail|pending", "detail": "..."},
       "ci":      {"status": "pass|fail|pending", "detail": "..."},
       "release": {"status": "pass|fail|pending", "detail": "..."}
     }
   }
   ```
   and pipe it in:
   ```bash
   echo "$JSON" | bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-status.sh"
   ```
   Report the rendered checklist verbatim to the developer as your response.

## Pipeline stage checklist (in-flight runs)

When an issue has an in-flight `/otta:dev` or `/otta:build` run, `/otta:status` also renders the **pipeline stage checklist** — the per-stage view from the active run, not just the merged-PR view above.

Check the LEARN ledger (`~/.otta/ledger/<repo-slug>.jsonl`) for recent `deploy_audit` or `gate_verdict` records that carry a `pr` field matching this issue's linked PR. Combine with the PR's current check-run state to infer which pipeline stage the run is in:

| Inferred stage | Signal |
|---|---|
| Build in-progress | PR not yet open (no cross-reference in issue timeline) |
| Gate/CI in-progress | PR open, gate checks queued or in-progress |
| Deploy in-progress | PR merged, deploy-verify not yet confirmed |
| Done | PR merged + deploy confirmed (or human-approve policy) |

Render the stage checklist as a compact list alongside the standard 5-stage view:

```
Pipeline stages (#$1):
  ✓ Seed    ✓ Learn    ⋯ Build    ○ Review    ○ QA    ○ Ship    ○ Deploy
```

Degrade gracefully if the ledger or PR state is insufficient to infer stages — omit the pipeline stage row rather than showing speculative data.

### Resumption projection

This status resolution is the durable evidence source and source of truth for native progress projections. On resume, resolve the issue, linked PR, checks, ledger verdicts, deploy policy, and deploy audit before marking stages active or completed. Never reset to Seed or Build merely because a new session invoked the workflow.

If durable evidence conflicts or contradicts another source, report the contradiction and keep the affected stage blocked or unknown; do not advance optimistically. With insufficient evidence, omit speculative state and label any native projection session-only.
