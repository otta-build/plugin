---
name: otta-remember
description: Use when promoting a durable delivery learning into a repository knowledge ledger.
---

# Otta Remember

Before reading the canonical workflow, resolve the installed plugin root from this loaded `SKILL.md` resource path: take the absolute path two directories above this skill directory and retain that absolute path as `OTTA_PLUGIN_ROOT` in this skill execution state. Reject an empty resolved root. For every canonical shell command, verify its referenced Bash target is a readable regular file and inline-prefix `OTTA_PLUGIN_ROOT='<resolved absolute root>'` on that same invocation. For every structured tool call, verify each structured-tool target exists and is readable, then substitute the absolute root directly into every plugin path or root argument. Do not rely on exported environment persistence between tool calls. Never assume `PLUGIN_ROOT` exists outside hook execution.

In Codex context, invoke Otta skills as `$otta-<name>`; do not invoke Claude command syntax `/otta:<name>`.

Bind the first Codex invocation argument to canonical `$1` and the full argument string to `$ARGUMENTS`; preserve an absent optional first argument as empty.

Read and follow the [canonical remember workflow](../../commands/remember.md). Treat that command document as the source of truth; do not recreate its workflow here.
