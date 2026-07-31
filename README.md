# Otta — the self-learning AI software factory

A runtime-neutral agent plugin that turns coding sessions into a self-improving software factory. The **Otta loop**:

```
issue → acceptance criteria → local gate → PR → ship → Otta Pulse (DORA + lifecycle)
```

It's the *discipline layer* of Otta. It needs no private engine and no secrets — just `gh` + `jq` and (optionally) the Otta Pulse GitHub App for metrics.

## Install and invoke

### Claude Code

```
/plugin marketplace add otta-build/plugin
/plugin install --scope user otta@otta
```

> **After installing, fully restart Claude Code** (not just `/reload-plugins` — command registration needs a fresh process). If you don't see `/otta:` commands after restarting, the plugin is installed but **not enabled**: run `/plugin`, find **otta**, and toggle it **on**.
>
> Note: `otta@otta` = `<plugin>@<marketplace>` — both are named `otta` (the repo is `otta-build/plugin`, but the marketplace's manifest name is `otta`).

Then, once per repo:

```
/otta:setup
```

This runs a **guided wizard** that teaches why each step exists (pain → benefit), asks each question via structured chips (recommended default first), and writes `.otta.yml` + installs the pre-push gate hook and the **Otta Pulse** GitHub App. See [docs/why-otta-setup.md](docs/why-otta-setup.md) for the full pain→benefit table.

After setup, natural language is the normal interface in both Claude Code and Codex: ask to start an issue, fix a bug, check status, stage, or release, and the repository policy routes the matching canonical Otta lifecycle. Explicit `/otta:*` commands and `$otta-*` skills always win when supplied and remain the deterministic recovery/API surface. Read-only or status intent never authorizes writes; ambiguous production targets and rollbacks pause for clarification.

Claude Code invokes Otta through `/otta:*` commands, such as `/otta:start 131` and `/otta:ship`.

### Codex

Install Otta from Codex's Plugins surface. Codex reads `.codex-plugin/plugin.json` and exposes the workflows as native skills. Invoke them as `$otta-setup`, `$otta-start`, `$otta-dev`, `$otta-build`, `$otta-fix`, `$otta-ship`, `$otta-status`, `$otta-schedule`, `$otta-remember`, and `$otta-pulse-doctor`. A natural-language request matching a skill can also auto-trigger it; Codex does not use the Claude `/otta:*` command syntax.

## Claude Code commands

| Command | Does |
|---|---|
| `/otta:start <issue>` | Seed `.pr-body.md` from a GitHub issue's acceptance criteria |
| `/otta:dev <issue>` | Run the pipeline **interactively** — the builder can ask you mid-build |
| `/otta:build <issue>` | Run the pipeline **autonomously** as a workflow (unattended, can't ask) |
| `/otta:batch <issue> <issue> ...` | Run the pipeline across many issues **concurrently** — one PR each |
| `/otta:ship` | Run the local gate, then open the PR with the seeded body (manual ship) |
| `/otta:setup` | Install the pre-push gate hook + onboard the Pulse GitHub App |
| `/otta:pulse-doctor [owner/repo]` | Verify the Pulse GitHub App installation has `checks:write` |
| `/otta:schedule` | Set up a cloud routine that runs the pipeline autonomously (laptop-off) |

## Two ways to run the pipeline

Same four stages, two drivers — pick by whether you want to stay in the loop:

| | `/otta:dev` — interactive | `/otta:build` — autonomous |
|---|---|---|
| Driver | the agent in your live session (Task subagents) | a detached [workflow](https://code.claude.com/docs/en/workflows) |
| Builder can ask you? | **yes** — pauses for your decisions mid-build | no — returns `blocked` with the reason |
| Best for | real dev, ambiguous specs, "help me decide" | clear specs, overnight, CI-triggered, unattended |

Both run the same `builder → reviewer → qa → devops` stages and open a PR only if the gate + every AC pass.

## The pipeline (`/otta:build`)

`/otta:build <issue>` runs a [dynamic workflow](https://code.claude.com/docs/en/workflows) that orchestrates four focused subagents — the plan lives in code, so it's repeatable and the stages can't be skipped:

1. **Build** — `builder` implements test-first (TDD)
2. **Spec Review** — `reviewer` checks every AC is met, nothing extra (one fix loop)
3. **Verify** — `qa` runs the gate and *adversarially* verifies each AC has real evidence
4. **Ship** — `devops` opens the PR — **only if** the gate passed and every AC passed

The subagents (`agents/*.md`) are reusable on their own — Claude delegates to them by name, and you can use them as agent-team teammates too.

### `/otta:batch <issue> <issue> ...`

Run the gated pipeline across many issues **concurrently** — one worktree-isolated
lane and one PR per issue. Otta gates every lane identically; a failed lane never
aborts the batch. Rides the Workflow tool's native `parallel()` fan-out (Otta owns
the gate, not the scheduler). Concurrency self-throttles at `min(16, cores−2)`.

### Branch naming (`.otta.yml` `branch_pattern`)

Every stage runs in an isolated worktree from `scripts/otta-worktree.sh`, which by default branches as `otta/<issue>`. Some consumer repos gate PR branch names against a required pattern (e.g. a Linear-linked `(feat|fix)/team-N-slug` convention) and reject `otta/<issue>` outright — renaming a PR's head branch after the fact closes it on GitHub. Opt into a gate-compliant name with `branch_pattern` in `.otta.yml`:

```yaml
branch_pattern: "fix/lc-{issue}-{slug}"
```

`{issue}` always expands to the issue number. `{slug}` is optional and, only when present in the pattern, triggers a `gh issue view` title fetch — kebab-cased, conventional-commit prefix stripped, capped at 40 chars. If `gh` is unavailable or the title fetch fails, it falls back to `issue-<n>` rather than aborting the worktree. Omitting `branch_pattern` entirely keeps the legacy `otta/{issue}` default.

## Pipeline progress

Otta uses one progress protocol and each harness's best native surface:

- Claude Code interactive runs use native Task items and named Agent rows.
- Claude Code autonomous runs use native Workflow phases.
- Codex runs use one native plan plus native agent rows and the goal footer.
- `/otta:status` and `$otta-status` expose detailed durable evidence on demand.

The pipeline stage checklist is therefore rendered through native progress UI instead of duplicated as routine transcript prose.

Native progress is a projection, not the source of truth. Resumed runs reconstruct it from Otta ledger, PR, check, and deployment evidence. The projection changes only at meaningful stage transitions; routine in-stage narration stays out of the transcript.

Normal progress:

```
✔ Seed  ✔ Learn  ● Build — progress contracts  ○ Review  ○ QA  ○ Ship
```

Blocked attention event:

```
QA blocked · preview SHA 9ac21e7 does not match PR head b724ad1
Action: rebuild the preview for the current head.
```

Resumed run:

```
Resumed #139 · Build and Review verified from durable evidence
● QA — running the Otta gate
```

Completion:

```
Shipped #139 · PR #N · gate, review, and QA passed
Deploy policy: human approval required
```

If a harness has no native progress tool, Otta renders the selected compact stages once in Markdown. Failures still annotate the blocked stage with its reason and next action. `/otta:status` or `$otta-status` can reconstruct the detailed view from any session, even after the build agent finishes.

## Autonomous (`/otta:schedule`)

`/otta:schedule` sets up a **cloud routine** (runs on Anthropic infra, laptop-off) that nightly picks a ready issue and runs the pipeline to a PR. Add GitHub (`pull_request.opened` → review) or API (`/fire` → Sentry-alert→fix) triggers from claude.ai/code/routines.

## LEARN consultation and capture

Otta keeps these as independent controls under `.otta.yml`'s `learn:` block:

```yaml
learn:
  enabled: true       # legacy fallback for repositories not yet using both keys
  consult: true       # read active, non-expired repo LEARNINGS.md rules before work
  capture: true       # append gate/reviewer/QA verdicts to the local ledger
  expiry_days: 180
```

Override either decision for one run with `OTTA_LEARN_CONSULT=true|false` or `OTTA_LEARN_CAPTURE=true|false`; changing one never changes the other. `OTTA_NO_CAPTURE=1` remains a legacy capture opt-out. Each prepare attempt writes `.otta/run/learning-receipt.json` with decisions, provenance, rule IDs/count, and a consulted/skipped reason; it never copies session text or secrets. Otta adds `/.otta/run/` to Git's repository-local `info/exclude`, including from linked worktrees, so these inspectable artifacts do not become commit candidates and no tracked `.gitignore` is changed. That run-start receipt remains authoritative for later gate, reviewer, and QA capture even if config or environment overrides change; `capture --policy-receipt <path>` selects a non-default receipt, while a run without a prepare receipt safely resolves the current policy for backward compatibility. Capture-disabled verdicts stay out of `~/.otta/ledger/<repo>.jsonl` and produce only a metadata skip receipt under `.otta/run/`. `LEARNINGS.md` is the reviewable rule truth; the ledger is raw evidence and Pulse is the optional remote event spine—personal Brain, Mem0, and ChatGPT memory are not runtime dependencies.

## What the gate checks (local mirror of the Pulse merge gates)

- a ` ```acceptance ` fenced block in `.pr-body.md`
- a test in the diff, OR `[test-impractical: <reason>]`
- AC-layer tag enforcement (`[ui-layer]` / `[e2e]` ACs must have a preview URL or e2e evidence — unit tests alone are not sufficient)
- `Fixes #<issue>` — so the issue→PR link exists in GitHub
- `idea_ref:` — so Pulse can join idea → issue → PR → version

Failures surface **before** you push, not in CI. Bypass once with `OTTA_SKIP_GATE=1 git push`.

> **Review-thread gate: local vs. server split.** The local `otta-gate.sh` does not check for review-thread resolution — it cannot, because reviews only exist after the PR is open. The `review-thread` sub-check listed in `.otta.yml`'s `gates:` block is a *server-side* Pulse merge gate: it blocks the merge until every open review thread is resolved. The local gate catches the body/test/AC-layer checks before push; Pulse enforces the review-thread check at merge time.

> **PR body is branch-local.** Each branch maintains its own `.pr-body.md`; the copy on `main` is just whatever the last merged PR left behind. `/otta:setup` and `/otta:start` both run `scripts/install-merge-ours.sh`, which registers a `merge=ours` git driver and adds `.pr-body.md merge=ours` to `.gitattributes` — so merging or rebasing from main never overwrites your branch's body and never produces a conflict on that file.
>
> **Or don't track it at all.** If you'd rather `.pr-body.md` never enter git, add it to `.gitignore`. Otta detects that and skips the `merge=ours` driver entirely — it exists only to protect a *tracked* body, and installing it anyway would dirty `.gitattributes` on every seed. With the body untracked, the pre-push gate requires a freshly seeded one whenever your branch is ahead of the default branch, so nothing goes out ungated.

The gate fires at two points: a **pre-push** hook (blocks `git push`), and a **build-stage** hook (`SubagentStop`) that runs after the `otta:builder` subagent finishes — so a build stage can't report "done" past a failing gate; the reasons are fed back so it keeps fixing. Same `OTTA_SKIP_GATE=1` bypass.

## Post-merge deploy+verify (`.otta.yml` `deploy.auto`)

By default the loop stops at a green PR for a human to merge. Opt a repo into hands-off delivery with a `deploy` block in `.otta.yml` — universal and provider-pluggable, never over-fit to one platform:

```yaml
deploy:
  auto: human-approve
  target: production
  project: acme/widget
  executor: github-workflow
  workflow: deploy-production.yml
  ref: main
  sha_input: commit_sha
  provider: coolify
  verify: health-sha
  health_url: https://app.example.com/health
  health_commit_field: commit
```

The three modes:

| `auto` | What `/otta:ship`'s deploy stage does |
|---|---|
| `human-approve` *(default)* | Without an executor, stops at the open PR exactly as before. With `executor: github-workflow`, requires `--approved-head <exact-pr-head>`, invalidates approval after any push, then merges and dispatches the approved change. An already-merged approved PR dispatches without merging again. |
| `merge-on-green` | Polls the Otta Gate until **every** sub-check is green, then squash-merges. On a stall it prints the blocking sub-check (e.g. a `ciGreen` stuck with no runner) instead of hanging. Downstream deploy is handled outside Otta. |
| `merge-and-deploy` | Legacy contracts merge and verify through `provider`. With `executor: github-workflow`, Otta dispatches the configured repository workflow, polls it to terminal success, and then requires the live health SHA to match the merge SHA. |

**Production opt-in guard.** `target: production` with `auto: merge-and-deploy` is **rejected** unless `deploy.allow_production: true` is set — so no repo ships hands-off to prod by accident. Staging needs no opt-in.

**No baked-in infra.** The Coolify adapter reads `OTTA_COOLIFY_URL` / `_TOKEN` / `_APP_UUID` (and `OTTA_DEPLOY_HEALTH_URL` for `verify: health`) from the environment — no provider creds or org infra are shipped in the plugin.

### GitHub workflow mutation boundary and recovery

With `executor: github-workflow`, Otta owns approval, merge, dispatch identity, polling, and runtime verification. The configured GitHub workflow must remain the **only deployment mutation authority**: disable competing provider/webhook/Otta triggers, use one production concurrency group with `cancel-in-progress: false`, reuse build artifacts instead of rebuilding on the application host, and keep cleanup outside the deployment critical section. Otta needs GitHub Actions and PR permissions, not provider credentials.

The workflow must expose the resolved environment and exact SHA input as standalone `run-name` tokens, for example `run-name: deploy production ${{ inputs.commit_sha }}`. Otta snapshots runs for the configured workflow/ref and correlates only unseen runs created after dispatch by the authenticated actor whose `display_title` carries both exact tokens. A matching `head_sha` is never sufficient because it identifies the workflow ref, not necessarily the environment or SHA input received by that run; requiring both title markers remains correct when the dispatch ref advances. The local Otta lock only serializes processes sharing one ledger directory, so the workflow is also the cross-machine idempotency boundary: serialize all production deploys globally, then check the live commit at job start and exit successfully without mutation when it already equals the requested SHA. This makes a duplicate same-SHA dispatch harmless even across separate agents or hosts.

Normal production approval is commit-bound:

```bash
bash scripts/otta-deploy-verify.sh <pr> --approved-head <pr-head-sha>
```

Retries resume the recorded run and never redispatch an uncertain request. Inspect evidence with `jq 'select(.source=="deploy")' ~/.otta/ledger/<owner-repo>.jsonl` and `gh run view <run-id> --log-failed`. If correlation is unknown, select a verified existing run explicitly with `--resolve-run-id <run-id>`; Otta requires the configured workflow and ref, the recorded actor and dispatch time, a `workflow_dispatch` event, and the requested SHA as an exact standalone `display_title` token. The run's ref head may have advanced and does not need to equal the requested SHA. Retry a recorded failed run only by explicit operator action with `--retry-failed-run`. For rollback, invoke the target repository's documented rollback workflow (for example, `gh workflow run rollback.yml -f sha=<known-good-sha>`); Otta does not invent or bypass repository rollback logic.

## How it connects to Otta Pulse

Pulse is the GitHub App that ingests your PR/CI/tag webhooks into an append-only event store and computes DORA metrics. The default delivery integration is webhook-only: PR bodies carry the `Fixes #N` + `idea_ref` linkage that Pulse reads from the `pull_request` webhook, with no local secret. If you opt into agent telemetry or authenticated status lookups, local scripts also talk to Pulse and store an opt-in local repo token in a gitignored, mode-0600 harness config.

**Hosted or self-hosted.** By default Otta uses the hosted Pulse at `https://pulse.otta.build`. To run your own, set `OTTA_PULSE_URL` (e.g. `export OTTA_PULSE_URL=https://pulse.your-team.example`) before `/otta:setup` — every Otta script reads it, so a team can point the whole loop at a private Pulse with no code changes.

### Pulse App doctor

If a normal `gh api repos/<owner>/<repo>/installation` call returns an auth-type
error, use the Pulse doctor instead of treating the user token as evidence. It
uses the GitHub App's own JWT to find the repo installation, mint an installation
token, and confirm `checks: write`:

```bash
export OTTA_PULSE_APP_ID=<app-id>
export OTTA_PULSE_PRIVATE_KEY_PATH=/path/to/github-app-private-key.pem
OTTA_PLUGIN_ROOT=/absolute/path/to/installed/otta
bash "$OTTA_PLUGIN_ROOT/scripts/otta-pulse-doctor.sh" <owner/repo>
```

The doctor prints installation metadata and permission status only; it never
prints the minted installation token.

## Agent telemetry → Pulse (opt-in)

Pulse's GitHub App captures PR/CI/tag webhooks without agent telemetry. Opting in adds runtime evidence: logs describe agent/tool events, metrics provide aggregate counters and timing, and Claude can additionally emit beta traces. Each repo uses its own `x-pulse-token`; token-bearing config remains local and ignored.

### Claude Code

`/otta:setup` can wire Claude Code's OTEL environment into `.claude/settings.local.json`. Claude events are attributed with `OTEL_RESOURCE_ATTRIBUTES=repo=<owner/repo>,harness=claude_code`.

This is **CC-process-level**: once enabled, **every** Claude Code session in the repo emits to Pulse (not just `/otta:dev`). Token-bearing values go **only** into `.claude/settings.local.json` (gitignored) — never the committed `settings.json`.

> **Where your telemetry lands.** The endpoint base is `OTTA_PULSE_URL`, which **defaults to Otta's hosted Pulse (`https://pulse.otta.build`) — Otta receives that telemetry** (cost, tokens, tool timing, repo name). To keep it entirely in your own infrastructure, set `OTTA_PULSE_URL` to your self-hosted Pulse **before** enabling.

- **Logs and metrics** (default) — event records, counters, and timing.
- **Traces** (separate opt-in, **beta**) — spans; adds `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`.

Prefer `/otta:setup`. It writes the repo-scoped token to `.otta/pulse.env` and
verifies repository access plus `checks:write` through the customer-safe
installation-status endpoint. For non-interactive automation, supply the
absolute root of the installed plugin yourself; hosted telemetry reuses
`.otta/pulse.env`, while self-hosted Pulse requires its operator webhook secret
only for token derivation:

```bash
OTTA_PLUGIN_ROOT=/absolute/path/to/installed/otta
# hosted, logs + metrics:
bash "$OTTA_PLUGIN_ROOT/scripts/otta-telemetry-setup.sh" <owner/repo>
# self-hosted, logs + metrics + traces (beta):
OTTA_PULSE_URL=https://pulse.example.com bash "$OTTA_PLUGIN_ROOT/scripts/otta-telemetry-setup.sh" <owner/repo> <webhook-secret> --traces
```

**Manual block** (for non-`/otta:setup` users) — put in `.claude/settings.local.json` (gitignored), substituting your `${PULSE}` base, `<repo-token>`, and `<owner/repo>`:

```jsonc
{
  "env": {
    // logs (default)
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "${PULSE}/v1/logs",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "${PULSE}/v1/metrics",
    "OTEL_EXPORTER_OTLP_HEADERS": "x-pulse-token=<repo-token>",
    "OTEL_RESOURCE_ATTRIBUTES": "repo=<owner/repo>,harness=claude_code",
    // traces (beta — add only if you want spans)
    "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
    "OTEL_TRACES_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "${PULSE}/v1/traces"
  }
}
```

### Codex

Codex reads OTEL settings from `$CODEX_HOME/config.toml` (normally `~/.codex/config.toml`), not Claude's environment block. Run `$otta-setup` and choose Codex telemetry; the skill resolves its installed plugin directory and reuses the repo token from `.otta/pulse.env`.

For non-interactive automation, use the same user-supplied absolute installed root. In hosted mode, `--derive` is retained for compatibility but reads `.otta/pulse.env` and never calls the admin `/token` endpoint. Self-hosted derivation reads `OTTA_PULSE_WEBHOOK_SECRET`. Direct mode reads an already-derived token from `OTTA_PULSE_TOKEN`, keeping both secrets out of argv and shell history:

```bash
OTTA_PLUGIN_ROOT=/absolute/path/to/installed/otta
bash "$OTTA_PLUGIN_ROOT/scripts/otta-codex-setup.sh" --derive <owner/repo>
# self-hosted derivation, with OTTA_PULSE_WEBHOOK_SECRET already supplied by
# your secure runtime environment:
OTTA_PULSE_URL=https://pulse.example.com \
  bash "$OTTA_PLUGIN_ROOT/scripts/otta-codex-setup.sh" --derive <owner/repo>
# direct mode, with OTTA_PULSE_TOKEN already supplied by the environment:
bash "$OTTA_PLUGIN_ROOT/scripts/otta-codex-setup.sh" <owner/repo>
```

Legacy positional compatibility remains available for existing automation (`<owner/repo> <repo-token>` and `--derive <owner/repo> <webhook-secret>`), but new automation should use the environment variables above so secrets do not appear in process arguments or history.

The writer enables both `exporter = "otlp-http"` and `metrics_exporter = "otlp-http"`, keeps JSON protocol endpoints for `/v1/logs` and `/v1/metrics`, and stores `x-pulse-token` plus `x-pulse-repo` headers only in mode-0600 local files. `x-pulse-repo` is part of the required ingestion contract for attributing Codex conversation and model metadata; this plugin does not claim server-side validation until the corresponding Pulse change ships. `.otta/codex.env` remains a safely quoted, gitignored compatibility artifact and is not how Codex enables telemetry. Start a new Codex process after setup so it loads the updated `config.toml`.

## Scope

This plugin is the discipline layer. The autonomous loop engine (scheduled `sense→score→govern→act→learn` runs) and direct lifecycle emission are separate components — see the Otta roadmap.

## License

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
