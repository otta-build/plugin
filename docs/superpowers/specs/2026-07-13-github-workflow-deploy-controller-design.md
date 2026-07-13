# GitHub Workflow Deploy Controller Design

**Issue:** [otta-build/plugin#137](https://github.com/otta-build/plugin/issues/137)

**Status:** Approved direction; implementation pending

**Date:** 2026-07-13

## Goal

Make Otta the lifecycle controller for production delivery without creating a second deployment implementation. Otta will obtain explicit human production approval, merge the reviewed pull request, dispatch the repository's existing GitHub Actions deployment workflow exactly once for the merged commit, and verify both the workflow result and the commit running in production.

For LeadCognition, GitHub Actions remains the only component allowed to mutate the production Coolify application. This preserves the existing secrets and rollback boundary while moving deployment orchestration and evidence into Otta.

## Non-goals

- Otta will not call Coolify directly for ordinary production feature deployments.
- This change will not replace repository-specific build, migration, rollback, or smoke-test logic.
- This change will not make a green preview equivalent to production approval.
- This change will not introduce a second runner on the Hetzner application host.
- This change will not make Pulse autonomously approve production deployments.

## Current problem

Otta's `human-approve` mode stops after approval and PR creation. Its `merge-and-deploy` mode can merge and verify a deployment, but it does not initiate one. Repositories therefore need an external actor to dispatch their deployment workflow, leaving a gap between the Otta lifecycle and the actual production mutation.

LeadCognition also runs CI, deployment preparation, and production services on the same Hetzner server. Duplicate builds and overlapping deployment attempts consume the same CPU, memory, disk, and Docker resources. Faster delivery requires less duplicate work and stricter serialization, not more concurrency on that host.

## Chosen architecture

```text
Issue
  -> Otta build/review/QA gates
  -> pull request and preview evidence
  -> explicit human production approval
  -> Otta merges reviewed PR
  -> Otta dispatches one GitHub Actions workflow for merged SHA
  -> GitHub Actions performs the sole Coolify mutation
  -> Otta polls the workflow to a terminal result
  -> Otta verifies production health reports the merged SHA
  -> Otta records lifecycle evidence in its ledger/Pulse
```

The control and mutation boundaries are intentionally separate:

- **Otta owns lifecycle state:** gates, approval, merge, dispatch identity, verification, and evidence.
- **GitHub Actions owns deployment execution:** repository checkout, build/deploy commands, Coolify interaction, serialization, and rollback entry points.
- **Coolify owns application runtime:** container replacement and health.
- **The repository health endpoint owns runtime commit truth:** a successful deployment is not accepted until the expected commit is reported live.

## Contract extension

The existing v2 `.otta.yml` contract remains valid. Deployment execution is an additive configuration surface. A representative configuration is:

```yaml
version: 2
deploy:
  mode: human-approve
  target: production
  project: leadcognition
  executor: github-workflow
  workflow: deploy-production.yml
  ref: main
  sha_input: commit_sha
  provider: coolify
  verify: health-sha
  health_url: https://app.leadcognition.io/health
  health_commit_field: commit
```

The final field names must be kept minimal during implementation, but the contract must express:

- the executor type;
- the GitHub workflow file or numeric workflow ID;
- the dispatch ref;
- the input that carries the expected merged SHA, if the workflow accepts one;
- the provider used for evidence attribution; and
- the existing verification mode plus the health URL and JSON field used for
  commit verification.

Existing repositories without `executor: github-workflow` retain their current behavior. Existing `human-approve`, `merge-on-green`, and legacy verification-only configurations must not begin dispatching workflows implicitly.

## Approval semantics

Human production approval and deployment execution are separate decisions:

1. Otta completes build, independent review, QA, repository gates, and preview validation where applicable.
2. Otta presents the exact PR head, target environment, workflow, and production hostname for approval.
3. Approval authorizes one merge-and-dispatch attempt for that immutable change.
4. A changed PR head invalidates prior approval.
5. Approval is never inferred from CI success, preview success, issue status, or an earlier deployment.

The CLI should report the pending action plainly. It must not say production is deployed after merge or dispatch alone.

## Exactly-once dispatch

The stable deployment identity is:

```text
repository + workflow + environment + merged_commit_sha
```

Before dispatch, Otta checks its append-only ledger for that identity. The state machine is:

```text
approved -> dispatching -> dispatched -> workflow_succeeded -> runtime_verified
                         \-> workflow_failed
              \-> dispatch_unknown
```

Otta writes `dispatching` before the network call and records the GitHub response immediately afterward. A retry behaves as follows:

- `runtime_verified`: return the existing success evidence without dispatching.
- `dispatched` or a known workflow run: resume polling that run.
- `workflow_failed`: report failure and require an explicit retry/recovery action.
- `dispatch_unknown`: reconcile GitHub workflow runs for the workflow, ref, commit, and dispatch time window before deciding whether a new dispatch is safe.
- no record: perform the first dispatch.

This is at-most-once by default during uncertainty. Avoiding duplicate production mutations is more important than automatically retrying an ambiguous API timeout.

## Workflow run correlation

GitHub's workflow-dispatch response does not reliably return a run ID. Otta therefore records a dispatch timestamp and correlates the resulting run using the configured workflow, repository, event type, ref, expected SHA/input, actor, and a bounded creation-time window.

The production workflow should expose the requested commit SHA in its run metadata and deploy that exact SHA. If the workflow cannot accept a SHA input, Otta dispatches the immutable post-merge ref and verifies the resolved run head before accepting it. Multiple plausible runs are an error, not a reason to guess.

## Verification and failure handling

Otta polls the correlated GitHub Actions run until a terminal conclusion or configured timeout.

- Dispatch rejection: fail with the GitHub API error and no deployment claim.
- Run not found: enter `dispatch_unknown` and provide a recovery command.
- Run failure/cancellation: record the run URL and conclusion; do not retry automatically.
- Poll timeout: preserve the run identity so a later invocation resumes verification.
- Workflow success but wrong health SHA: fail the deployment verification and report expected versus observed commit.
- Health endpoint unavailable: retry with bounded backoff, then fail without hiding the successful workflow result.

Success requires both:

1. the correlated GitHub Actions run completed successfully; and
2. the configured production health endpoint reports the expected merged commit.

All output and ledger records must avoid tokens, workflow inputs marked secret, and raw environment values.

## LeadCognition host-load controls

The LeadCognition deployment workflow remains the enforcement point for host protection:

- one production deployment concurrency group with cancellation disabled;
- one deploy runner job at a time;
- build artifacts produced once and reused where practical instead of rebuilding on the host;
- no simultaneous preview cleanup or image pruning in the critical deployment section;
- health and commit verification after container replacement;
- stale preview cleanup through Coolify's preview registry path, outside the production deploy critical section; and
- conservative Docker cleanup based on measured disk pressure, not unconditional pruning.

Otta must respect GitHub's queue rather than adding parallel dispatches. It may report queue duration separately from execution duration so future optimization targets the actual bottleneck.

## Security boundary

- Workflow permissions should be least privilege: Otta needs Actions dispatch/read and PR merge access, not Coolify credentials.
- Coolify tokens remain scoped to GitHub Actions and stored in the existing secret authority.
- Otta logs identifiers and URLs, never token values or sensitive workflow inputs.
- The target repository, workflow, environment, production hostname, and expected SHA are shown before approval.
- The issue/PR body seeder must render issue text literally before this feature is built. [otta-build/plugin#138](https://github.com/otta-build/plugin/issues/138) is a prerequisite because its current unquoted heredoc can execute backticks or command substitutions from issue text.

## Alternatives considered

### Otta calls Coolify directly

Rejected for ordinary deployments. It would duplicate deployment logic, broaden Otta's secret access, bypass repository gates, and create two mutation authorities.

### GitHub Actions deploys automatically after merge

Fast, but it leaves Otta observing rather than controlling deployment and weakens the explicit human production approval boundary. It remains a valid repository policy outside this feature, not the LeadCognition target.

### Pulse performs autonomous deployment

Deferred. Pulse can supply evidence and lifecycle visibility, but it should not become the approval authority until the explicit Otta flow is reliable and audited.

## Rollout

### Phase 1: Otta plugin

1. Fix and independently verify the literal-rendering seeder vulnerability in issue #138.
2. Add failing contract and deployment-controller tests for issue #137.
3. Implement additive config parsing, approval invalidation, dispatch reconciliation, polling, and health-SHA verification.
4. Verify legacy deployment modes remain unchanged.
5. Document normal operation, ambiguous-dispatch recovery, manual retry, and rollback boundaries.

### Phase 2: LeadCognition adoption

1. Land LC-1064's immediate runner/deployment contention controls and validate their post-merge production effect.
2. Add the Otta GitHub-workflow executor configuration in a dedicated Linear-linked LeadCognition change.
3. Ensure `deploy-production.yml` accepts or deterministically resolves the approved merged SHA and remains the only Coolify mutation authority.
4. Run one controlled production deployment through Otta.
5. Verify GitHub workflow success, `/health.commit`, Linear release state, and Otta lifecycle evidence before declaring the rollout complete.

## Test strategy

Implementation begins with failing tests for:

- v2 config parsing and legacy compatibility;
- approval invalidation when the PR head changes;
- one dispatch for repeated invocations with the same identity;
- ambiguous dispatch reconciliation without duplicate mutation;
- workflow run correlation and multiple-match rejection;
- successful, failed, cancelled, missing, and timed-out workflow runs;
- successful workflow with stale or incorrect production commit;
- resumable polling after interruption; and
- redaction of credentials and sensitive inputs.

Focused tests run first, followed by every plugin shell test. LeadCognition adoption additionally runs repository-focused tests, the nearest package target, typecheck, preview validation, strict readiness checks, and a post-deployment health-commit smoke test.

## Completion evidence

The feature is complete only when all of the following exist:

- merged Otta plugin PRs for #138 and #137 with independent review and green tests;
- a Linear-linked LeadCognition adoption PR with green CI and resolved review threads;
- explicit human production approval tied to an immutable commit;
- one correlated GitHub Actions production run for that commit;
- production health reporting the same commit;
- Otta ledger/Pulse evidence covering approval through runtime verification; and
- GitHub, Linear, deployment, and remaining-action state reported in the final handoff.
