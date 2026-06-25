---
description: Set up Otta in this repo — guided wizard that teaches (pain→benefit) at each step, then writes .otta.yml + installs the gate hook and the Pulse GitHub App
---

# Why Otta? (read this once, then proceed)

AI agents code fast but quality is inconsistent — defects ship, runs forget context, and "is this production-ready?" is a guess. This setup wires Otta's gated TDD pipeline into THIS repo (~2 min):

- **Gates, not prompts, guarantee quality** — nothing broken can merge; every PR is reviewed + verified by specialist subagents before the gate opens.
- **Pulse records every verdict so the factory learns** — DORA metrics (deploy frequency, lead time, change-failure rate) and escape detection come free.
- **DORA + cost visibility, free** — $/PR, tokens used, and per-stage timing surface automatically once telemetry is on.

> Full pain→benefit table: [docs/why-otta-setup.md](../docs/why-otta-setup.md)

---

## 1. Detect delivery context

Run the detection script to auto-fill what can be determined from the repo:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-delivery-context.sh" --output .otta.yml
```

Show the developer the pre-filled `.otta.yml`. It will contain the detected `base`, `staging`, CI workflow names and `paths:` filters, and any `deploy` signal found in the workflow files.

---

## 2. Confirm or override: base and staging branches

**Pain this solves:** Otta must know your branch flow to route PRs and deploys correctly.
**Benefit you get:** PRs auto-target the right branch; staging-accumulate → promote works without manual config.

Ask via AskUserQuestion — header "Branch flow", question "Confirm the detected base and staging branches (or override):":
- "Use detected: `{detected_base}` base → confirm" (recommended, safe default) — uses what the script found; no change needed
- "Override base branch" — enter a different base branch name
- "Override both base + staging" — enter base and staging manually

Apply the answer to `.otta.yml` `base` and `staging` fields.

---

## 3. Deploy automation policy

**Pain this solves:** How far should the pipeline drive? Stop at a green PR? Auto-merge? Auto-deploy to production?
**Benefit you get:** You pick the safety level. `human-approve` ships nothing without you — never an accidental prod deploy. You can tighten or loosen per repo at any time.

Ask via AskUserQuestion — header "Deploy automation", question "What should `/otta:ship` do once the PR is green?":
- "human-approve (recommended)" — stop at the green PR; you merge. Safest, no accidental prod. An absent `deploy` block also resolves to this — existing repos are unaffected.
- "merge-on-green" — auto-merge once every Otta Gate sub-check is green; downstream deploy handled outside Otta
- "merge-and-deploy" — merge on green, then verify the deploy reached the merged SHA and report the live URL

Set `deploy.auto` to the chosen value.

### 3b. Production opt-in guard (only for `merge-and-deploy` targeting production)

**Pain this solves:** Hands-off production deploys are powerful but risky — a misconfigured gate could ship a broken build.
**Benefit you get:** The guard requires explicit opt-in; no accidental hands-off production deploys.

If the developer chose `merge-and-deploy` AND `deploy.target` is `production`, ask via AskUserQuestion — header "Production safety", question "Permit hands-off production deploys? This is a one-time explicit opt-in.":
- "No, keep the production guard (recommended)" — `allow_production` stays `false`; merge-and-deploy stops before production
- "Yes, permit hands-off production deploy" — set `deploy.allow_production: true`

Fill `deploy.allow_production` accordingly.

### 3c. Non-detectable deploy fields

Ask the developer for any fields the detection script left as placeholders:
- **deploy.mode** — what does "deployed" mean? (`"auto-on-merge"`, `"tag"`, `"manual"`, `"none"`)
- **deploy.provider** — which platform? (`coolify`, `vercel`, `tauri`, or `none`)
- **deploy.target** — which environment? (`production` or `staging`)
- **deploy.verify** — how is a deploy confirmed? (`sha-match` — default; `health`; `none`)

Fill these into `.otta.yml` before continuing.

---

## 4. Required CI checks

**Pain this solves:** You need one authoritative "is this production-ready?" signal that every agent and the gate obey.
**Benefit you get:** The gate aggregates YOUR CI checks — agents can't merge red; no green-but-broken surprises.

First, auto-detect — don't just ask. Run:
```bash
gh api "repos/{owner}/{repo}/branches/{base}/protection/required_status_checks/contexts"
```
(substitute the repo and the detected `base`).

Ask via AskUserQuestion — header "Required CI checks", question "Which CI checks must pass before merge?":
- "Use detected: `{ci_checks}` — confirm (recommended)" — use the branch-protection list; most common case
- "Enter check names manually" — enter comma-separated check names (e.g. `Build (ubuntu-22.04), test`)
- "Skip (no required checks yet)" — sets `ci.required: false`; the gate's CI sub-check will be skipped

Set `ci.required` to the chosen list or `false`.

---

## 5. Onboard the Otta Pulse GitHub App

**Pain this solves:** The loop has amnesia without a memory — runs don't learn from each other; you can't see what shipped broken.
**Benefit you get:** DORA metrics free (deploy frequency, lead time, change-failure rate) + escape detection + the LEARN data that improves agents over time.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pulse-install.sh"
```

**Self-hosting Pulse?** By default this wires to the hosted Otta Pulse at `https://pulse.otta.build`. A team running its own Pulse instance sets `OTTA_PULSE_URL` first, and every Otta script honours it:

```bash
OTTA_PULSE_URL="https://pulse.your-team.example" bash "${CLAUDE_PLUGIN_ROOT}/scripts/pulse-install.sh"
```

Export `OTTA_PULSE_URL` in your shell profile to make it the default for this machine. The hosted default needs no config.

Installing the App is interactive GitHub consent — you cannot do it for the user. Print the URL from the script and ask the user to open it, pick their account/org, and click Install. Offer to open it with `--open` if they are on this machine.

After the user confirms installation, set `pulse.installed: true` in `.otta.yml`.

---

## 6. (Optional) Harden against credential exfiltration

**Pain this solves:** The pipeline runs Bash commands near your secrets — an agent could inadvertently read `~/.aws`, `~/.ssh`, or token env vars.
**Benefit you get:** Agents can't read your credential files or token env vars — credential exfiltration is blocked at the sandbox level.

Ask via AskUserQuestion — header "Sandbox credentials", question "Block pipeline Bash from reading credential files + token env vars?":
- "Yes, sandbox credentials (recommended)" — adds `.claude/settings.json` with `sandbox.credentials`; needs sandbox mode (`bubblewrap`+`socat` on Linux, macOS native); also isolates filesystem writes + network (you approve new domains on first use)
- "No, skip" — no sandbox config written; you can add it later

Only if the developer chooses "Yes", write `.claude/settings.json` — **merge into an existing file, never clobber it**:

```json
{
  "sandbox": {
    "enabled": true,
    "allowUnsandboxedCommands": true,
    "credentials": {
      "files": [
        { "path": "~/.aws/credentials", "mode": "deny" },
        { "path": "~/.aws/config", "mode": "deny" },
        { "path": "~/.ssh", "mode": "deny" },
        { "path": "~/.config/gcloud", "mode": "deny" }
      ],
      "envVars": [
        { "name": "GITHUB_TOKEN", "mode": "deny" },
        { "name": "AWS_ACCESS_KEY_ID", "mode": "deny" },
        { "name": "AWS_SECRET_ACCESS_KEY", "mode": "deny" },
        { "name": "NPM_TOKEN", "mode": "deny" }
      ]
    }
  }
}
```

Notes: `allowUnsandboxedCommands: true` keeps the loop working if a sandbox dependency is missing (set `false` for strict mode). There is **no built-in credential deny list** — the lists above are a starting set; add the secrets that matter for this repo. The rules apply to the main session **and** the pipeline subagents (builder/reviewer/qa/devops), since subagents share the parent's sandbox config. `mode` only supports `"deny"` today.

---

## 7. (Optional) Scaffold a thin test-runner CI workflow

**Pain this solves:** No CI → the gate's CI check can never go green; the gate's authoritative "production-ready?" signal stays permanently unlit.
**Benefit you get:** A minimal test-runner makes the gate real — the quality loop closes; agents know when they broke something.

If the repo has a deployable package (`deploy.mode` is not `none`) but no CI workflow covering it yet:

Ask via AskUserQuestion — header "CI workflow", question "Scaffold a minimal CI test-runner workflow?":
- "Yes, add a starter CI workflow (recommended if none exists)" — generates `.github/workflows/ci-test.yml`: checkout → install deps → run tests; matches `deploy.package_paths` if set
- "No, skip — I'll add CI manually" — no file written

Generate the workflow only if the developer chooses "Yes". Keep it minimal. Match the working-directory to `deploy.package_paths` if set.

---

## 8. Install the local gate hook

**Pain this solves:** Gate failures found only after pushing = slow feedback loop; you wait for CI and Otta Gate to report what a pre-push check would have caught immediately.
**Benefit you get:** The same gate runs pre-push — fewer red PRs, faster iteration, no wasted push-wait cycles.

Ask via AskUserQuestion — header "Local gate hook", question "Install the pre-push gate hook?":
- "Yes, install pre-push hook (recommended)" — runs the same gate locally before every push; catches failures before they hit CI
- "No, skip" — rely on CI + Otta Gate only; slower feedback loop

Only if the developer chooses "Yes":

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-git-hooks.sh"
```

---

## 9. (Optional) Stream Claude Code telemetry to Pulse

**Pain this solves:** Can't improve what you can't see — without telemetry you're flying blind on per-tool/per-stage cost and timing.
**Benefit you get:** $/PR, tokens used, per-tool and per-stage timing flow into Pulse → spot the slow or expensive stage; the LEARN layer uses this to improve agent behavior over time.

Ask via AskUserQuestion — header "Telemetry", question "Stream this repo's Claude Code telemetry to Pulse?":
- "Logs only (recommended)" — per-tool/stage timing; default-on signal; streams to hosted `pulse.otta.build` (**Otta receives that telemetry**) unless `OTTA_PULSE_URL` is set to self-host first. **Process-level: once on, every Claude Code session in this repo emits — not just `/otta:dev`.**
- "Logs + traces (beta)" — adds spans (more volume); same destination disclosure applies
- "Skip" — no session telemetry

Only on a non-Skip answer, source the repo + token from `.otta/pulse.env` and invoke the writer (which **merges into an existing `env`, never clobbers**, and is idempotent):

```bash
[ -f .otta/pulse.env ] && set -a && . .otta/pulse.env && set +a
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" "$REPO" "$OTTA_PULSE_TOKEN"
```

`OTTA_PULSE_URL` is honoured automatically (self-host); the hosted default needs no config.

**Traces are a SEPARATE opt-in (beta, default NO).** Only after the developer also consents to spans, re-run with `--traces` (adds `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` + the traces exporters):

Ask via AskUserQuestion — header "Traces (beta)", question "Also enable traces/spans? (more volume, separate opt-in)":
- "No, logs only (recommended)" — spans skipped; you can add later
- "Yes, enable traces (beta)" — re-runs the writer with `--traces`

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" "$REPO" "$OTTA_PULSE_TOKEN" --traces
```

For non-setup users, the manual env block (logs-default / traces-beta split) is documented in the README.

---

## 10. Write-summary — confirm before writing

Before writing any files, show a summary of everything that will be written:

> "Here is what I will write based on your answers:
> - `.otta.yml` — base: `{base}`, staging: `{staging}`, deploy.auto: `{deploy_auto}`, ci.required: `{ci_required}`, pulse.installed: `{pulse_installed}`
> - `.claude/settings.json` (sandbox credentials): `{yes/no}`
> - `.github/workflows/ci-test.yml` (CI scaffold): `{yes/no}`
> - `.claude/settings.local.json` (telemetry): `{yes/no — logs/traces}`
>
> Confirm to proceed, or go back to change any setting."

Ask via AskUserQuestion — header "Confirm setup", question "Write these files and proceed?":
- "Yes, write and commit (recommended)" — proceeds to write all files
- "Go back — I want to change a setting" — return to the relevant step

Only after confirmation, write the files and run:

```bash
git add .otta.yml
git commit -m "chore: add .otta.yml delivery context (Otta setup)"
```

Tell the developer this file is the delivery contract for the Otta loop — keep it in git so all agents and CI jobs see it.

---

## 11. Ready — the payoff

This repo now has:

- **Gated quality** — nothing broken can merge; every PR is reviewed + verified by subagents
- **Memory** — Pulse records every gate verdict so the factory learns (DORA + escape detection free)
- **Visibility** — $/PR, tokens, per-stage timing in Pulse; DORA metrics from day one
- **Safety** — sandboxed agents can't touch your credentials

**Ad-hoc AI coding → a measured, self-improving factory.**

Next steps:
- `/otta:start <issue>` — begin a scoped issue (creates an isolated worktree, seeds `.pr-body.md`)
- `/otta:ship` — gate + open the PR (builder → reviewer → QA → DevOps)

Pulse wiring is automatic — `/otta:setup` connects this repo to Pulse and writes a gitignored `.otta/pulse.env` for you. No token to paste, no shell-profile edit needed. Merged-PR verdicts are captured server-side by the Otta Pulse GitHub App; the local stream adds your pre-merge gate runs so you see the full picture in Pulse.

To opt out of local verdict streaming, set `OTTA_NO_CAPTURE=1` in your environment (verdicts stay in the local `.otta/ledger/` file and can be imported later with `pulse ingest-ledger`).
