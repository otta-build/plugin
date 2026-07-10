# Otta — the self-learning AI software factory

A Claude Code plugin that turns any agent session into a self-improving software factory. The **Otta loop**:

```
issue → acceptance criteria → local gate → PR → ship → Otta Pulse (DORA + lifecycle)
```

It's the *discipline layer* of Otta. It needs no private engine and no secrets — just `gh` + `jq` and (optionally) the Otta Pulse GitHub App for metrics.

## Install

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

## Commands

| Command | Does |
|---|---|
| `/otta:start <issue>` | Seed `.pr-body.md` from a GitHub issue's acceptance criteria |
| `/otta:dev <issue>` | Run the pipeline **interactively** — the builder can ask you mid-build |
| `/otta:build <issue>` | Run the pipeline **autonomously** as a workflow (unattended, can't ask) |
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

## Pipeline stage checklist UX

Every `/otta:dev` and `/otta:build` run creates a **stage checklist** at run start — one item per pipeline stage — so you always know where a run is without reading the full log:

```
[ ] Seed     — seed .pr-body.md from the issue
[✓] Learn    — consulted Pulse; no prior escapes for this idea
[→] Build    — builder implementing test-first (in progress)
[ ] Review   — spec-review
[ ] QA       — gate + adversarial AC verification
[ ] Ship     — commit + open PR
[ ] Deploy   — deploy-verify per .otta.yml policy
```

On a task-aware harness (Claude Code), each stage updates the task tool's `activeForm` — so the **agent switcher** shows "Building #105" or "QA #105" per agent without you having to ask. On harnesses without a native task tool, the checklist renders as a markdown block in chat and is updated at each stage transition.

**Failures annotate the stage:** `✗ QA — gate failed: tsc errors in src/foo.ts` so you see the blocker at a glance.

**`/otta:status` shows the same checklist** for in-flight runs, inferred from the LEARN ledger + PR check state — queryable from any session, even after the build agent has finished.

## Autonomous (`/otta:schedule`)

`/otta:schedule` sets up a **cloud routine** (runs on Anthropic infra, laptop-off) that nightly picks a ready issue and runs the pipeline to a PR. Add GitHub (`pull_request.opened` → review) or API (`/fire` → Sentry-alert→fix) triggers from claude.ai/code/routines.

## LEARN-layer capture (free)

Every gate run appends a `{score, feedback}` record to a local ledger at `~/.otta/ledger/<repo>.jsonl` — a file write, **zero LM tokens**. With the plugin installed at user scope this accrues across **every project you push from**, building the trainset for future GEPA prompt optimization (ADR-0004) with no extra work. Opt out per-run with `OTTA_NO_CAPTURE=1`; relocate with `OTTA_LEDGER_DIR`.

## What the gate checks (local mirror of the Pulse merge gates)

- a ` ```acceptance ` fenced block in `.pr-body.md`
- a test in the diff, OR `[test-impractical: <reason>]`
- AC-layer tag enforcement (`[ui-layer]` / `[e2e]` ACs must have a preview URL or e2e evidence — unit tests alone are not sufficient)
- `Fixes #<issue>` — so the issue→PR link exists in GitHub
- `idea_ref:` — so Pulse can join idea → issue → PR → version

Failures surface **before** you push, not in CI. Bypass once with `OTTA_SKIP_GATE=1 git push`.

> **Review-thread gate: local vs. server split.** The local `otta-gate.sh` does not check for review-thread resolution — it cannot, because reviews only exist after the PR is open. The `review-thread` sub-check listed in `.otta.yml`'s `gates:` block is a *server-side* Pulse merge gate: it blocks the merge until every open review thread is resolved. The local gate catches the body/test/AC-layer checks before push; Pulse enforces the review-thread check at merge time.

> **PR body is branch-local.** Each branch maintains its own `.pr-body.md`; the copy on `main` is just whatever the last merged PR left behind. `/otta:setup` and `/otta:start` both run `scripts/install-merge-ours.sh`, which registers a `merge=ours` git driver and adds `.pr-body.md merge=ours` to `.gitattributes` — so merging or rebasing from main never overwrites your branch's body and never produces a conflict on that file.

The gate fires at two points: a **pre-push** hook (blocks `git push`), and a **build-stage** hook (`SubagentStop`) that runs after the `otta:builder` subagent finishes — so a build stage can't report "done" past a failing gate; the reasons are fed back so it keeps fixing. Same `OTTA_SKIP_GATE=1` bypass.

## Post-merge deploy+verify (`.otta.yml` `deploy.auto`)

By default the loop stops at a green PR for a human to merge. Opt a repo into hands-off delivery with a `deploy` block in `.otta.yml` — universal and provider-pluggable, never over-fit to one platform:

```yaml
deploy:
  auto: human-approve   # human-approve | merge-on-green | merge-and-deploy
  target: production    # production | staging — environment a merge ships to
  provider: coolify     # coolify | vercel | tauri | none (generic)
  verify: sha-match     # sha-match | health | none
  allow_production: false  # explicit opt-in for hands-off prod (see guard below)
```

The three modes:

| `auto` | What `/otta:ship`'s deploy stage does |
|---|---|
| `human-approve` *(default)* | Stops at the open PR — the human merges. **An absent `deploy` block resolves to this**, so existing repos are unchanged. Never auto-merges. |
| `merge-on-green` | Polls the Otta Gate until **every** sub-check is green, then squash-merges. On a stall it prints the blocking sub-check (e.g. a `ciGreen` stuck with no runner) instead of hanging. Downstream deploy is handled outside Otta. |
| `merge-and-deploy` | Merges on green, then verifies the deploy reached the merged SHA via `provider` (Coolify adapter, or `none` for the generic path), optionally probes a `health` URL, and reports the live URL + SHA or the exact failing step. |

**Production opt-in guard.** `target: production` with `auto: merge-and-deploy` is **rejected** unless `deploy.allow_production: true` is set — so no repo ships hands-off to prod by accident. Staging needs no opt-in.

**No baked-in infra.** The Coolify adapter reads `OTTA_COOLIFY_URL` / `_TOKEN` / `_APP_UUID` (and `OTTA_DEPLOY_HEALTH_URL` for `verify: health`) from the environment — no provider creds or org infra are shipped in the plugin.

## How it connects to Otta Pulse

Pulse is the GitHub App that ingests your PR/CI/tag webhooks into an append-only event store and computes DORA metrics. This plugin doesn't talk to Pulse directly — it makes sure every PR body carries the `Fixes #N` + `idea_ref` linkage, which **Pulse already reads from the `pull_request` webhook**. No extra auth, no secret on your machine.

**Hosted or self-hosted.** By default Otta uses the hosted Pulse at `https://pulse.otta.build`. To run your own, set `OTTA_PULSE_URL` (e.g. `export OTTA_PULSE_URL=https://pulse.your-team.example`) before `/otta:setup` — every Otta script reads it, so a team can point the whole loop at a private Pulse with no code changes.

### Pulse App doctor

If a normal `gh api repos/<owner>/<repo>/installation` call returns an auth-type
error, use the Pulse doctor instead of treating the user token as evidence. It
uses the GitHub App's own JWT to find the repo installation, mint an installation
token, and confirm `checks: write`:

```bash
export OTTA_PULSE_APP_ID=<app-id>
export OTTA_PULSE_PRIVATE_KEY_PATH=/path/to/github-app-private-key.pem
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-pulse-doctor.sh" <owner/repo>
```

The doctor prints installation metadata and permission status only; it never
prints the minted installation token.

## Claude Code telemetry → Pulse (opt-in)

Pulse's GitHub App captures PR/CI/tag webhooks with no machine setup. To also feed **Claude Code's own OTEL telemetry** — per-tool/per-stage timing (logs) and spans (traces) — into Pulse, `/otta:setup` offers an opt-in step that wires Claude Code's `env` block.

This is **CC-process-level**: once enabled, **every** Claude Code session in the repo emits to Pulse (not just `/otta:dev`). Token-bearing values go **only** into `.claude/settings.local.json` (gitignored) — never the committed `settings.json`.

> **Where your telemetry lands.** The endpoint base is `OTTA_PULSE_URL`, which **defaults to Otta's hosted Pulse (`https://pulse.otta.build`) — Otta receives that telemetry** (cost, tokens, tool timing, repo name). To keep it entirely in your own infrastructure, set `OTTA_PULSE_URL` to your self-hosted Pulse **before** enabling.

- **Logs** (default) — timing/event records.
- **Traces** (separate opt-in, **beta**) — spans; adds `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`.

Run it directly (or via the `/otta:setup` step, which sources the repo + token from `.otta/pulse.env`):

```bash
# logs only:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" <owner/repo> <pulse-token>
# logs + traces (beta):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" <owner/repo> <pulse-token> --traces
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
    "OTEL_EXPORTER_OTLP_HEADERS": "x-pulse-token=<repo-token>",
    "OTEL_RESOURCE_ATTRIBUTES": "repo=<owner/repo>",
    // traces (beta — add only if you want spans)
    "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
    "OTEL_TRACES_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL": "http/json",
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "${PULSE}/v1/traces"
  }
}
```

## Scope

This plugin is the discipline layer. The autonomous loop engine (scheduled `sense→score→govern→act→learn` runs) and direct lifecycle emission are separate components — see the Otta roadmap.
