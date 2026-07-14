# Implicit Cross-Harness Delivery Routing

**Status:** Proposed
**Issue:** [#148](https://github.com/otta-build/plugin/issues/148)
**Baseline:** Otta v1.4.1

## Summary

Developers should express intent in ordinary language while Otta selects and
enforces the correct lifecycle operation. The explicit Otta commands remain a
stable internal API, a deterministic automation interface, and a recovery path;
they are not vocabulary every developer must memorize.

The design keeps GitHub as the shared source of delivery truth, repository-owned
GitHub Actions as the only ordinary infrastructure mutation boundary, and one
canonical Otta implementation behind thin Claude Code and Codex adapters. It
adds optional environment profiles and latest-wins release semantics without a
central release broker, provider-specific Otta code, or a new production
database.

## Goals

- Route natural-language development and delivery intent through the complete
  Otta command surface in Claude Code and Codex.
- Make forgetting an explicit command harmless through repository and GitHub
  enforcement.
- Support GitHub projects with staging and production, production only, package
  publication, or no runtime deployment.
- Coalesce bursts of 5-10 release attempts into the newest eligible deployment
  while preserving visible outcomes for every request.
- Keep deployment provider-neutral and protect constrained application hosts
  from overlapping release work.
- Preserve existing v1.4.1 repositories and explicit command invocations.

## Non-goals

- A central Otta Pulse release broker or release database.
- Distributed leases, fencing tokens, or custom team RBAC.
- Provider adapters inside Otta for Coolify, GCP, Vercel, Cloudflare, or AWS.
- Cross-repository scheduling for several projects sharing one deployment host.
- Replacing GitHub branch protection, checks, Actions, or environments.
- Supporting non-GitHub source-control providers in this version.
- Making staging mandatory before an explicitly approved production release.

## Design principles

1. **Intent is the interface; commands are the protocol.** Natural language is
   translated into a canonical Otta operation before any state-changing work.
2. **One core, two adapters.** Claude Code commands and Codex skills delegate to
   the same command documents, scripts, configuration parser, and state model.
3. **Prompts assist; gates enforce.** Local routing improves DX, while required
   GitHub checks and repository workflows remain authoritative when an agent
   forgets or ignores local guidance.
4. **Capabilities are configured, not inferred at release time.** Setup may
   propose staging or deployment workflows, but committed `.otta.yml` is the
   authority. Otta never invents staging because a branch happens to exist.
5. **Latest eligible wins.** Intermediate deployment requests may be coalesced
   only when a newer approved request includes their commit.
6. **Provider logic stays in the repository.** Otta dispatches and verifies a
   workflow; it never needs the provider credential or deployment API.

## Architecture

```text
developer intent
      |
      v
Claude adapter or Codex adapter
      |
      v
canonical Otta operation
      |
      +--> repository contract + local gate
      |
      v
GitHub issue / PR / checks / workflow run
      |
      v
repository-owned provider workflow
      |
      v
runtime verification + release evidence
```

The adapter performs only harness-specific argument binding, progress display,
and invocation. Durable progress is reconstructed from the GitHub issue, PR,
check runs, workflow runs, merge SHA, and runtime verification. A local ledger
may accelerate recovery but is never the only evidence needed by another
developer, machine, or harness.

## Complete command and intent routing

Explicit invocation always wins. Otherwise, the router selects the narrowest
operation that satisfies the developer's intent.

| Canonical operation | Example natural-language intent | Automatic behavior | Required pause |
| --- | --- | --- | --- |
| `otta setup` | "Use Otta here", or first state-changing request in an unconfigured repo | Inspect the repository and propose the onboarding contract | Confirm repository writes, App installation, and environment choices |
| `otta start` | "Start issue #148" | Seed the issue-linked branch and PR acceptance contract | Missing or non-falsifiable acceptance criteria |
| `otta dev` | "Implement this issue" or "build this feature" | Run the full issue-to-release lifecycle | Genuine product or production decisions |
| `otta build` | "Run the full Otta build" | Run builder, reviewer, QA, and devops sequentially with bounded repair | Repeated blocker or exhausted repair bound |
| `otta fix` | "Make this small issue-linked fix" | Use the reduced issue-linked TDD path | Missing issue or test-impractical rationale |
| `otta ship` | "Ship it", "release it", "deploy staging", or "go directly to production" | Gate, open or resolve the PR, then apply the configured environment policy | Exact-SHA production approval, rollback, or ambiguous target |
| `otta status` | "Is it released?", "what is blocked?", or "continue" | Reconstruct the lifecycle from durable evidence before resuming | Contradictory or insufficient evidence |
| `otta schedule` | "Run this every weekday" or "schedule the next suitable issue" | Configure the supported autonomous routine | Schedule, scope, or mutation authority is ambiguous |
| `otta remember` | "Remember this delivery lesson" | Propose a durable repository learning from verified evidence | Human approval before promoting a new standing rule |
| `otta pulse-doctor` | "Why is the Otta gate missing?" or "check Pulse installation" | Run the read-only installation and permission diagnosis | Credentials or App-owner action is required |

### Routing precedence

1. An explicit Otta command or skill invocation.
2. A direct status, setup, rollback, scheduling, or memory intent.
3. A state-changing issue request, routed to `dev` or `fix` by scope.
4. A release intent, routed to `ship` with its requested or configured target.
5. If no route is safe, explain the missing issue, target, or configuration
   instead of guessing.

Read-only questions never become writes. Production approval and rollback are
never inferred from vague language such as "continue" or "looks good".

## First-touch setup

On the first state-changing request in a repository without a valid Otta
contract, the router enters setup before start, dev, build, fix, or ship.

Setup:

1. Detects the GitHub repository, default branch, harnesses, workflows, health
   endpoints, and possible environment branches.
2. Shows a proposed `.otta.yml`, hooks, required checks, and Pulse onboarding.
3. Asks once before writing repository files or requesting GitHub App changes.
4. Creates a reviewable onboarding change rather than silently modifying the
   protected branch.
5. Installs local convenience hooks while documenting that server-side checks
   are the enforcement boundary.
6. Validates the configured workflow before calling the repository ready.

Setup detection is advisory. A detected `staging` branch is offered as a
profile; it is not enabled until committed configuration says so.

## Environment contract

The v1.4.1 flat `deploy` contract remains valid and behaves as one configured
environment. New repositories may opt into named profiles:

```yaml
deploy:
  default: production
  environments:
    staging:
      workflow: deploy-staging.yml
      ref: staging
      sha_input: sha
      approval: automatic
      verify: health-sha
      health_url: https://staging.example.com/health
      health_commit_field: commit
    production:
      workflow: deploy-production.yml
      ref: main
      sha_input: sha
      approval: human
      verify: health-sha
      health_url: https://app.example.com/health
      health_commit_field: commit
```

Profiles are optional:

- **Staging plus production:** `release` uses `deploy.default`; explicit
  "staging" or "direct production" selects that target.
- **Production only:** omit staging. Release requires the production policy.
- **No runtime deployment:** omit environment profiles or configure a package
  publication workflow. The lifecycle may end at a verified PR, merge, tag, or
  package release.

Staging approval never authorizes production. Direct production remains allowed
when production gates pass and a human approves the exact current PR head.

## Latest-wins release behavior

Each repository environment uses one non-cancelling GitHub Actions concurrency
group. The default single pending slot intentionally coalesces a burst rather
than executing every intermediate release.

Example with approved requests A through J:

```text
A starts
B becomes pending
C replaces B
...
J replaces I

A checks for a newer eligible request containing A
  -> if J is proven, A becomes superseded without provider mutation
J deploys and verifies once
B-I resolve as included in J
```

### Eligibility rules

An active or cancelled request is superseded only when Otta can identify a
newer request for the same repository and environment whose commit:

- is a descendant of the older commit;
- passed the required release policy;
- carries the exact-SHA workflow marker; and
- is queued, running, succeeded, or runtime verified.

Advancement of `main` alone is not enough. A newer commit may not have received
production approval. Divergent commits, force pushes, and rollback targets fail
closed instead of being classified as included.

### Outcomes

- `runtime_verified`: the exact requested commit is live.
- `included`: a verified descendant release contains the requested commit.
- `superseded`: a proven eligible descendant is taking responsibility, but has
  not yet completed.
- `failed`: the selected workflow or runtime verification failed.
- `dispatch_unknown`: Otta cannot safely correlate the dispatch.
- `blocked`: policy, approval, or evidence is insufficient.

A GitHub concurrency cancellation is not automatically a failure. It becomes
`included` or `superseded` only with descendant evidence; otherwise it remains
failed or blocked with a recovery action.

## Provider and host boundary

Otta requires a repository-owned GitHub workflow with an exact SHA input and an
observable verification contract. The workflow may deploy through Coolify,
Cloud Run, GKE, Vercel, Cloudflare, AWS, or another provider. Provider secrets
remain in GitHub OIDC, environments, or repository secrets.

Setup validates what can be proven statically:

- the workflow is manually dispatchable;
- the exact SHA input appears as a standalone run-title marker;
- the environment concurrency group does not cancel an active release;
- same-SHA live state can become a successful no-op;
- the configured verification field exists; and
- competing ordinary production triggers are called out.

For projects sharing one constrained host across repositories, setup warns that
repository-local concurrency is insufficient. A single-capacity shared runner
or an external host semaphore is an advanced deployment concern, not part of
the default Otta controller.

## Enforcement and evidence

Implicit routing is a convenience layer. A merge or release is trustworthy only
when GitHub proves the required outputs:

- issue linkage and falsifiable acceptance criteria;
- test evidence or a valid test-impractical rationale;
- required CI and Otta Gate checks;
- resolved blocking human review threads;
- exact PR head approval for production;
- correlated repository workflow run; and
- exact runtime commit or configured provider deployment evidence.

Branch protection and required checks prevent an agent that forgot Otta from
shipping incomplete work. Provider-side automatic production triggers are
disabled or restricted so the repository workflow remains the sole ordinary
mutation authority. Break-glass provider access and rollback stay explicit and
audited.

## Cross-harness resumption

A Claude Code session and a Codex session must resolve the same next action for
the same issue or PR. Status resolution reads GitHub first and treats local
ledger state as corroboration. If the ledger says dispatched while GitHub shows
a different exact-SHA run, Otta reports the contradiction and stops.

The canonical command documents and scripts remain the implementation source of
truth. Claude command metadata and Codex skill metadata may describe triggers,
but they must not duplicate lifecycle policy.

## Failure and recovery

- Changed PR head: invalidate production approval.
- Ambiguous dispatch: record `dispatch_unknown`; never redispatch implicitly.
- Cancelled pending run with a proven descendant: report `superseded` or
  `included`.
- Cancelled run without a successor: report failure with the run URL.
- Workflow success with wrong runtime SHA: fail verification.
- Unavailable or malformed health evidence: retry with bounds, then fail closed.
- New release arrives during failure: do not hide the failure; a proven
  descendant may take over only through the normal eligibility rules.
- Rollback: invoke the repository's explicit rollback workflow with a known-good
  immutable target and separate approval.

## Compatibility and migration

- Existing flat v1.4.1 `deploy` blocks continue to parse and execute unchanged.
- Named environments are additive and opt-in.
- Explicit Claude commands and Codex skills remain supported indefinitely.
- Setup can propose a migration from a flat block, but never rewrites it without
  approval.
- Status can read old ledger records and reports the environment recorded in
  their existing target field.

## Verification plan

### Routing matrix

Run every natural-language route and explicit fallback in Claude Code and Codex
for all ten canonical operations. Confirm both adapters bind the same arguments
and reach the same canonical command document.

### Repository topology matrix

- staging plus production;
- production only;
- package publication without a runtime;
- no deployment;
- legacy v1.4.1 flat deploy configuration; and
- a generic GitHub workflow fixture representing a non-Coolify provider.

### Concurrency and recovery matrix

- 10 simultaneous release attempts on one environment;
- same-SHA duplicates from separate processes;
- intermediate GitHub pending-run cancellations;
- newer unapproved `main` commit while an approved deploy is active;
- divergent or rollback target;
- dispatch response lost after GitHub accepted it;
- controller restart in dispatch, polling, and verification states;
- workflow success with stale, missing, or malformed runtime evidence; and
- Claude-started work resumed by Codex and the inverse.

### Rollout

1. Ship parsing and routing behind backward-compatible behavior.
2. Dogfood implicit routing in the Otta plugin repository.
3. Exercise latest-wins behavior with non-mutating workflow fixtures.
4. Enable real staging delivery in a repository that has staging.
5. Perform one explicitly approved low-risk direct-production release.
6. Expand to additional repositories only after status and recovery evidence is
   consistent across Claude Code and Codex.

## Acceptance mapping

- **AC1:** Complete command table and routing precedence cover setup, start,
  dev, build, fix, ship, status, schedule, remember, and pulse-doctor.
- **AC2:** Architecture and cross-harness sections define one core, thin
  adapters, and GitHub-first resumption.
- **AC3:** Environment contract covers staging plus production, production only,
  no deployment, and flat v1.4.1 compatibility.
- **AC4:** Latest-wins section defines 5-10 request coalescing, descendant proof,
  included/superseded outcomes, and host-load boundaries.
- **AC5:** Provider boundary keeps execution in repository-owned GitHub
  workflows and permits staging or direct production.
- **AC6:** Enforcement, verification, failure, migration, rollout, and non-goal
  sections define a production-safe path without a central broker.
