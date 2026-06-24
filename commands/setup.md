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
- **deploy.target** — where does it deploy? (e.g. `vercel`, `coolify`, `tauri`, `npm`, `none`)
- **staging-first vs prod** — does every feature branch go to a staging environment before merging to `base`? (`staging: staging` is already set if a `staging` branch was found — confirm this is the intended flow)
- **ci.required** — which CI check names are required to pass before merge? **First auto-detect, don't just ask:** run `gh api "repos/{owner}/{repo}/branches/{base}/protection/required_status_checks/contexts"` (substitute the repo and the detected `base`). If it returns a list, pre-fill `ci.required` with it and ask the developer only to **confirm** (e.g. "Branch protection requires `["Build (ubuntu-22.04)", "test"]` — use these?"). If it 404s (no branch protection, or no admin access), fall back to asking which check names are required, e.g. `["Build (ubuntu-22.04)", "test"]`.

Fill these answers into `.otta.yml` before continuing.

## 3. Onboard the Otta Pulse GitHub App

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/pulse-install.sh"
```

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

## 7. Ready

Tell the developer the loop is live:
- `/otta:start <issue>` — begin a scoped issue (creates an isolated worktree)
- `/otta:ship` — gate + open the PR

Pulse wiring is automatic — `/otta:setup` connects this repo to Pulse and writes a gitignored `.otta/pulse.env` for you. No token to paste, no shell-profile edit needed. Merged-PR verdicts are captured server-side by the Otta Pulse GitHub App; the local stream adds your pre-merge gate runs so you see the full picture in Pulse.

To opt out of local verdict streaming, set `OTTA_NO_CAPTURE=1` in your environment (verdicts stay in the local `.otta/ledger/` file and can be imported later with `pulse ingest-ledger`).
