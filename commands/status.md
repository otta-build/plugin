---
description: Show pipeline status (Idea → Build → Gate → CI → Release/Deploy) for an issue or PR
argument-hint: <issue-or-pr-number>
---

Show a stage-by-stage progress checklist for **#$1** — where this piece of work sits in the Otta pipeline right now. Read-only: this command never writes, merges, or pushes anything.

1. **Resolve the repo + the item.** `REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"`. Try `gh pr view $1 --repo "$REPO" --json number,title,state,url,mergedAt,body` first — if `$1` is a PR, that's your Build+Release source directly and its body's `Fixes #N` / `Closes #N` gives you the issue. If it errors (not a PR), treat `$1` as an issue number instead.

2. **Idea stage.** `gh issue view <issue> --repo "$REPO" --json number,state,title`. `pass` if the issue exists (open or closed); `fail` only if the lookup 404s. Prefer the real `idea_ref` from `.pr-body.md` in the current checkout if it's seeded for this issue; otherwise use `issue:#<issue>`.

3. **Build stage — find the linked PR** (skip if step 1 already resolved a PR directly):
   ```bash
   gh api "repos/$REPO/issues/<issue>/timeline" --paginate \
     --jq '.[] | select(.event=="cross-referenced" and .source.issue.pull_request) | .source.issue.number' | tail -1
   ```
   No PR found yet → `build: pending`, and every later stage is also `pending` (nothing to check). A PR found/open → `build: pass`; a PR found but closed unmerged → `build: fail`.

4. **Gate + CI stages.** `gh pr checks <pr-number> --repo "$REPO" --json name,state,bucket` (or `gh pr checks <pr-number>` if `--json` isn't supported by the installed `gh` version — fall back to parsing the plain-text table). Map the check named `Otta Gate` (or its sub-checks) to the **Gate** stage, and the CI workflow check (e.g. `CI` / `ci.yml`) to the **CI** stage. `bucket`/state `pass`→pass, `fail`→fail, anything in-progress/queued→pending.

5. **Release/Deploy stage.** From the PR JSON: `mergedAt` unset → `pending`. `mergedAt` set → check `gh release list --repo "$REPO" -L 5` for a tag containing the merge commit, or fall back to the `.otta.yml` `deploy.auto` policy text (e.g. "merged, deploy policy: human-approve — no auto-deploy configured") when there's nothing further to verify. Merged with a matching release → `pass`.

6. **Pulse gate_verdict (opt-in).** Only if both `OTTA_PULSE_URL` and `OTTA_PULSE_TOKEN` are set (check env, then `./.otta/pulse.env`):
   ```bash
   curl -fsS -m 5 "${OTTA_PULSE_URL%/}/idea?ref=<idea_ref>" \
     -H "x-pulse-token: ${OTTA_PULSE_TOKEN}" | jq .
   ```
   Use the returned `verdicts` (pass/fail counts on this idea's branches) as corroborating detail text on the **Gate** stage — e.g. append `"(Pulse: 3 pass / 1 fail on this idea)"`. A failed/timed-out call must never block rendering — swallow it and fall through to the `gh`-only signal. If the env vars aren't set at all, skip this step entirely and note in the Gate stage detail: `"Pulse not configured — gate status from gh checks only"`. Never treat "not configured" as an error.

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
   echo "$JSON" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-status.sh"
   ```
   Report the rendered checklist verbatim to the developer as your response.
