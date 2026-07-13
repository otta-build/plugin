---
description: Run the Otta gate and open the PR with the seeded body
argument-hint: "[--base <branch>]"
---

Ship the current work through the Otta gate, then open the PR.

1. Make sure `.pr-body.md` is complete and honest:
   - Each acceptance criterion echoed with real evidence (test name, preview observation)
   - `idea_ref:` set to the real origin (e.g. `intercom:...`, `sentry:...`, or `issue:#N`)
   - `Fixes #<issue>` present
   - Either a test was added, or `[test-impractical: <reason>]` is in the body

2. Run the full local gate (mirrors the Otta Pulse merge gates — catches failures before CI):

   ```bash
   bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/otta-gate.sh"
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
   bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/otta-deploy-verify.sh" <pr-number>
   ```

   The stage reads the `deploy` block from `.otta.yml`:
   - **`human-approve`** (default, and what an absent block resolves to) — stops at the open PR. The human merges. This preserves today's behavior exactly; nothing auto-merges.
   - **`merge-on-green`** — polls the Otta Gate until every sub-check is green (on stall it prints the blocking sub-check — e.g. a `ciGreen` stuck with no runner — instead of hanging), then squash-merges. Downstream deploy is handled outside Otta.
   - **`merge-and-deploy`** — merges on green, then verifies the deploy reached the merged SHA via the configured `provider` (Coolify adapter reads `OTTA_COOLIFY_*` from the env; `provider: none` is the generic path), optionally probes a health endpoint, and reports the live URL + SHA or the exact failing step.

   **Prod guard (AC5):** `target: production` with `auto: merge-and-deploy` is **rejected** unless `deploy.allow_production: true` is set in `.otta.yml` — no accidental hands-off prod deploys. Coolify creds are never baked into the plugin; they come from the environment.
