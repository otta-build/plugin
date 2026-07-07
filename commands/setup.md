---
description: Set up Otta in this repo — guided wizard that teaches (pain→benefit) at each step, then writes .otta.yml + installs the gate hook and the Pulse GitHub App
---

# Why Otta? (read this once, then proceed)

AI agents code fast but quality is inconsistent — defects ship, runs forget context, and "is this production-ready?" is a guess. This setup wires Otta's gated TDD pipeline into THIS repo (~2 min):

- **Gates, not prompts, guarantee quality** — nothing broken can merge; every PR is reviewed + verified by specialist subagents before the gate opens.
- **Pulse records every verdict so the factory learns** — DORA metrics (deploy frequency, lead time, change-failure rate) and escape detection come free.
- **DORA + cost visibility, free** — $/PR, tokens used, and per-stage timing surface automatically once telemetry is on.

> Full pain→benefit table: [docs/why-otta-setup.md](../docs/why-otta-setup.md)

> **Proof by self-application:** This very wizard shipped through the Otta loop you're installing — built → reviewed → **QA caught a real gap (#26 AC3, the Pulse step had no opt-out)** → fixed → gated → merged.

---

## 0. Before we start: see where you stand

Run the readiness score to show the current state (0/8):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-readiness.sh"
```

Show the developer the per-dimension ✓/✗ list and the `N/8 production-ready` score. This is the **before** snapshot — setup will close these gaps.

Then offer the live gate demo via AskUserQuestion — header "Gate demo", question "Watch the gate catch a bad change? (10s demo, runs in a throwaway temp dir — never touches your repo)":
- "Show me (recommended)" — run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-gate-demo.sh"` and print the red→green narration; takes ~10 seconds
- "Skip" — proceed directly to Part A

---

## Part A: Detect + ask (no files written yet)

Steps 1–9 collect choices only. No optional file is written until after the summary confirmation in step 10.

---

## 1. Detect delivery context

Run the detection script to inspect the repo and surface branch/deploy signals.
**Do NOT write to `.otta.yml` here** — Part B step B1 is the sole author of the v2 contract.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-delivery-context.sh"
```

Show the developer the detection output. It will contain detected CI workflow names and `paths:` filters, any `deploy` signal found in the workflow files, and Linear/tracker signals. This includes `deploy.mode` — one of `"auto-on-merge"`, `"tag"`, `"manual"`, `"none"` — an informational delivery signal detected from CI; it is display-only here and is **not** one of the fields written to `.otta.yml` (the v2 contract's `deploy` block only has `target` and `project` — see step 2). Use this information to pre-fill the deploy and tracker answers for the steps below before anything is committed.

---

## 2. Deploy target and project

**Pain this solves:** Otta needs to know where this repo deploys so `write-otta-contract.sh` can wire the right platform and project into `.otta.yml`.
**Benefit you get:** `deploy.target` and `deploy.project` are filled in — the pipeline knows how to verify a deploy.

Ask via AskUserQuestion — header "Deploy platform", question "Which platform does this repo deploy to?":
- `cloudflare-pages` — Cloudflare Pages
- `vercel` — Vercel
- `coolify` — Coolify (self-hosted)
- `none` — no deploy (library, internal tool)

Then ask for the project name on that platform (the Cloudflare project, Vercel project, or Coolify app name). Enter `none` if not applicable.

These answers map directly to the `--deploy-target` and `--deploy-project` flags of `write-otta-contract.sh`, which writes `deploy.target` and `deploy.project` into `.otta.yml`.

Record the answers.

---

## 5. Onboard the Otta Pulse GitHub App

**Pain this solves:** The loop has amnesia without a memory — runs don't learn from each other; you can't see what shipped broken.
**Benefit you get:** DORA metrics free (deploy frequency, lead time, change-failure rate) + escape detection + the LEARN data that improves agents over time.

Ask via AskUserQuestion — header "Otta Pulse", question "Install the Otta Pulse GitHub App for this repo?":
- "Install (recommended)" — DORA + escape detection + the LEARN memory; without it the loop has amnesia and you have no server-side verdicts or metrics
- "Skip" — no Pulse capture; gate still runs locally, but no server-side verdicts, DORA, or LEARN data

Only if the developer chooses "Install":

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pulse-install.sh"
```

**Self-hosting Pulse?** By default this wires to the hosted Otta Pulse at `https://pulse.otta.build`. A team running its own Pulse instance sets `OTTA_PULSE_URL` first:

```bash
OTTA_PULSE_URL="https://pulse.your-team.example" bash "${CLAUDE_PLUGIN_ROOT}/scripts/pulse-install.sh"
```

Print the installation URL from the script and ask the user to open it, pick their account/org, and click Install. Offer to open it with `--open` if they are on this machine.

After the user confirms installation, record the choice; it is passed as the `--pulse` flag to `write-otta-contract.sh` → sets `telemetry.pulse: true` in `.otta.yml`. On "Skip", no flag is passed → `telemetry.pulse: false`. Do NOT run `pulse-install.sh` on "Skip".

---

## 6. (Optional choice) Harden against credential exfiltration

**Pain this solves:** The pipeline runs Bash commands near your secrets — an agent could inadvertently read `~/.aws`, `~/.ssh`, or token env vars.
**Benefit you get:** Agents can't read your credential files or token env vars — credential exfiltration is blocked at the sandbox level.

Ask via AskUserQuestion — header "Sandbox credentials", question "Block pipeline Bash from reading credential files + token env vars?":
- "Yes, sandbox credentials (recommended)" — will add `.claude/settings.json` with `sandbox.credentials`; needs sandbox mode (`bubblewrap`+`socat` on Linux, macOS native); also isolates filesystem writes + network (you approve new domains on first use)
- "No, skip" — no sandbox config written; you can add it later

Record the choice — the file is written after confirmation in step 10.

---

## 7. (Optional choice) Scaffold a thin test-runner CI workflow

**Pain this solves:** No CI → the gate's CI check can never go green; the gate's authoritative "production-ready?" signal stays permanently unlit.
**Benefit you get:** A minimal test-runner makes the gate real — the quality loop closes; agents know when they broke something.

If the repo deploys something (deploy target is not `none`) but has no CI workflow covering it yet:

Ask via AskUserQuestion — header "CI workflow", question "Scaffold a minimal CI test-runner workflow?":
- "Yes, add a starter CI workflow (recommended if none exists)" — will generate `.github/workflows/ci-test.yml`: checkout → install deps → run tests; matches `deploy.package_paths` if set
- "No, skip — I'll add CI manually" — no file written

Record the choice — the file is written after confirmation in step 10.

---

## 7b. (Optional choice) Set up a self-hosted Actions runner

**Pain this solves:** Private repos on free GitHub orgs exhaust Actions minutes quickly (~2,000 min/month free). With Otta's gated pipeline (builder → reviewer → QA → DevOps), each PR can trigger 4–6 CI runs, exhausting the quota in ~15 PRs — at which point `pull_request` CI silently stops and the gate's CI sub-check is permanently unlit.

**Benefit you get:** A self-hosted runner on your own infra has no minute limits — the gate's CI sub-check stays live regardless of how many PRs you ship.

**Detect first — only show this step when relevant:**

```bash
gh repo view --json isPrivate --jq .isPrivate
```

If the output is `true`, show this step. If the output is `false` (public repo), skip this step entirely — free-tier minutes are not a concern for public repos.

Only when repo is **private**: Ask via AskUserQuestion — header "Self-hosted runner", question "This is a private repo. Free GitHub Actions minutes (~2,000/month) run out fast with Otta's pipeline. Set up a self-hosted runner to avoid CI blackouts?":
- "Yes — generate runner setup (recommended)" — will run `otta-runner-setup.sh` in Part B to output the docker run command and write `docs/runner-setup.md`
- "No — I'll manage CI minutes manually" — skip; no files written

Record the choice — the script is run after confirmation in step 10.

---

## 8. (Optional choice) Install the local gate hook

**Pain this solves:** Gate failures found only after pushing = slow feedback loop; you wait for CI and Otta Gate to report what a pre-push check would have caught immediately.
**Benefit you get:** The same gate runs pre-push — fewer red PRs, faster iteration, no wasted push-wait cycles.

Ask via AskUserQuestion — header "Local gate hook", question "Install the pre-push gate hook?":
- "Yes, install pre-push hook (recommended)" — will run `install-git-hooks.sh` to mirror the gate locally
- "No, skip" — rely on CI + Otta Gate only; slower feedback loop

Record the choice — the script is run after confirmation in step 10.

---

## 9. (Optional choice) Stream Claude Code telemetry to Pulse

**Pain this solves:** Can't improve what you can't see — without telemetry you're flying blind on per-tool/per-stage cost and timing.
**Benefit you get:** $/PR, tokens used, per-tool and per-stage timing flow into Pulse → spot the slow or expensive stage; the LEARN layer uses this to improve agent behavior over time.

Ask via AskUserQuestion — header "Telemetry", question "Stream this repo's Claude Code telemetry to Pulse?":
- "Logs only (recommended)" — per-tool/stage timing; default-on signal; streams to hosted `pulse.otta.build` (**Otta receives that telemetry**) unless `OTTA_PULSE_URL` is set to self-host first. **Process-level: once on, every Claude Code session in this repo emits — not just `/otta:dev`.**
- "Logs + traces (beta)" — adds spans (more volume); same destination disclosure applies
- "Skip" — no session telemetry

Record the choice — telemetry setup is wired after confirmation in step 10.

---

## 9b. Additional harness adapters

Run the harness detection script to find non-CC harnesses in this repo:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-harnesses.sh"
```

For each harness found (other than `claude_code`, which was configured above), offer an adapter via AskUserQuestion:

**If `codex` is detected:**

Ask via AskUserQuestion — header "Codex adapter", question "Codex CLI detected. Wire Otta telemetry for Codex? (runs otta-codex-setup.sh)":
- "Yes (recommended)" — will run `otta-codex-setup.sh` in Part B to write `.otta/codex.env`
- "Skip" — no Codex telemetry

**If `gemini` is detected:**

Ask via AskUserQuestion — header "Gemini adapter", question "Gemini CLI detected. Wire Otta telemetry for Gemini? Note: Gemini has no native OTLP auth headers — a local OTel Collector sidecar is required to inject the token. (runs otta-gemini-setup.sh)":
- "Yes" — will run `otta-gemini-setup.sh` in Part B; requires `docker` for the OTel Collector sidecar
- "Skip" — no Gemini telemetry

**If `cursor` is detected:**

Inform only (no adapter available yet): "Cursor detected. A Cursor telemetry adapter is coming in a future version. Skipping for now."

If no additional harnesses are found, skip this step entirely (no prompts shown).

Record choices for each harness — scripts are run after confirmation in step 10.

---

## 9c. (Optional choice) Enable release versioning

**Pain this solves:** Every deploy is anonymous — no version number, no `deploy_tag` event in Pulse, no upgrade story for customers.
**Benefit you get:** Bump `package.json` version and push → the CI workflow cuts the git tag automatically → Pulse records `deploy_tag` → idea→PR→version chain is complete.

Ask via AskUserQuestion — header "Release versioning", question "Enable automatic release tagging via CI?":
- "Yes — auto-tag on version bump (recommended)" — installs `.github/workflows/otta-release.yml`; bump `package.json` version and push → CI cuts a git tag automatically
- "No — I'll tag manually" — adds one-liner to the final summary: `git tag vX.Y.Z && git push origin vX.Y.Z`; no files written
- "Skip — no versioning needed" — silent skip; nothing written, nothing mentioned again

Record the choice — the file is installed after confirmation in step 10.

---

## 10. Write-summary — confirm before writing any file

Show a complete summary of what will be written based on all choices above:

> "Here is what I will write:
> - `.otta.yml` — tracker: `{kind: linear, team: {team} | kind: gh}`, autonomy: `{auto | human-gated}`, deploy: `{target: {target}, project: {project}}`, gates: `[pr-body-acceptance, test-coverage, review-thread]`, telemetry: `{pulse: {true|false}, otel: {endpoint|null}}`, loops: `{[dev_loop] | [dev_loop, seo_geo]}`
> - `.claude/settings.json` (sandbox credentials): `{yes/no}`
> - `.github/workflows/ci-test.yml` (CI scaffold): `{yes/no}`
> - `.github/workflows/otta-release.yml` (release tagging): `{yes/no}`
> - `.claude/settings.local.json` (telemetry, gitignored): `{yes/no — logs / logs+traces}`
> - Pre-push gate hook (install-git-hooks.sh): `{yes/no}`
> - `.gitattributes` — `.pr-body.md merge=ours` entry (always written, idempotent)
> - `CLAUDE.md` (if absent): always written — CC is the primary harness being configured
> - Additional harness context files (if absent): `AGENTS.md` (Codex), `GEMINI.md` (Gemini), `.cursor/rules` (Cursor) — only for detected non-CC harnesses
> - `docs/runner-setup.md` (self-hosted runner instructions): `{yes/no — only for private repos where runner was chosen}`
>
> Confirm to proceed, or go back to change any answer."

Ask via AskUserQuestion — header "Confirm setup", question "Write these files and proceed?":
- "Yes, write and commit (recommended)" — proceeds to Part B
- "Go back — I want to change an answer" — return to the relevant step

---

## Part B: Execute (only after confirmation above)

### B1. Write .otta.yml and commit

Write the v2 contract file — the single per-repo interface every loop + Paperclip dispatch reads.
Pass the collected answers as flags (omit flags for fields that were left as defaults):

```bash
# Build the flag list from answers collected in Part A:
#   --deploy-target <target>   (e.g. cloudflare-pages, vercel, coolify, none)
#   --deploy-project <name>    (project name on the deploy platform)
#   --pulse                    (if developer chose Pulse telemetry in step 5)
#   --otel <endpoint>          (if developer provided an OTEL endpoint in step 9)
#   --seo-geo                  (if the developer opts this repo into the seo_geo loop)
#   LINEAR_TEAM=<team>         (set as env var if a Linear team was identified)

bash "${CLAUDE_PLUGIN_ROOT}/scripts/write-otta-contract.sh" --output .otta.yml
```

Then commit:

```bash
git add .otta.yml
git commit -m "chore: add .otta.yml delivery contract (Otta setup v2)"
```

Tell the developer this file is the v2 delivery contract — keep it in git so all agents and CI jobs see it. Fields marked `# FILL IN` should be reviewed and updated before the commit if the values are known.

### B1b. Write additional harness context files (OTTA.md mapper)

For each additional harness detected in step 9b (i.e. non-CC harnesses only), write the corresponding context file **only if it does not already exist** (never overwrite):

| Harness | File | Content |
|---------|------|---------|
| `codex` | `AGENTS.md` | "# Otta Gate Active\n\nThis repo runs the Otta gate hook before push. Gate: `bash .claude/hooks/pre-push-gate.sh`. Pulse wired: telemetry flows to pulse.otta.build (Codex adapter)." |
| `gemini` | `GEMINI.md` | "# Otta Gate Active\n\nThis repo runs the Otta gate hook before push. Gate: `bash .claude/hooks/pre-push-gate.sh`. Pulse wired: telemetry flows to pulse.otta.build (Gemini adapter)." |
| `cursor` | `.cursor/rules` | "# Otta Gate Active\n\nThis repo runs the Otta gate hook before push. Gate: `bash .claude/hooks/pre-push-gate.sh`. Pulse wired: telemetry flows to pulse.otta.build (Cursor adapter coming soon)." |

For Cursor, create `.cursor/` if it does not exist. Log each file written. Skip any file that already exists. If no additional harnesses were found, skip this step entirely.

### B2. Write sandbox credentials (if chosen)

If the developer chose Yes in step 6, write `.claude/settings.json` — **merge into an existing file, never clobber it**:

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

### B3. Scaffold CI workflow (if chosen)

If the developer chose Yes in step 7, generate `.github/workflows/ci-test.yml`. Keep it minimal: checkout → install deps → run tests. Match the working-directory to `deploy.package_paths` if set.

### B4. Install pre-push gate hook (if chosen)

If the developer chose Yes in step 8:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-git-hooks.sh"
```

### B4b. Install PR-body merge driver (unconditional)

Always run after writing `.pr-body.md`. Installs the `merge=ours` git driver so `.pr-body.md` is never overwritten during a merge or rebase from main — each branch keeps its own PR body:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-merge-ours.sh"
```

### B5. Wire telemetry (if chosen)

If the developer chose Logs or Logs+traces in step 9, ask for the **webhook secret** (found in Coolify → Otta project → pulse app → `WEBHOOK_SECRET` env var). The script calls `/token` to derive a per-repo token and writes only the derived token to `.claude/settings.local.json` — the webhook secret is **never written to any file**.

Prompt via AskUserQuestion: "Paste your Pulse webhook secret (from Coolify → pulse app → WEBHOOK_SECRET):"

Then invoke the writer (which **merges into an existing `env`, never clobbers**, and is idempotent):

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" "$REPO" "$WEBHOOK_SECRET"
```

`OTTA_PULSE_URL` is honoured automatically (self-host); the hosted default needs no config.

**Traces are a SEPARATE opt-in (beta, default NO).** Only if the developer chose Logs+traces, re-run with `--traces`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-telemetry-setup.sh" "$REPO" "$WEBHOOK_SECRET" --traces
```

For non-setup users, the manual env block (logs-default / traces-beta split) is documented in the README.

### B7. Install release workflow (if chosen)

If the developer chose "Yes — auto-tag on version bump" in step 9c:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-release-setup.sh"
```

### B7b. Generate self-hosted runner setup (if chosen)

If the developer chose "Yes — generate runner setup" in step 7b:

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-runner-setup.sh" "$REPO"
```

This outputs the docker run command to stdout and writes `docs/runner-setup.md` with full registration instructions. Print the stdout output so the developer can copy the docker run command. Tell them to follow `docs/runner-setup.md` to register the runner with GitHub.

### B6. Write CLAUDE.md (unconditional)

Claude Code is always the primary harness being configured by `/otta:setup`. Write `CLAUDE.md` **only if it does not already exist** (never overwrite), regardless of what step 9b detected:

> Content: "# Otta Gate Active\n\nThis repo runs the Otta gate hook before push. Gate: `bash .claude/hooks/pre-push-gate.sh`. Pulse wired: telemetry flows to pulse.otta.build."

Log whether the file was written or already existed.

---

## 11. Ready — the payoff

This repo now has:

- **Gated quality** — nothing broken can merge; every PR is reviewed + verified by subagents before the gate opens
- **Memory** — Pulse records every gate verdict so the factory learns (DORA + escape detection free)
- **Visibility** — $/PR, tokens, per-stage timing in Pulse; DORA metrics from day one
- **Safety** — sandboxed agents can't touch your credentials

**Ad-hoc AI coding → a measured, self-improving factory.**

Next steps:
- `/otta:start <issue>` — begin a scoped issue (creates an isolated worktree, seeds `.pr-body.md`)
- `/otta:ship` — gate + open the PR (builder → reviewer → QA → DevOps)

Pulse wiring is automatic — `/otta:setup` connects this repo to Pulse and writes a gitignored `.otta/pulse.env` for you. No token to paste, no shell-profile edit needed. Merged-PR verdicts are captured server-side by the Otta Pulse GitHub App; the local stream adds your pre-merge gate runs so you see the full picture in Pulse.

To opt out of local verdict streaming, set `OTTA_NO_CAPTURE=1` in your environment (verdicts stay in the local `.otta/ledger/` file and can be imported later with `pulse ingest-ledger`).

---

## 12. After — readiness score

Run the score again to show what was unlocked:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-readiness.sh"
```

Show the developer the updated ✓/✗ list and the new `N/8 production-ready` score. Compare to the **before** snapshot from step 0.

---

## 13. Ship your first gated PR now

Ask via AskUserQuestion — header "First PR in 2 min", question "Ship your first gated PR now? I'll run `/otta:start <issue>` for you.":
- "Yes — tell me the issue number" — ask the developer for the issue number/title, then invoke `/otta:start <issue>`
- "Skip — I'll do it later" — print: "Run `/otta:start <issue>` whenever you're ready to begin a scoped issue."
