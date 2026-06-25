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

