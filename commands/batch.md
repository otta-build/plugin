---
description: Run the Otta gated pipeline across many issues concurrently (one PR each).
argument-hint: <issue> <issue> ... (e.g. 101 102 103)
---

# /otta:batch — parallel multi-issue delivery

Run the full Otta pipeline (build → spec-review → verify → ship) for **each** issue
in `$ARGUMENTS` **concurrently**. Each issue runs in its own isolated worktree and
opens its own PR. Otta gates every lane identically; failures are isolated (one bad
lane never aborts the batch).

## Steps

1. Parse `$ARGUMENTS` into a whitespace-separated list of issue numbers. If empty,
   tell the user the usage `/otta:batch 101 102 103` and stop.

2. Invoke the **Workflow** tool with (resolve the plugin root with the same
   fallback every other Otta command uses):
   - `scriptPath: "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/workflows/otta-batch.mjs"`
   - `args: { "issues": [<the parsed issue numbers as strings>], "pluginRoot": "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}" }`

   (The workflow normalizes/dedupes the list, fans out one `otta-build` lane per
   issue via native `parallel()`, and returns `{ issues: [...], summary }`.)

3. When it completes, render the returned `summary` as a table:
   `| Issue | Status | PR / reason |` — one row per issue.

## Notes

- Concurrency self-throttles at the Workflow cap `min(16, cores−2)`; pass as many
  issues as you like.
- Worktrees live under `~/.otta/worktrees/` and are discoverable via
  `git worktree list`; the pipeline tears each down after its PR opens.
- If a lane dies before shipping, sweep leftover worktrees with the existing GC:
  `bash "${OTTA_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}}/scripts/otta-worktree.sh" --prune` (age-based;
  pass `--prune 0` to remove all when no batch is in flight).
