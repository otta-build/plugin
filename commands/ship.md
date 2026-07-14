---
description: Run the Otta gate and open the PR with the seeded body
argument-hint: "[--base <branch>] [--environment <name>]"
---

Ship the current work through the Otta gate, then open the PR.

1. Make sure `.pr-body.md` is complete and honest:
   - Each acceptance criterion echoed with real evidence (test name, preview observation)
   - `idea_ref:` set to the real origin (e.g. `intercom:...`, `sentry:...`, or `issue:#N`)
   - `Fixes #<issue>` present
   - Either a test was added, or `[test-impractical: <reason>]` is in the body

2. Run the full local gate (mirrors the Otta Pulse merge gates — catches failures before CI):

   ```bash
   bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-gate.sh"
   ```

   If it fails, fix what it reports and re-run. Do not push past a failing gate.

3. Once green, commit, push the branch, and open the PR using the seeded body verbatim:

   ```bash
   gh pr create --body-file .pr-body.md --title "<conventional-commit title>" $ARGUMENTS
   ```

   Use `--base staging` if the repo's `.otta.yml` names a staging branch; otherwise `--base main` (the default).

After merge + release tag, Pulse ingests the PR/tag webhooks automatically. The `idea_ref` + `Fixes #N` in the body are what let Pulse join the idea→issue→PR→version chain — no extra step needed.

4. **Deploy+verify (per `.otta.yml` `deploy.auto` policy).** Once the PR is open, drive it through to deployment according to the repo's policy:

   ```bash
   bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-deploy-verify.sh" <pr-number> --environment <name>
   ```

   Resolve natural staging/production target intent to a configured environment; otherwise use `deploy.default`. Pass that resolved deployment environment explicitly with `--environment <name>` so Claude Code, Codex, and resumed sessions execute the same policy. An unknown or ambiguous target pauses instead of guessing. Legacy flat configuration omits the flag and resolves as `legacy`.

   The stage reads the `deploy` block from `.otta.yml`:
   - **`human-approve`** (default, and what an absent block resolves to) — without an executor, stops at the open PR exactly as before. With `executor: github-workflow`, show the exact repo, PR head, target, workflow, ref, and health URL; after explicit approval rerun with `--approved-head <exact-pr-head>`. A changed head invalidates approval.
   - **`merge-on-green`** — polls the Otta Gate until every sub-check is green (on stall it prints the blocking sub-check — e.g. a `ciGreen` stuck with no runner — instead of hanging), then squash-merges. Downstream deploy is handled outside Otta.
   - **`merge-and-deploy`** — legacy contracts merge then verify via the configured provider. With `executor: github-workflow`, Otta dispatches exactly one configured workflow for the merge SHA, polls it to terminal success, then verifies the live health commit.

   **Prod guard (AC5):** `target: production` with `auto: merge-and-deploy` is **rejected** unless `deploy.allow_production: true` is set in `.otta.yml` — no accidental hands-off prod deploys. Coolify creds are never baked into the plugin; they come from the environment.

   **One mutation authority.** For `executor: github-workflow`, the repository workflow is the only infrastructure mutator. Disable parallel provider/webhook triggers, use one production concurrency group with `cancel-in-progress: false`, reuse artifacts, and keep cleanup outside the deploy critical section. Put the exact SHA input in `run-name` as a standalone token; Otta requires that exact `display_title` marker and never substitutes `head_sha`, which identifies the workflow ref rather than proving the input received by that run. Because the local Otta lock does not span machines, the workflow must self-dedupe too: inside the global concurrency group, compare live health with the requested SHA and no-op successfully when it is already deployed. Otta stores only workflow/run/commit evidence; provider credentials stay in the workflow.

   **Recovery is explicit.** A normal retry resumes the recorded run. Inspect it with `gh run view <run-id> --log-failed` and the deploy records in `~/.otta/ledger/<repo>.jsonl`. Attach a known workflow-dispatch run to `dispatch_unknown` with `--resolve-run-id <run-id>`; retry a recorded failed run with `--retry-failed-run`. For rollback, invoke the repository's documented rollback workflow. Never guess among multiple runs or create a second ordinary deployment while dispatch state is uncertain.

   **Latest-wins is fail-closed.** GitHub's non-cancelling per-environment concurrency keeps one active mutation plus one latest pending request and coalesces intermediate pending runs. A queued/running dispatch is never approval proof and cannot preempt the active approved release. Without an explicitly configured durable eligibility source, preemptive supersession is disabled; an older request becomes `included` only after a descendant workflow succeeds and live runtime health reports that descendant SHA.
