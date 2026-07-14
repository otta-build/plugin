# GitHub Workflow Deploy Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Otta obtain commit-bound production approval, dispatch one configured GitHub Actions deployment for the merged SHA, and verify both the workflow result and live health SHA without becoming an infrastructure mutation authority.

**Architecture:** Extend the flat `deploy:` contract additively, keep policy/orchestration in `otta-deploy-verify.sh`, and isolate GitHub workflow dispatch, ledger reconciliation, polling, and health verification in a focused adapter. The adapter uses Otta's append-only ledger for idempotency and reconciles GitHub run IDs before retrying an ambiguous dispatch. Existing repositories retain their current behavior unless `deploy.executor: github-workflow` is configured.

**Tech Stack:** Bash, GitHub CLI, jq/Python JSON parsing, Markdown, shell regression tests.

---

## File map

- Create `scripts/github-workflow-deploy.sh` for dispatch, reconciliation, polling, and health verification.
- Create `tests/github-workflow-deploy.test.sh` with stubbed GitHub, HTTP, sleep, and ledger boundaries.
- Modify `scripts/write-otta-contract.sh` and `tests/write-otta-contract.test.sh` for additive configuration.
- Modify `scripts/otta-deploy-verify.sh` and `tests/otta-deploy-verify.test.sh` for approval and orchestration.
- Modify `commands/setup.md`, `commands/ship.md`, `commands/dev.md`, `commands/status.md`, `README.md`, and `docs/why-otta-setup.md` for the operational contract.
- Modify `.pr-body.md` only with verified evidence.

### Task 1: Add the workflow-executor contract

**Files:**
- Modify: `tests/write-otta-contract.test.sh`
- Modify: `scripts/write-otta-contract.sh`
- Modify: `tests/otta-deploy-verify.test.sh`
- Modify: `scripts/otta-deploy-verify.sh`

- [ ] **Step 1: Write failing generated-contract tests**

Invoke the writer with all new flags and assert exact emitted lines:

```bash
bash "$SCRIPT" --output "$OUT" \
  --deploy-target production --deploy-project leadcognition \
  --deploy-auto human-approve --deploy-executor github-workflow \
  --deploy-workflow deploy-production.yml --deploy-ref main \
  --deploy-sha-input commit_sha --deploy-provider coolify \
  --deploy-verify health-sha \
  --deploy-health-url https://app.leadcognition.io/health \
  --deploy-health-commit-field commit
```

Assert `executor`, `workflow`, `ref`, `sha_input`, `provider`, `verify`, `health_url`, and `health_commit_field`. Add negative cases for a missing workflow and unknown executor.

- [ ] **Step 2: Run RED**

Run: `bash tests/write-otta-contract.test.sh`

Expected: FAIL with `unknown arg: --deploy-executor`.

- [ ] **Step 3: Implement validated writer flags**

Add defaults:

```bash
DEPLOY_EXECUTOR="none"; DEPLOY_WORKFLOW=""; DEPLOY_REF="main"
DEPLOY_SHA_INPUT="commit_sha"; DEPLOY_PROVIDER="none"
DEPLOY_VERIFY="sha-match"; DEPLOY_HEALTH_URL=""
DEPLOY_HEALTH_COMMIT_FIELD="commit"
```

Accept matching CLI flags. Validate `none|github-workflow`, and reject `github-workflow` without a workflow. Preserve existing output exactly when executor is `none`; otherwise emit all new flat keys below `deploy.auto`.

- [ ] **Step 4: Add parser tests and functions**

Add a workflow-enabled fixture plus missing-key defaults. Implement:

```bash
parse_deploy_executor()            { local v; v="$(_deploy_raw "${1:-.otta.yml}" executor)"; echo "${v:-none}"; }
parse_deploy_workflow()            { _deploy_raw "${1:-.otta.yml}" workflow; }
parse_deploy_ref()                 { local v; v="$(_deploy_raw "${1:-.otta.yml}" ref)"; echo "${v:-main}"; }
parse_deploy_sha_input()           { local v; v="$(_deploy_raw "${1:-.otta.yml}" sha_input)"; echo "${v:-commit_sha}"; }
parse_deploy_health_url()          { _deploy_raw "${1:-.otta.yml}" health_url; }
parse_deploy_health_commit_field() { local v; v="$(_deploy_raw "${1:-.otta.yml}" health_commit_field)"; echo "${v:-commit}"; }
```

- [ ] **Step 5: Run GREEN and commit**

Run: `bash tests/write-otta-contract.test.sh && bash tests/otta-deploy-verify.test.sh`

Expected: PASS.

```bash
git add scripts/write-otta-contract.sh scripts/otta-deploy-verify.sh tests/write-otta-contract.test.sh tests/otta-deploy-verify.test.sh
git commit -m "feat(#137): configure GitHub workflow deployments"
```

### Task 2: Separate approval from execution

**Files:**
- Modify: `tests/otta-deploy-verify.test.sh`
- Modify: `scripts/otta-deploy-verify.sh`

- [ ] **Step 1: Write the failing decision table**

Test all rows:

```text
human-approve + OPEN + no approval        = wait-human
human-approve + OPEN + matching head      = merge-dispatch
human-approve + OPEN + changed head       = invalid-approval
human-approve + MERGED + matching head    = dispatch
human-approve + MERGED + no approval      = wait-human
merge-on-green + OPEN + green             = merge-only
merge-and-deploy + OPEN + green           = merge-dispatch
executor none                             = legacy
```

- [ ] **Step 2: Run RED**

Run: `bash tests/otta-deploy-verify.test.sh`

Expected: FAIL because `decide_delivery_action` is undefined.

- [ ] **Step 3: Implement the pure decision**

```bash
decide_delivery_action() {
  local auto="$1" state="$2" executor="$3" approved="${4:-}" head="${5:-}" green="${6:-false}"
  [ "$executor" = github-workflow ] || { echo legacy; return 0; }
  if [ "$auto" = human-approve ]; then
    [ -n "$approved" ] || { echo wait-human; return 1; }
    sha_match "$approved" "$head" || { echo invalid-approval; return 2; }
    [ "$state" = MERGED ] && { echo dispatch; return 0; }
    [ "$state" = OPEN ] && [ "$green" = true ] && { echo merge-dispatch; return 0; }
    echo wait-gate; return 1
  fi
  [ "$green" = true ] || { echo wait-gate; return 1; }
  [ "$auto" = merge-on-green ] && { echo merge-only; return 0; }
  [ "$auto" = merge-and-deploy ] && { echo merge-dispatch; return 0; }
  echo legacy
}
```

- [ ] **Step 4: Parse immutable approval and PR state**

Add `--approved-head <sha>`. Before mutation, read `state`, `headRefOid`, and `mergeCommit`. Without approval, display repo, PR, exact head, target, workflow, ref, and health URL, then stop. Reject a changed head before polling checks. Test that no-approval and changed-head paths invoke neither merge nor dispatch.

- [ ] **Step 5: Run GREEN and commit**

Run: `bash tests/otta-deploy-verify.test.sh`

Expected: PASS.

```bash
git add scripts/otta-deploy-verify.sh tests/otta-deploy-verify.test.sh
git commit -m "feat(#137): bind production approval to PR head"
```

### Task 3: Dispatch and reconcile exactly once

**Files:**
- Create: `tests/github-workflow-deploy.test.sh`
- Create: `scripts/github-workflow-deploy.sh`

- [ ] **Step 1: Write failing adapter tests**

With `OTTA_LEDGER_DIR` temporary and `gh` stubbed, prove: stable identity; first dispatch exactly once; retry reuses the run ID; `dispatching` reconciles exactly one unseen run; zero matches remains unknown without redispatch; multiple matches fail ambiguous; failed runs require explicit recovery.

- [ ] **Step 2: Run RED**

Run: `bash tests/github-workflow-deploy.test.sh`

Expected: FAIL because the adapter does not exist.

- [ ] **Step 3: Implement stable identity and ledger lookup**

```bash
workflow_deploy_key() { printf '%s\n' "$1|$2|$3|$4" | shasum -a 256 | awk '{print $1}'; }
deployment_last_record() {
  local project="$1" key="$2" file="${OTTA_LEDGER_DIR:-$HOME/.otta/ledger}/${project//\//-}.jsonl"
  [ -f "$file" ] || return 1
  jq -c --arg key "$key" 'select(.source=="deploy" and .input.idempotency_key==$key)' "$file" | tail -1
}
```

Use `ledger-append.sh --source deploy` for `deploy_dispatching`, `deploy_dispatched`, `deploy_dispatch_unknown`, `deploy_workflow_succeeded`, `deploy_workflow_failed`, and `deploy_runtime_verified`. Build all payloads with `jq -cn`.

- [ ] **Step 4: Implement dispatch reconciliation**

Record run IDs before dispatch, append `deploy_dispatching`, then call:

```bash
gh workflow run "$workflow" --repo "$repo" --ref "$ref" -f "$sha_input=$merge_sha"
```

Poll workflow-dispatch runs for the configured workflow/ref whose IDs were not in the recorded pre-dispatch set. Correlate only a post-dispatch run from the recorded actor whose `display_title` contains the requested SHA as an exact standalone token; `head_sha` must never substitute because it identifies the workflow ref rather than proving the input received by the run. Exactly one becomes `deploy_dispatched`; zero times out as unknown; multiple fail as ambiguous. Retries reconcile from the ledger and never call `workflow run` again while state is uncertain.

- [ ] **Step 5: Run GREEN and commit**

Run: `bash tests/github-workflow-deploy.test.sh`

Expected: PASS with the exact dispatch counts asserted.

```bash
git add scripts/github-workflow-deploy.sh tests/github-workflow-deploy.test.sh
git commit -m "feat(#137): dispatch workflows exactly once"
```

### Task 4: Poll workflow and verify live SHA

**Files:**
- Modify: `tests/github-workflow-deploy.test.sh`
- Modify: `scripts/github-workflow-deploy.sh`

- [ ] **Step 1: Write failing tests**

Cover queued→running→success, failure, cancellation, timeout, interrupted resume, unreachable/malformed health, missing field, stale SHA, prefix-equivalent SHA, and eventual correct SHA.

- [ ] **Step 2: Run RED**

Run: `bash tests/github-workflow-deploy.test.sh`

Expected: FAIL because terminal polling and health verification are absent.

- [ ] **Step 3: Implement terminal polling**

Poll `gh run view <id> --json status,conclusion,url,headSha`, throttle logs to once per 60 seconds, and preserve the run ID on timeout. Record success only for `completed/success`; every other terminal conclusion is failure.

- [ ] **Step 4: Implement live SHA verification**

`verify_health_sha <url> <field> <expected>` must use bounded retry, `jq -r --arg field '.[$field] // empty'`, and existing prefix-tolerant `sha_match`. Its final error reports expected SHA, observed SHA or unavailable state, URL, and timeout without exposing headers or tokens. Record `deploy_runtime_verified` only after a match.

- [ ] **Step 5: Run GREEN and commit**

Run: `bash tests/github-workflow-deploy.test.sh`

Expected: PASS.

```bash
git add scripts/github-workflow-deploy.sh tests/github-workflow-deploy.test.sh
git commit -m "feat(#137): verify workflow and live commit"
```

### Task 5: Wire orchestration without changing legacy modes

**Files:**
- Modify: `tests/otta-deploy-verify.test.sh`
- Modify: `scripts/otta-deploy-verify.sh`

- [ ] **Step 1: Write failing orchestration tests**

Prove approved open PR merges then dispatches; approved merged PR dispatches without merging; workflow failure skips health; stale health fails; merge-on-green remains merge-only; legacy merge-and-deploy still uses `verify_deploy`; missing workflow fails before mutation.

- [ ] **Step 2: Run RED**

Run: `bash tests/otta-deploy-verify.test.sh`

Expected: FAIL because `_run` does not route to the adapter.

- [ ] **Step 3: Source and invoke the adapter**

Resolve it relative to `BASH_SOURCE[0]`. Route only `executor=github-workflow` through `run_github_workflow_deploy` with repo, PR, target, workflow, ref, SHA input, merge SHA, health URL, and field. Never pass Coolify credentials. Preserve every legacy route.

- [ ] **Step 4: Run GREEN and commit**

Run:

```bash
bash tests/otta-deploy-verify.test.sh
bash tests/github-workflow-deploy.test.sh
bash tests/write-otta-contract.test.sh
bash tests/ledger-append.test.sh
```

Expected: PASS.

```bash
git add scripts/otta-deploy-verify.sh tests/otta-deploy-verify.test.sh
git commit -m "feat(#137): orchestrate workflow deployments"
```

### Task 6: Document operation and recovery

**Files:**
- Modify: `commands/setup.md`
- Modify: `commands/ship.md`
- Modify: `commands/dev.md`
- Modify: `commands/status.md`
- Modify: `README.md`
- Modify: `docs/why-otta-setup.md`

- [ ] **Step 1: Document configuration and approval**

Document all writer flags/flat keys and `--approved-head`. Explain that any changed head invalidates approval.

- [ ] **Step 2: Document the mutation boundary and load controls**

State that Otta controls approval, merge, dispatch, and verification while the configured GitHub workflow is the sole infrastructure mutation authority. Require one production concurrency group with cancellation disabled, reuse of build artifacts, and no parallel Otta/provider/webhook deployment initiation.

- [ ] **Step 3: Document recovery**

Give commands to inspect/resume a recorded run, resolve `dispatch_unknown`, explicitly retry failure, and invoke the repository-owned rollback workflow. Otta never guesses on ambiguous correlation.

- [ ] **Step 4: Check stale claims and commit**

Run:

```bash
rg -n "merge-and-deploy|human-approve|github-workflow|approved-head|mutation authority" README.md commands docs
rg -n "deploy.*only has.*target.*project|downstream deploy is handled outside Otta" README.md commands docs
```

Expected: consistent new contract; no stale universal claims.

```bash
git add README.md commands/setup.md commands/ship.md commands/dev.md commands/status.md docs/why-otta-setup.md
git commit -m "docs(#137): explain workflow deployment control"
```

### Task 7: Verify and dogfood safely

**Files:**
- Modify: `.pr-body.md`

- [ ] **Step 1: Run all plugin tests and syntax checks**

```bash
for test_file in tests/*.test.sh; do bash "$test_file"; done
bash -n scripts/github-workflow-deploy.sh scripts/otta-deploy-verify.sh scripts/write-otta-contract.sh
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Dogfood a non-mutating workflow**

Use a workflow that only echoes the supplied SHA and includes it in the run name. Configure `target: test`, a temporary ledger, and a health fixture returning the same SHA. Invoke twice for one identity. Prove the first reaches runtime verification, the second reuses it, GitHub shows exactly one run, and no Coolify/production resource was contacted.

- [ ] **Step 3: Fill acceptance evidence and run the gate**

Replace `.pr-body.md` placeholders with exact commands, the fixture run URL, and direct evidence for AC1–AC8. Then run:

```bash
OTTA_PLUGIN_ROOT='/Users/wiselancer/.codex/plugins/cache/otta/otta/1.1.3' bash scripts/otta-gate.sh .pr-body.md
```

Expected: PASS for every locally evaluable layer.

- [ ] **Step 4: Commit evidence**

```bash
git add .pr-body.md
git commit -m "test(#137): record deployment controller evidence"
```

## Builder constraints

- Work only in `/Users/wiselancer/jean/otta/plugin-137` on `otta/137`.
- Retain `OTTA_PLUGIN_ROOT=/Users/wiselancer/.codex/plugins/cache/otta/otta/1.1.3` for canonical Otta commands.
- Do not open or push a PR; reviewer and QA run first.
- Do not contact Coolify, LeadCognition production, or a production workflow during plugin tests.
- Preserve the corrected conclusion that #138 was not a shell-injection defect.
