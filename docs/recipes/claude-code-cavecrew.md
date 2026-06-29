# CaveCrew patterns for Otta + Claude Code

CaveCrew is a Claude Code plugin that provides specialized subagents for read-only research, surgical edits, and diff review. It is **Claude Code-only and entirely optional** — Otta has no dependency on it.

## Agents

| Agent | Best for | Hard limits |
|---|---|---|
| `cavecrew-investigator` | Symbol lookup, file/line mapping, mining long threads | Read-only. Returns `file:line` table only. |
| `cavecrew-builder` | 1-2 file edits, mechanical renames, format fixes | Refuses scope > 2 files. No new features. |
| `cavecrew-reviewer` | Pre-gate diff review, one-line severity findings | Read-only. No fixes, no suggestions outside diff. |

## Patterns inside the Otta loop

### Research before build

Spawn `cavecrew-investigator` before the builder to locate symbols or mine context without flooding main context:

```
Agent({ subagent_type: "cavecrew-investigator", prompt: "Where is X defined? List file:line." })
```

### Surgical edit in worktree

Use `cavecrew-builder` for the smallest possible edit inside an Otta worktree. It hard-refuses if scope creeps to 3+ files — that signals you need `/otta:dev` not `/otta:fix`.

### Pre-gate review

Run `cavecrew-reviewer` on the diff before the gate:

```
Agent({ subagent_type: "cavecrew-reviewer", prompt: "Review diff on branch X." })
```

Fix findings, then run the gate. The gate is still mandatory — reviewer output does not replace it.

## What CaveCrew does NOT replace

- **The Otta gate** — always runs, regardless of reviewer verdict.
- **The PR** — every change goes through a PR, no direct-to-main.
- **`idea_ref` traceability** — Pulse needs the issue linkage regardless of who made the edit.

## Teams not using Claude Code

Ignore this doc. Otta is executor-agnostic — the gate and GitHub App work identically with Copilot App, Codex, or any other agent.
