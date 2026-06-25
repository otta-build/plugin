---
description: Set up Otta in this repo — detect delivery context, write .otta.yml, install the gate hook and the Pulse GitHub App
---

Set up the Otta shipping loop for this repository (once per repo).

## 1. Detect delivery context

Run the detection script to auto-fill what can be determined from the repo:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-delivery-context.sh" --output .otta.yml
```

Show the developer the pre-filled `.otta.yml`. It will contain the detected `base`, `staging`, CI workflow names and `paths:` filters, and any `deploy` signal found in the workflow files.

## 2. Ask the developer for the non-detectable fields

The script leaves placeholders for fields it cannot determine. Ask the developer:

- **deploy.mode** — what does "deployed" mean for this repo? (choose one)
  - `"auto-on-merge"` — every merge to `base` ships automatically (Vercel, Coolify, etc.)
  - `"tag"` — a git tag triggers the release (Tauri, npm publish, Docker tag, etc.)
  - `"manual"` — deploy is triggered manually (button, script, etc.)
  - `"none"` — no automated deploy yet
- **deploy.provider** — which platform deploys it? (`coolify`, `vercel`, `tauri`, or `none` for the generic path)
- **deploy.auto** — the post-merge policy (#20). What should `/otta:ship` do once the PR is green? (choose one)
  - `"human-approve"` (default) — stop at the green PR; the human merges. Safe, unchanged behavior. An **absent** `deploy` block also resolves to this, so existing repos are unaffected.
  - `"merge-on-green"` — auto-merge once every Otta Gate sub-check is green; downstream deploy handled outside Otta.
  - `"merge-and-deploy"` — merge on green, then verify the deploy reached the merged SHA (provider SHA-match) and report the live URL.
- **deploy.target** — which environment does a merge ship to? (`production` or `staging`)
- **deploy.verify** — how is a deploy confirmed? (`sha-match` — default; `health` — also probe a health URL; `none`)
- **deploy.allow_production** — only relevant for `merge-and-deploy` to `production`. This **must** be set to `true` explicitly to permit a hands-off production deploy; otherwise the stage is rejected (no accidental hands-off prod deploys). Default `false`. Ask the developer to confirm before setting it true.
- **staging-first vs prod** — does every feature branch go to a staging environment before merging to `base`? (`staging: staging` is already set if a `staging` branch was found — confirm this is the intended flow)
- **ci.required** — which CI check names are required to pass before merge? **First auto-detect, don't just ask:** run `gh api "repos/{owner}/{repo}/branches/{base}/protection/required_status_checks/contexts"` (substitute the repo and the detected `base`). If it returns a list, pre-fill `ci.required` with it and ask the developer only to **confirm** (e.g. "Branch protection requires `["Build (ubuntu-22.04)", "test"]` — use these?"). If it 404s (no branch protection, or no admin access), fall back to asking which check names are required, e.g. `["Build (ubuntu-22.04)", "test"]`.

Fill these answers into `.otta.yml` before continuing.

## 3. Onboard the Otta Pulse GitHub App

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

## 4. Write and commit .otta.yml

Once the fields are filled and Pulse is installed:

```bash
git add .otta.yml
git commit -m "chore: add .otta.yml delivery context (Otta setup)"
```

Tell the developer this file is the delivery contract for the Otta loop — keep it in git so all agents and CI jobs see it.

## 5. Install the local gate hook

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-git-hooks.sh"
```

This mirrors the Pulse merge gates locally so `/otta:ship` can run pre-push checks without a round-trip to GitHub.

## 6. (Optional) Scaffold a thin test-runner CI workflow

If the repo has a deployable package (`deploy.mode` is not `none`) but no CI workflow covering it yet, offer to scaffold a minimal test-runner workflow:

> "I can add a starter `.github/workflows/ci-test.yml` that runs your tests on pull requests. This is a thin scaffold — Otta governs the gate logic, not CI. Want me to create it?"

Generate the workflow only if the developer says yes. Keep it minimal: checkout → install deps → run tests. Match the working-directory to `deploy.package_paths` if set.

## 7. (Optional) Harden against credential exfiltration

Offer — do **not** impose. Otta gates AI-written code; this stops that code from *reading* your secrets in the first place, using Claude Code's `sandbox.credentials`. It **requires sandbox mode on**, which has real side effects, so state the trade-off before writing anything:

> "I can add a `.claude/settings.json` that blocks the pipeline's Bash commands from reading credential files (`~/.aws`, `~/.ssh`, `~/.config/gcloud`) and strips token env vars (`GITHUB_TOKEN`, `AWS_*`, `NPM_TOKEN`). It needs `sandbox.enabled: true`, which also isolates the filesystem (writes limited to the working dir) and the network (you approve new domains on first use). macOS + Linux/WSL2 only — not native Windows; Linux needs `bubblewrap` + `socat`. Add it? You can tune the deny lists after."

Only if the developer says yes, write `.claude/settings.json` — **merge into an existing file, never clobber it**:

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

## 8. (Optional) Stream Claude Code telemetry to Pulse

Offer — do **not** impose. This turns on Claude Code's OTEL telemetry so per-tool/per-stage timing (logs) and spans (traces) flow into Pulse. It is **CC-process-level**, so state that clearly before writing anything:

> "I can turn on Claude Code telemetry for this repo so Pulse sees per-tool/per-stage timing. **This is process-level — once on, EVERY Claude Code session in this repo emits to Pulse, not just `/otta:dev`.** The token goes only into `.claude/settings.local.json` (gitignored), never the committed `settings.json`. Enable it?"

Only if the developer says yes, source the repo + per-repo token from the existing pulse wiring and invoke the writer (which **merges into an existing `env`, never clobbers**, and is idempotent):

```bash
[ -f .otta/pulse.env ] && set -a && . .otta/pulse.env && set +a
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" "$REPO" "$OTTA_PULSE_TOKEN"
```

`OTTA_PULSE_URL` is honoured automatically (self-host); the hosted default needs no config.

**Traces are a SEPARATE opt-in (beta, default NO).** Only after the developer also consents to spans, re-run with `--traces` (adds `CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1` + the traces exporters):

> "Traces/spans are a separate beta opt-in (more volume). Add those too?"

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" "$REPO" "$OTTA_PULSE_TOKEN" --traces
```

For non-setup users, the manual env block (logs-default / traces-beta split) is documented in the README.

## 9. Ready

Tell the developer the loop is live:
- `/otta:start <issue>` — begin a scoped issue (creates an isolated worktree)
- `/otta:ship` — gate + open the PR

Pulse wiring is automatic — `/otta:setup` connects this repo to Pulse and writes a gitignored `.otta/pulse.env` for you. No token to paste, no shell-profile edit needed. Merged-PR verdicts are captured server-side by the Otta Pulse GitHub App; the local stream adds your pre-merge gate runs so you see the full picture in Pulse.

To opt out of local verdict streaming, set `OTTA_NO_CAPTURE=1` in your environment (verdicts stay in the local `.otta/ledger/` file and can be imported later with `pulse ingest-ledger`).
