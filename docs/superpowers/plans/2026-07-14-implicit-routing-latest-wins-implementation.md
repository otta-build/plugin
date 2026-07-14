# Implicit Routing and Latest-Wins Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Otta route ordinary developer intent through its complete lifecycle and safely coordinate environment-specific GitHub Workflow releases without breaking legacy repositories.

**Architecture:** Keep the canonical behavior in repository scripts and command documents. Add one context-policy installer for Claude Code and Codex, extend the existing deploy parser with a backward-compatible environment resolver, and teach the GitHub Workflow controller to classify proven descendant successors while GitHub concurrency remains the host-load serialization boundary. Provider credentials and provider APIs remain outside Otta.

**Tech Stack:** Bash 3.2-compatible scripts, Python 3 standard library for structured fixture parsing, GitHub CLI/API, Markdown command/skill adapters, shell test suites.

---

### Task 1: Install the cross-harness intent policy

**Files:**
- Create: `scripts/install-otta-intent-policy.sh`
- Create: `tests/implicit-routing.test.sh`
- Modify: `commands/setup.md`
- Modify: `README.md`

- [ ] **Step 1: Write the failing routing-policy test**

Create a temporary repository with existing custom `CLAUDE.md` and `AGENTS.md` content. Run the installer twice and assert both files preserve the custom content, contain exactly one `<!-- otta:intent-begin -->` block, name all ten canonical operations, state that explicit invocation wins, and state that read-only/status intent cannot mutate state.

```bash
for file in CLAUDE.md AGENTS.md; do
  [ "$(grep -c '<!-- otta:intent-begin -->' "$TMP/repo/$file")" -eq 1 ]
  grep -Fq 'Explicit Otta invocation always wins.' "$TMP/repo/$file"
  grep -Fq 'Read-only and status requests never authorize writes.' "$TMP/repo/$file"
  for operation in setup start dev build fix ship status schedule remember pulse-doctor; do
    grep -Eq "(^|[[:space:]|])${operation}([[:space:]|]|$)" "$TMP/repo/$file"
  done
done
```

- [ ] **Step 2: Run the test and confirm RED**

Run: `bash tests/implicit-routing.test.sh`

Expected: FAIL because `scripts/install-otta-intent-policy.sh` does not exist.

- [ ] **Step 3: Implement the idempotent installer**

The script accepts repository root plus an optional harness list, defaults to both Claude Code and Codex, and replaces only its delimited block. The installed policy must use this routing table:

```text
setup          first state-changing request without a valid Otta contract
start          begin a known issue and seed acceptance criteria
dev            standard issue-linked implementation
build          explicit autonomous builder-reviewer-QA-devops pipeline
fix            tiny issue-linked change
ship           release, staging, or production intent
status         released, blocked, continue, or resume intent
schedule       recurring autonomous work intent
remember       promote a verified delivery learning
pulse-doctor   diagnose missing Otta/Pulse checks
```

The block must also define precedence: explicit Otta invocation, direct setup/status/schedule/memory intent, issue-linked dev/fix, then release intent. Ambiguous production targets, rollbacks, and unconfigured repositories pause instead of guessing.

- [ ] **Step 4: Wire setup and document the implicit interface**

Update setup's confirmed write summary and execution phase to call:

```bash
OTTA_PLUGIN_ROOT="${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}" \
  bash "${OTTA_PLUGIN_ROOT}/scripts/install-otta-intent-policy.sh" "$(git rev-parse --show-toplevel)"
```

Document that natural language is the normal interface while explicit Claude commands and Codex skills remain deterministic recovery/API surfaces.

- [ ] **Step 5: Run focused tests and commit**

Run:

```bash
bash tests/implicit-routing.test.sh
bash tests/codex-plugin-parity.test.sh
bash tests/otta-setup-v2.test.sh
```

Expected: all pass.

Commit: `feat(#151): install cross-harness intent routing`

### Task 2: Resolve named deployment environments without breaking flat config

**Files:**
- Create: `scripts/otta-deploy-config.sh`
- Create: `tests/otta-deploy-environments.test.sh`
- Modify: `scripts/otta-deploy-verify.sh`
- Modify: `scripts/write-otta-contract.sh`
- Modify: `tests/write-otta-contract.test.sh`

- [ ] **Step 1: Write failing environment-resolution tests**

Cover these fixtures:

```yaml
deploy:
  default: production
  environments:
    staging:
      auto: merge-and-deploy
      target: staging
      executor: github-workflow
      workflow: deploy-staging.yml
      ref: staging
      sha_input: sha
      verify: health-sha
      health_url: https://staging.example.test/health
      health_commit_field: commit
    production:
      auto: human-approve
      target: production
      executor: github-workflow
      workflow: deploy-production.yml
      ref: main
      sha_input: sha
      verify: health-sha
      health_url: https://app.example.test/health
      health_commit_field: commit
```

Assert `resolve_deploy_environment <file> ''` selects `production`, an explicit `staging` selects staging, an unknown name fails, and a legacy flat block returns the original values with environment `legacy`.

- [ ] **Step 2: Run the test and confirm RED**

Run: `bash tests/otta-deploy-environments.test.sh`

Expected: FAIL because the resolver does not exist.

- [ ] **Step 3: Implement the narrow YAML-subset resolver**

Expose these sourceable functions without adding a yq/PyYAML dependency:

```bash
deploy_has_named_environments <yml>
parse_deploy_default_environment <yml>
resolve_deploy_environment <yml> [requested]
deploy_config_value <yml> <environment-or-legacy> <key>
```

Parse only scalar keys in the existing `deploy` block and one `deploy.environments.<name>` nesting level. Reject duplicate environment names, tabs, missing defaults, and non-scalar values for known keys. Do not evaluate configuration as shell code.

- [ ] **Step 4: Thread `--environment` through deploy verification**

Extend the command contract:

```text
otta-deploy-verify.sh <pr> [--environment <name>] [existing recovery flags]
```

All `parse_deploy_*` functions keep their existing one-argument behavior for flat files and accept an optional resolved environment. The policy banner prints `environment=<name>` so another harness can resume from durable output.

- [ ] **Step 5: Add additive contract generation**

Add optional writer flags `--deploy-default-environment`, `--deploy-staging-workflow`, `--deploy-staging-health-url`, `--deploy-production-workflow`, and `--deploy-production-health-url`. Every emitted environment must contain complete workflow, verification, health URL, and health-field evidence. Only emit `deploy.environments` when the default-environment flag is present; otherwise byte-for-byte preserve the flat shape used by existing tests.

- [ ] **Step 6: Run focused tests and commit**

Run:

```bash
bash tests/otta-deploy-environments.test.sh
bash tests/otta-deploy-verify.test.sh
bash tests/write-otta-contract.test.sh
```

Expected: all pass, including every legacy assertion.

Commit: `feat(#151): add named deployment environments`

### Task 3: Add fail-closed latest-eligible-wins successor classification

> **Safety correction (approved during implementation):** A raw queued or running `workflow_dispatch`, even with an exact SHA title marker, is not durable proof that the candidate is policy-eligible. The default controller therefore reports such a candidate as non-terminal `successor_pending`/blocked and never skips or cancels the active approved release. Automatic `included` classification requires a same-environment descendant, successful repository workflow, ancestry proof, and current runtime SHA proof. The pure `superseded` path remains available only when a future integration explicitly supplies durable `candidate_policy_eligible=true`; Otta does not infer that proof from dispatch state or a local-only ledger. Without such a source, preemptive supersession is disabled and the repository's non-cancelling concurrency still coalesces pending B-I while keeping at most one active plus one pending request.

**Files:**
- Modify: `scripts/github-workflow-deploy.sh`
- Create: `tests/github-workflow-latest-wins.test.sh`
- Modify: `tests/github-workflow-deploy.test.sh`

- [ ] **Step 1: Write the failing pure-decision tests**

Add fixtures for ten ordered requests and expose a pure classifier with this contract:

```bash
classify_release_successor \
  <older-sha> <older-environment> <candidate-sha> <candidate-environment> \
  <candidate-policy-eligible> <candidate-state> <compare-status>
```

Expected results:

```text
same environment + eligible + queued/running + compare ahead    => superseded
same environment + eligible + runtime_verified + compare ahead => included
same SHA + runtime_verified                                     => included
different environment                                           => blocked
eligible=false                                                   => blocked
compare divergent/behind/unknown                                 => blocked
cancelled without proven successor                               => blocked
rollback target                                                  => blocked
```

- [ ] **Step 2: Run the test and confirm RED**

Run: `bash tests/github-workflow-latest-wins.test.sh`

Expected: FAIL because the classifier is missing.

- [ ] **Step 3: Implement successor discovery from GitHub evidence**

Add:

```bash
find_eligible_successor <repo> <workflow> <ref> <environment> <older-sha>
```

List `workflow_dispatch` runs for the configured workflow/ref and require exact standalone environment and SHA markers in the display title. Queued/in-progress candidates return non-terminal `successor_pending`; they are never considered policy-eligible by default. An included successor requires successful workflow evidence, a live runtime SHA match, and GitHub compare proof of same-SHA or descendant ancestry. Filter for successful, runtime-relevant candidates before applying recency: a newer cancelled duplicate cannot hide an older successful run, while duplicate successful runs for the same verified live SHA are idempotent and use the newest successful proof. Never classify from `main` advancement or a local-only ledger alone. Multiple materially different successor SHAs matching runtime evidence return blocked/ambiguous.

- [ ] **Step 4: Integrate outcomes without unsafe redispatch**

When a recorded run is cancelled or replaced, consult the successor resolver before returning failure. Append `deploy_included` only with workflow, ancestry, and live runtime proof. Append `deploy_superseded` only when an explicitly configured durable eligibility source supplies proof; no such source is inferred by default. Keep `deploy_dispatch_unknown`, failed-run recovery, and at-most-once dispatch behavior unchanged. The same repository/environment lock key remains the local optimization; repository workflow concurrency remains the cross-machine serialization boundary.

- [ ] **Step 5: Prove the 10-request and recovery matrix**

The test simulates A through J, with GitHub retaining one active and one pending run. Assert B-I never become runtime-verified individually, A and J never overlap provider mutation, queued/running J never causes optimistic supersession, and every older request remains blocked until J is included with descendant plus live runtime evidence. Add restart fixtures using pre-existing ledger records and cancelled pending runs.

- [ ] **Step 6: Run focused tests and commit**

Run:

```bash
bash tests/github-workflow-latest-wins.test.sh
bash tests/github-workflow-deploy.test.sh
bash tests/otta-deploy-verify.test.sh
```

Expected: all pass.

Commit: `feat(#151): classify latest eligible releases`

### Task 4: Validate the repository-owned workflow safety contract

**Files:**
- Create: `scripts/otta-deploy-readiness.sh`
- Create: `tests/otta-deploy-readiness.test.sh`
- Modify: `scripts/otta-readiness.sh`
- Modify: `commands/setup.md`
- Modify: `docs/why-otta-setup.md`

- [ ] **Step 1: Write failing static workflow-validation tests**

Fixtures must include one valid generic workflow and failures for missing `workflow_dispatch`, missing SHA input, missing standalone environment/SHA `run-name`, an ordinary push trigger on the configured workflow, `cancel-in-progress: true`, environment-independent concurrency, missing same-SHA no-op marker, missing health verification, and competing push-triggered production workflows using scalar, sequence, quoted-key, and block trigger syntax. Comments and `pull_request` triggers must not produce false positives.

- [ ] **Step 2: Run the test and confirm RED**

Run: `bash tests/otta-deploy-readiness.test.sh`

Expected: FAIL because the deploy readiness script does not exist.

- [ ] **Step 3: Implement read-only validation**

`otta-deploy-readiness.sh [--otta-yml path] [--environment name]` must inspect committed configuration and workflow text without mutation. It prints one PASS/WARN/FAIL line per invariant and exits non-zero for mutation-safety failures. A configured `shared_host: true` produces a warning that repository-local concurrency is insufficient and recommends a single-capacity shared runner or external host semaphore; it must not install a broker.

- [ ] **Step 4: Integrate the readiness score and setup flow**

The general readiness script invokes deploy readiness only when a GitHub Workflow executor is configured. Setup shows the failures before calling the repository ready. No-runtime and legacy non-workflow repositories remain valid and are explicitly reported as not applicable.

- [ ] **Step 5: Run focused tests and commit**

Run:

```bash
bash tests/otta-deploy-readiness.test.sh
bash tests/otta-readiness.test.sh
bash tests/otta-setup-v2.test.sh
```

Expected: all pass.

Commit: `feat(#151): validate deploy workflow safety`

### Task 5: Complete parity, status, and full verification

**Files:**
- Modify: `commands/ship.md`
- Modify: `commands/status.md`
- Modify: `commands/dev.md`
- Modify: `commands/build.md`
- Modify: `skills/otta-ship/SKILL.md` only if adapter metadata needs a trigger clarification
- Modify: `skills/otta-status/SKILL.md` only if adapter metadata needs a trigger clarification
- Modify: `tests/codex-plugin-parity.test.sh`
- Modify: `tests/otta-status.test.sh`
- Modify: `.pr-body.md`

- [ ] **Step 1: Write failing parity and status assertions**

Assert canonical command documents pass environment arguments identically in Claude and Codex, status renders `runtime_verified`, `included`, `superseded`, `failed`, `dispatch_unknown`, and `blocked`, and adapter files delegate rather than copy policy.

- [ ] **Step 2: Run tests and confirm RED**

Run:

```bash
bash tests/codex-plugin-parity.test.sh
bash tests/otta-status.test.sh
```

Expected: at least the new environment/outcome assertions fail.

- [ ] **Step 3: Update canonical lifecycle documentation and status rendering**

Ship accepts natural target intent or `--environment`, requires exact-head approval for production, and passes the resolved environment to deploy verification. Status reads GitHub evidence first and reports local ledger data only as corroboration. Conflicting exact-SHA evidence yields blocked, never optimistic success.

- [ ] **Step 4: Fill the PR body with real evidence**

Replace the placeholder summary/acceptance block, preserve `idea_ref: issue:#148`, check an AC only after its focused proof passes, and list every focused command plus the full gate.

- [ ] **Step 5: Run the complete gate**

Run:

```bash
bash tests/implicit-routing.test.sh
bash tests/otta-deploy-environments.test.sh
bash tests/github-workflow-latest-wins.test.sh
bash tests/otta-deploy-readiness.test.sh
bash tests/github-workflow-deploy.test.sh
bash tests/otta-deploy-verify.test.sh
bash tests/codex-plugin-parity.test.sh
bash tests/otta-status.test.sh
bash scripts/otta-gate.sh
git diff --check origin/main...HEAD
```

Expected: every command passes and the diff contains no whitespace errors.

- [ ] **Step 6: Commit final integration**

Commit: `feat(#151): complete implicit delivery routing`
