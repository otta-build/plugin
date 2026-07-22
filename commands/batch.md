---
description: Run the Otta gated pipeline across many issues concurrently (one PR each).
argument-hint: <issue> <issue> ... (e.g. 101 102 103)
---

# /otta:batch — parallel multi-issue delivery

Run the full Otta pipeline (build → spec-review → verify → ship) for **each** issue
in `$ARGUMENTS` **concurrently**. Each issue runs in its own isolated worktree and
opens its own PR. Otta gates every lane identically; failures are isolated (one bad
lane never aborts the batch).

Parse `$ARGUMENTS` into a whitespace-separated list of issue numbers. If empty, tell
the user the usage `/otta:batch 101 102 103` and stop. The unit of work is **one lane per issue**:
every lane is exactly the `builder → reviewer → qa → devops` pipeline run for that single issue.

## Orchestration compatibility

### Claude Code adapter

When the `Workflow` tool is available, invoke it with the bundled batch script (this
is an explicit, user-invoked opt-in to orchestration):

```
Workflow({
  scriptPath: "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/workflows/otta-batch.mjs",
  args: { issues: [<the parsed issue numbers as strings>], pluginRoot: "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}" }
})
```

`otta-batch.mjs` fans out one `otta-build` lane per issue via the runtime's native
`parallel()`, gates each lane identically, and returns `{ issues: [...], summary }`.
Concurrency self-throttles at the Workflow cap `min(16, cores−2)`.

### Codex adapter

When `Workflow` is unavailable (including Codex), do not call it. Fan out **one lane
per issue** using the harness's native subagent primitives, run in parallel:

Before each dispatch, include the resolved absolute plugin root in every subagent prompt.
Tell the lane to retain that path as execution state and inline-inject `OTTA_PLUGIN_ROOT`
for every plugin command it invokes; do not rely on environment inheritance between the
parent and subagent.

1. For **each** issue, use `spawn_agent` to start one lane. Instruct that lane to run
   the complete `builder → reviewer → qa → devops` chain for its single issue exactly
   as the [canonical build workflow](./build.md) Codex adapter describes — seed
   `.pr-body.md`, implement test-first, spec-review with the bounded three-attempt
   repair loop, run the Otta gate + adversarial QA, and open the PR only when the gate
   and every AC pass. Each lane works in its own isolated worktree
   (`scripts/otta-worktree.sh <issue>`), so lanes never collide.
2. Dispatch all lanes before waiting, so they run concurrently. Then `wait_agent` on
   each lane and collect its verdict. A lane that fails is recorded as `blocked` with
   its reason; it never aborts the other lanes.
3. When every lane has returned, render the collected verdicts as a table:
   `| Issue | Status | PR / reason |` — one row per issue.

On a harness with differently named primitives, use its equivalent parallel spawn and
wait operations while preserving one isolated lane per issue and uniform gating.

If neither Workflow nor collaboration/subagent primitives are available, run each
issue's `builder → reviewer → qa → devops` chain sequentially in the current agent —
one issue fully to a PR (or blocked verdict) before starting the next — preserving the
same stage gates, bounded repair loop, and role separation. Do not pretend lanes ran
in parallel; report the summary table the same way.

## Notes

- Worktrees live under `~/.otta/worktrees/` and are discoverable via
  `git worktree list`; the pipeline tears each down after its PR opens.
- If a lane dies before shipping, sweep leftover worktrees with the existing GC:
  `bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-worktree.sh" --prune`
  (age-based; pass `--prune 0` to remove all when no batch is in flight).
- Per-issue CI/CD time is not shortened by batching — parallelism overlaps the CI
  waits so they stop being additive. Per-issue speed (caching, runners, test
  splitting) is a separate concern.
