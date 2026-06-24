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

