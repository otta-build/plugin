## 0.16.1

### Fixed
- `scripts/otta-telemetry-setup.sh` now writes the OTLP **metrics** exporter (`OTEL_METRICS_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/json`, `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=<pulse>/v1/metrics`). Previously only the logs (and optional traces) exporters were configured — but Claude Code emits its cost/token/model data **only** as OTLP metrics, never as logs/traces. Onboarded repos therefore sent nothing usable to Pulse and `/compare` stayed empty. Verified end-to-end: with the generated config, `claude` POSTs `claude_code.cost.usage` + `claude_code.token.usage` to `/v1/metrics`. Companion server fix: otta-build/pulse#50 (Pulse materializes `agent_run` from these metrics). (plugin#43)

## 0.16.0

### Added
- `scripts/otta-codex-setup.sh` — Codex CLI telemetry adapter: writes `.otta/codex.env` with standard OTEL env vars pointing to Pulse; gitignored (token-bearing); opt-in with consent disclosure
- `scripts/otta-gemini-setup.sh` — Gemini CLI telemetry adapter: writes `.gemini/settings.json` (`enabled: true`, `otlpEndpoint`, `otlpProtocol: http/json`) + `otel-collector-config.yaml` sidecar (injects auth header via `${env:OTTA_PULSE_TOKEN}`, repo+harness attrs, cost_usd from tokens); opt-in with consent disclosure
- Both adapters: idempotent; mirror the CC adapter pattern from v0.13.0

### Changed
- `scripts/otta-telemetry-setup.sh` — second arg changed from `<pulse-token>` to `<webhook-secret>`; script calls `GET /token?repo=<slug>` on Pulse to derive the correct per-repo HMAC token automatically; webhook secret never written to any file — only the derived token lands in `settings.local.json`
- `commands/setup.md` Step 8 — asks for webhook secret instead of raw pulse token

## 0.15.0 — awesome wizard: live gate demo + readiness score + meta-flex + first-PR-in-2-min
- **feat(setup):** Four opt-in "awesome" features added to the guided wizard — all terminal-feasible, all skippable. (1) Live gate demo (`scripts/otta-gate-demo.sh`): shows the gate go RED (no test) → GREEN (test added) in a throwaway `mktemp -d`; never touches the user's repo; offered via AskUserQuestion at setup start. (2) Meta-flex copy in setup intro + `docs/why-otta-setup.md`: "This very wizard shipped through the Otta loop — QA caught a real gap (#26 AC3, the Pulse step had no opt-out) → fixed → gated → merged. Proof by self-application." (3) Factory Readiness Score (`scripts/otta-readiness.sh`): scores 0–8 across base/staging, CI, branch protection, gate hook, Pulse, sandbox credentials, telemetry, `.otta.yml`; pure read-only, degrades gracefully when `gh` absent; shown at setup START and END. (4) First-PR-in-2-min: AskUserQuestion at setup end offers to invoke `/otta:start <issue>` immediately. (#28)
- **scripts:** `scripts/otta-gate-demo.sh` — isolated demo (mktemp, subshell, trap cleanup, explicit root SHA as base-ref, local git identity, no cwd change). `scripts/otta-readiness.sh` — 8-dimension readiness probe, `set -euo pipefail`-safe (each probe guarded with `|| true` / boolean flag; no single failure aborts), exits 0 always.
- **test:** `tests/otta-gate-demo.test.sh` — demo exits 0, red narration present, green narration present, cwd unchanged, no new files in plugin repo. `tests/otta-readiness.test.sh` — score math: 0/8 (bare repo), 8/8 (all dims; gh stubbed via PATH), 4/8 (partial); read-only verified; per-dim ✓/✗ list present. `tests/setup-wizard.test.sh` extended with 4 new asserts (meta-flex, gate-demo AskUserQuestion, readiness at start+end positional, first-PR AskUserQuestion).
- **version:** 0.14.0 → 0.15.0. No regression of v0.14.0 wizard or v0.13.1 telemetry disclosure.

## 0.14.0 — guided setup wizard: teach (pain→benefit) + structured AskUserQuestion at each step
- **feat(setup):** `/otta:setup` rewritten as a guided wizard. Every decision step now (a) teaches — states the pain it solves and the benefit — and (b) asks via Claude Code's structured `AskUserQuestion` tool (chips, recommended/safe default first, one-line tradeoff per option). Steps: base/staging confirm, deploy.auto policy, production opt-in guard, ci.required confirm, Pulse App, sandbox.credentials, CI workflow scaffold, local gate hook, telemetry (logs + traces separate opt-in). Adds a "why Otta" spine intro at the top and a write-summary ("here is what I will write — confirm?") + payoff line at the end. **Outputs unchanged** — `.otta.yml`, `.claude/settings.local.json`, defaults, back-compat identical to v0.13.1; telemetry data-destination disclosure (v0.13.1) preserved in structured option descriptions. (#26)
- **docs:** new `docs/why-otta-setup.md` holds the reusable pain→benefit value table (landing / README can pull from it); linked from `setup.md` intro.
- **test:** `tests/setup-wizard.test.sh` — spine intro present, per-step teach-blurb + AskUserQuestion directive for each of 8+ decision steps, write-summary step, telemetry destination disclosure regression guard (`pulse.otta.build` + "Otta receives"), `docs/why-otta-setup.md` exists.

## 0.13.1 — telemetry consent: disclose data destination
- **fix(setup):** the `/otta:setup` step-8 telemetry consent + README now state **where the data lands** — by default it streams to Otta's *hosted* Pulse (`pulse.otta.build`), which Otta receives; self-host by setting `OTTA_PULSE_URL` first. Prior text stated the process-level scope but not the destination — a trust gap for a tool positioned on neutrality. Consent/disclosure text only; no behavior change. (#24)

## 0.13.0 — Claude Code OTEL telemetry → Pulse (emit side)
- **feat(setup):** new opt-in `/otta:setup` step turns on Claude Code's OTEL telemetry so per-tool/per-stage timing (logs) and spans (traces) flow into Pulse — completing the emit side of the #38 receiver. Telemetry is **CC-process-level**: once enabled, every Claude Code session in the repo emits (not just `/otta:dev`), and the consent prompt states this. (#22)
- **feat(telemetry):** `scripts/otta-telemetry-setup.sh <owner/repo> <pulse-token> [--traces]` merges the OTEL `env` block into `.claude/settings.local.json` (gitignored, token-bearing — **never** the committed `settings.json`) via python3 — merge-into-existing, never clobber, idempotent on re-run. Logs are the default (`CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_LOGS_EXPORTER=otlp`, `…_LOGS_PROTOCOL=http/json`, `…_LOGS_ENDPOINT=${PULSE}/v1/logs`, `OTEL_EXPORTER_OTLP_HEADERS=x-pulse-token=…`, `OTEL_RESOURCE_ATTRIBUTES=repo=…`); `--traces` is a separate beta opt-in adding `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` + the traces exporters. Endpoint base from `OTTA_PULSE_URL` (default `https://pulse.otta.build`, self-host override); repo + token reuse the existing `.otta/pulse.env` wiring. The script also ensures `.gitignore` covers `.claude/settings.local.json`.
- **docs:** `/otta:setup` step + README document the env block (incl. the manual block for non-setup users) and the logs-default / traces-beta split.
- **test:** `tests/otta-telemetry-setup.test.sh` — logs-only default (6 vars, no traces); `--traces` adds the 4 beta/traces vars; `OTTA_PULSE_URL` override (else default); MERGE preserves a pre-existing `env` var + other top-level keys with valid JSON out; token lands only in the gitignored `settings.local.json` (verified with `git check-ignore`, never staged); idempotent re-run (stable, no dupes).

## 0.12.0 — post-merge deploy+verify stage
- **feat(deploy):** new post-merge `deploy+verify` stage drives a green PR through to deployment per a per-repo `.otta.yml` `deploy` policy. `scripts/otta-deploy-verify.sh` parses the policy, polls the Otta Gate to green (surfacing the blocking sub-check — e.g. a CI check stuck with no runner — instead of hanging), merges only when policy allows AND every sub-check is green, and (for `merge-and-deploy`) verifies the deploy by provider SHA-match + optional health probe. (#20)
- **feat(.otta.yml):** `deploy` block gains `auto` (`human-approve` | `merge-on-green` | `merge-and-deploy`), `target` (`production` | `staging`), `provider` (`coolify` | `vercel` | `tauri` | `none`), `verify` (`sha-match` | `health` | `none`), and `allow_production`. **Back-compat:** an absent `deploy` block (or absent `auto`) resolves to `human-approve` — existing repos stop at the green PR exactly as before. `detect-delivery-context.sh` now emits these keys (`target` = environment, `provider` = platform); `mode`/`package_paths` retained as informational.
- **feat(guard):** `target: production` + `auto: merge-and-deploy` is rejected unless `deploy.allow_production: true` — no accidental hands-off prod deploys (AC5). Provider logic is pluggable and env-driven (Coolify reads `OTTA_COOLIFY_*`); no infra/creds baked into the plugin.
- **docs:** `/otta:setup` asks/writes the `deploy` policy; README documents the three modes + the prod opt-in guard; `/otta:ship`, `/otta:dev`, `/otta:build` invoke/note the stage.
- **test:** `tests/otta-deploy-verify.test.sh` (policy parsing per `auto` value, absent → human-approve, prod+merge-and-deploy without opt-in rejected, gate-poll stall surfaces the blocker, SHA-match pass/fail, default never-merges); `detect-delivery-context.test.sh` extended for the new keys.

## 0.11.5 — gate no-origin fix
- **fix(gate):** `check-test-coverage.sh` no longer crashes under `set -e` on a repo with no `origin/HEAD` (fresh clone / local-only — any team's first run). BASE detection degrades origin → local default → root commit. Found by a fresh-repo onboarding test. (#19)

## 0.11.4 — self-host docs
- Documented the `OTTA_PULSE_URL` self-host override in `/otta:setup` + README — a team can point the whole loop at its own Pulse with no code change (hosted default unchanged). (#17)

## 0.11.3 — sandbox.credentials hardening
- `/otta:setup` now offers (opt-in) to write `.claude/settings.json` `sandbox.credentials`, so the pipeline's Bash commands can't read credential files / token env vars. Sandbox-mode trade-offs (filesystem + network isolation, platform reqs) are stated; written only on consent. (#15)

## 0.11.2 — pipeline invokes learn-from-pulse
- `/otta:dev` and `/otta:build` now run the `learn-from-pulse` skill after seeding and before the builder — the skill existed but nothing invoked it, so the online LEARN step never ran. Now automatic; no-ops when Pulse isn't configured. (#13)

## 0.11.1 — judgment stages → opus
- Pipeline `reviewer` + `qa` pinned to `opus` (builder/devops stay `sonnet`). The judgment stages drive defect-catch rate — opus reviewers caught a real privacy BLOCKER that a passing test suite and the gate both missed. (#11)

## 0.11.0 — SubagentStop gate
- New `SubagentStop` hook runs `otta-gate.sh` when the `otta:builder` subagent finishes — a build stage can no longer report "done" past a failing gate; the failing-check detail is fed back so it keeps fixing. Scoped to the builder, guarded by `.pr-body.md` presence + `OTTA_SKIP_GATE`. (#9)

## 0.10.2 — onboarding minors
- N2: an empty `BASE...HEAD` diff now prints "no changes to gate yet" (exit 0) instead of a false coverage failure. N3: `/otta:setup` auto-detects `ci.required` from branch protection (confirm-only). (#7)

## 0.10.1 — onboarding-eval fixes

Fixes found by a fresh-eyes onboarding-UX eval (2026-06-24):
- **macOS BLOCKER:** `pulse-install.sh` used GNU-only `head -n -1` → crashed before writing `.otta/pulse.env`. The v0.10.0 zero-paste wiring was broken on macOS. Now uses portable `sed '$d'` (verified end-to-end on macOS).
- Removed the dead `/event` ledger bridge (per-repo token → 401; printed confusing "(pulse push skipped)" every gate run). The `/ledger` stream is the real path.
- Schema-name drift: `ship/fix/schedule/builder/devops/workflow` read `.selfloop.yml` while setup writes `.otta.yml` → staging routing silently broke. Renamed all refs to `.otta.yml`.
- First-gate error pointed at non-existent commands (`/otta-start`, `otta seed`) → now `/otta:start <issue>`.
- README: `/plugin install otta` → `otta@otta`; added the missing **enable + restart** nudge (the #1 historical onboarding blocker) + `otta@otta` naming note.

## 0.10.0 — zero-paste Pulse wiring

- **Zero-paste Pulse wiring** — `/otta:setup` now connects the repo to Pulse automatically: it proves repo access with your `gh` token, gets a per-repo scoped token, and writes a gitignored `.otta/pulse.env` for you. No token to paste, no `~/.zshrc` edit, secret never in git. The gate streams pre-merge verdicts best-effort (non-blocking). Removes the old dead manual shell-profile step.
- Requires the matching Pulse endpoints (`/connect`, `/ledger`).

## 0.9.0 — first release on otta-build/plugin (org polyrepo)

The plugin's new canonical home is **otta-build/plugin**. Install: `/plugin marketplace add otta-build/plugin` → `/plugin install otta@otta`.

- **otta:fix** — tiered fast-path: tiny changes stay cheap but still GATED + traceable (never direct-to-main, never ungated). Review depth scales with size; the gate never skips.
- **otta:setup v2** — detects delivery context (base/staging/CI/deploy), writes a schema-valid `.otta.yml`, onboards the Pulse App.
- **otta:qa real-sample dry-run** — for heuristic ACs, qa runs the code on REAL project data, not just the author's fixture (ADR-0006).
- Carries the full v0.8.x base: worktree isolation + `--prune`, reviewer/qa verdict capture, Pulse push bridge, the `learn-from-pulse` skill.

