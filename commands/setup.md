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

**Interaction compatibility.** Wherever this workflow says AskUserQuestion, use the harness's native interactive input: `request_user_input` when available. If no interactive-input tool exists, ask one concise direct question in chat and wait for the answer before continuing. Do not call an unavailable Claude-only `AskUserQuestion` tool. Preserve the stated choices and defaults whichever interaction mechanism is used.

---

## 0. Before we start: see where you stand

Run the readiness score to show the current state (0/8):

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-readiness.sh"
```

Show the developer the per-dimension ✓/✗ list and the `N/8 production-ready` score. This is the **before** snapshot — setup will close these gaps.

Then offer the live gate demo via AskUserQuestion — header "Gate demo", question "Watch the gate catch a bad change? (10s demo, runs in a throwaway temp dir — never touches your repo)":
- "Show me (recommended)" — run `bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-gate-demo.sh"` and print the red→green narration; takes ~10 seconds
- "Skip" — proceed directly to Part A

---

## Part A: Detect + ask (no files written yet)

Steps 1–9 collect choices only. No optional file is written until after the summary confirmation in step 10.

---

## 1. Detect delivery context

Run the detection script to inspect the repo and surface branch/deploy signals.
**Do NOT write to `.otta.yml` here** — Part B step B1 is the sole author of the v2 contract.

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/detect-delivery-context.sh"
```

Show the developer the detection output. It will contain detected CI workflow names and `paths:` filters, any `deploy` signal found in the workflow files, and Linear/tracker signals. This includes `deploy.mode` — one of `"auto-on-merge"`, `"tag"`, `"manual"`, `"none"` — an informational delivery signal detected from CI; it is display-only here and is **not** one of the fields written to `.otta.yml` (the v2 contract's `deploy` block only has `target` and `project` — see step 2). Use this information to pre-fill the deploy and tracker answers for the steps below before anything is committed.

> **Preview vs. v2 contract mismatch:** `detect-delivery-context.sh` outputs a "preview" of detected fields. This preview may include keys (e.g., `deploy.mode`, `deploy.provider`) that do **not** appear in the written `.otta.yml` — the v2 contract schema is fixed at 6 keys (`tracker`, `autonomy`, `deploy`, `gates`, `telemetry`, `loops`). Treat the preview as diagnostic input, not as a draft of the final contract.

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

## 3. Deploy policy (merge behaviour)

**Pain this solves:** Without a declared policy every merge is manual — agents can't auto-merge when the gate is green.
**Benefit you get:** `deploy.auto` tells the loop and `otta-deploy-verify.sh` exactly when to merge and deploy automatically vs wait for human approval.

Ask via AskUserQuestion — header "Merge policy", question "When the gate is green, should PRs merge automatically?":
- `human-approve` (default) — a human must always approve and merge; safest, choose this when unsure
- `merge-on-green` — merge automatically when gate + CI are green; no deploy step triggered
- `merge-and-deploy` — merge and trigger the deploy pipeline automatically (requires deploy target set in step 2)

This maps to the `--deploy-auto <value>` flag of `write-otta-contract.sh` → `deploy.auto` in `.otta.yml`.

If the developer chose `merge-and-deploy` AND the deploy target is a production environment, ask one follow-up:

Ask via AskUserQuestion — header "Production auto-deploy opt-in", question "This repo deploys to production. Allow fully automatic production deploys (merge-and-deploy without human gate)?":
- `Yes, opt in` — adds `deploy.allow_production: true`; without this, `otta-deploy-verify.sh` will block production auto-deploys even with merge-and-deploy policy
- `No, keep human gate on production` (default) — `allow_production` is omitted (false); a human must approve before production auto-deploys run

Record both answers.

---

## 4. Self-learning opt-in (LEARN layer)

**Pain this solves:** The loop ships PRs, but each run starts from scratch — no memory of what worked, what was flagged, or what rules emerged from past verdicts.
**Benefit you get:** The LEARN layer auto-proposes enforced checks from verdict history, so the factory improves itself over time (GEPA).

Ask via AskUserQuestion — header "LEARN layer", question "Enable the self-learning (GEPA) layer for this repo?":
- "Enable (recommended if Pulse is installed)" — the LEARN loop replays verdict history and auto-proposes new gate rules; requires Pulse to accumulate data
- "Skip" — no LEARN; gate still runs, but no self-improvement; you can opt in later by editing `.otta.yml`

Only if the developer chooses "Enable":
- Ask for expiry days (optional, default 180): how many days of verdict history the LEARN run uses
- Ask for cadence (optional, default `weekly`): `daily` or `weekly` — how often the LEARN run proposes new rules

If the developer enables LEARN, pass `--learn` (and optionally `--learn-expiry-days <N>` and `--learn-cadence <daily|weekly>`) to `write-otta-contract.sh`. On "Skip", omit these flags — the contract will include a commented-out `learn:` block as a reminder.

Record the choice.

---

## 5. Onboard the Otta Pulse GitHub App

**Pain this solves:** The loop has amnesia without a memory — runs don't learn from each other; you can't see what shipped broken.
**Benefit you get:** DORA metrics free (deploy frequency, lead time, change-failure rate) + escape detection + the LEARN data that improves agents over time.

Ask via AskUserQuestion — header "Otta Pulse", question "Install the Otta Pulse GitHub App for this repo?":
- "Install (recommended)" — DORA + escape detection + the LEARN memory; without it the loop has amnesia and you have no server-side verdicts or metrics
- "Skip" — no Pulse capture; gate still runs locally, but no server-side verdicts, DORA, or LEARN data

Only if the developer chooses "Install":

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/pulse-install.sh"
```

**Self-hosting Pulse?** By default this wires to the hosted Otta Pulse at `https://pulse.otta.build`. A team running its own Pulse instance sets `OTTA_PULSE_URL` first:

```bash
OTTA_PULSE_URL="https://pulse.your-team.example" bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/pulse-install.sh"
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

## 8. (Optional) Install the local gate hook

**Pain this solves:** Gate failures found only after pushing = slow feedback loop; you wait for CI and Otta Gate to report what a pre-push check would have caught immediately.
**Benefit you get:** The same gate runs pre-push — fewer red PRs, faster iteration, no wasted push-wait cycles.

Ask via AskUserQuestion — header "Local gate hook (optional)", question "Install the pre-push gate hook? (optional — skip if you prefer CI-only feedback)":
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
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/detect-harnesses.sh"
```

For each harness found (other than `claude_code`, which was configured above), offer an adapter via AskUserQuestion:

**If `codex` is detected:**

Ask via AskUserQuestion — header "Codex adapter", question "Codex CLI detected. Wire Otta telemetry for Codex? (runs otta-codex-setup.sh)":
- "Yes (recommended)" — will run `otta-codex-setup.sh --derive` in Part B to write the active mode-0600 `$CODEX_HOME/config.toml` (normally `~/.codex/config.toml`) plus the gitignored legacy `.otta/codex.env`
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
> - `$CODEX_HOME/config.toml` (active Codex telemetry, mode 0600): `{yes/no — normally ~/.codex/config.toml}`
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
#   --deploy-auto <policy>     (human-approve [default] | merge-on-green | merge-and-deploy)
#   --allow-production         (only if developer explicitly opted in during step 3)
#   --learn                    (if developer enabled LEARN in step 4)
#   --learn-expiry-days <N>    (if developer provided a custom expiry; default 180)
#   --learn-cadence <cadence>  (daily | weekly; default weekly)
#   --pulse                    (if developer chose Pulse telemetry in step 5)
#   --otel <endpoint>          (if developer provided an OTEL endpoint in step 9)
#   --seo-geo                  (if the developer opts this repo into the seo_geo loop)
#   LINEAR_TEAM=<team>         (set as env var if a Linear team was identified)
# Omit --deploy-auto when the answer was human-approve (that is the default).

bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/write-otta-contract.sh" --output .otta.yml
```

Then commit:

```bash
git add .otta.yml
git commit -m "chore: add .otta.yml delivery contract (Otta setup v2)"
```

Tell the developer this file is the v2 delivery contract — keep it in git so all agents and CI jobs see it. Fields marked `# FILL IN` should be reviewed and updated before the commit if the values are known.

### B1b. Write additional harness context files (OTTA.md mapper)

For each additional harness detected in step 9b (i.e. non-CC harnesses only), inject an Otta gate notice into the corresponding context file. Use the delimiter block pattern — **never clobber existing content**:

| Harness | File | Block content |
|---------|------|---------------|
| `codex` | `AGENTS.md` | Gate notice (see below) with "Codex adapter" note |
| `gemini` | `GEMINI.md` | Gate notice with "Gemini adapter" note |
| `cursor` | `.cursor/rules` | Gate notice with "Cursor adapter coming soon" note |

**Delimiter-block pattern (idempotent, non-destructive):**

The gate notice is wrapped in delimiters so it can be found and updated on re-run without touching surrounding content:

```
<!-- otta:begin -->
# Otta Gate Active
This repo runs the Otta gate hook before push. Run `otta gate` or push — the hook fires automatically.
<!-- otta:end -->
```

- **File absent:** create it with just the delimiter block.
- **File exists, no delimiter block:** append the delimiter block at the end (preserves all existing content).
- **File exists, delimiter block present:** update only the block between `<!-- otta:begin -->` and `<!-- otta:end -->` in place — do NOT duplicate the block; never touch content outside the delimiters.

For Cursor, create `.cursor/` if it does not exist. Log whether each file was created, appended to, or updated in place. If no additional harnesses were found, skip this step entirely.

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
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/install-git-hooks.sh"
```

### B4b. Install PR-body merge driver (unconditional)

Always run after writing `.pr-body.md`. Installs the `merge=ours` git driver so `.pr-body.md` is never overwritten during a merge or rebase from main — each branch keeps its own PR body:

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/install-merge-ours.sh"
```

### B5. Wire telemetry (if chosen)

If the developer enabled Claude telemetry in step 9 and/or the Codex adapter in step 9b, derive a separate per-repo token for each selected writer and wire its active telemetry config. The flow depends on whether this repo uses hosted or self-hosted Pulse:

**Determine the Pulse URL** first:
```bash
PULSE_URL="${OTTA_PULSE_URL:-https://pulse.otta.build}"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
```

**For hosted `pulse.otta.build`** (no `OTTA_PULSE_URL` override, or `OTTA_PULSE_URL=https://pulse.otta.build`):

No webhook secret is needed. The `/token?repo=` endpoint is public — GitHub App installation is the proof of authorization. Do NOT ask for a webhook secret.

If the developer chose Claude Logs or Logs+traces, call its writer without a secret:

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-telemetry-setup.sh" "$REPO"
```

If the developer chose the Codex adapter, run:

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-codex-setup.sh" --derive "$REPO"
```

**For self-hosted Pulse** (`OTTA_PULSE_URL` set to any URL other than `https://pulse.otta.build`):

The webhook secret is required for either selected writer. Ask once via AskUserQuestion — header "Self-hosted Pulse secret", question "Paste your self-hosted Pulse webhook secret (from your Pulse instance env → `WEBHOOK_SECRET`):".

If the developer chose Claude Logs or Logs+traces, call:

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-telemetry-setup.sh" "$REPO" "$WEBHOOK_SECRET"
```

If the developer chose the Codex adapter, use the same webhook secret only to derive its repo token:

```bash
OTTA_PULSE_WEBHOOK_SECRET="$WEBHOOK_SECRET" \
  bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-codex-setup.sh" --derive "$REPO"
```

Each script calls `GET /token?repo=<repo>` (with the webhook secret as `x-pulse-token` only for self-hosted derivation). The Claude writer stores only its derived token in `.claude/settings.local.json`; the Codex writer stores only its derived token in `$CODEX_HOME/config.toml` and the ignored compatibility `.otta/codex.env`. The webhook secret is **never written to any file**, and neither writer prints tokens or token-bearing response bodies.

**Traces are a SEPARATE opt-in (beta, default NO).** Only if the developer chose Logs+traces, add `--traces` to the above call. For non-setup users, the manual env block is documented in the README.

### B6. Write CLAUDE.md (unconditional)

Claude Code is always the primary harness being configured by `/otta:setup`. Inject the gate notice into `CLAUDE.md` using the same **delimiter-block pattern** as B1b — never clobber existing content:

```
<!-- otta:begin -->
# Otta Gate Active
This repo runs the Otta gate hook before push. Run `otta gate` or push — the hook fires automatically.
<!-- otta:end -->
```

- **`CLAUDE.md` absent:** create it with just the delimiter block.
- **`CLAUDE.md` exists, no delimiter block:** append the block at the end (preserves all existing content; users keep their custom instructions).
- **`CLAUDE.md` exists, delimiter block present:** update the block in place — idempotent re-run, no duplication.

Log whether the file was created, appended to, or updated in place.

### B7. Install release workflow (if chosen)

If the developer chose "Yes — auto-tag on version bump" in step 9c:

```bash
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-release-setup.sh"
```

### B7b. Generate self-hosted runner setup (if chosen)

If the developer chose "Yes — generate runner setup" in step 7b:

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-runner-setup.sh" "$REPO"
```

This outputs the docker run command to stdout and writes `docs/runner-setup.md` with full registration instructions. Print the stdout output so the developer can copy the docker run command. Tell them to follow `docs/runner-setup.md` to register the runner with GitHub.

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
bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-readiness.sh"
```

Show the developer the updated ✓/✗ list and the new `N/8 production-ready` score. Compare to the **before** snapshot from step 0.

---

## 13. Ship your first gated PR now

Ask via AskUserQuestion — header "First PR in 2 min", question "Ship your first gated PR now? I'll run `/otta:start <issue>` for you.":
- "Yes — tell me the issue number" — ask the developer for the issue number/title, then invoke `/otta:start <issue>`
- "Skip — I'll do it later" — print: "Run `/otta:start <issue>` whenever you're ready to begin a scoped issue."
