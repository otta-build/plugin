# Codex Plugin Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one Otta plugin package whose Claude Code and Codex entry points, hooks, telemetry configuration, and evidence records have equivalent behavior.

**Architecture:** Keep Claude commands as the canonical workflow documents and add thin Codex skill entry points that route to them. Use Codex's documented `PLUGIN_ROOT` with a `CLAUDE_PLUGIN_ROOT` compatibility fallback for executable paths, and extend the append-only ledger envelope with optional attribution fields. Configure Codex using its documented `[otel]` selector keys plus OTLP sub-tables; keep token-bearing configuration local and ignored.

**Tech Stack:** Bash, Markdown skills, JSON manifests, TOML configuration, jq, shell regression tests.

---

### Task 1: Dual-runtime hooks and native Codex package

**Files:**
- Create: `.codex-plugin/plugin.json`
- Modify: `hooks/hooks.json`
- Create: `tests/codex-plugin-parity.test.sh`

- [x] **Step 1: Write the failing package test**

Add assertions that `.codex-plugin/plugin.json` exists, declares `skills` and `hooks`, and that both hook commands use `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}`.

- [x] **Step 2: Run the test to verify RED**

Run: `bash tests/codex-plugin-parity.test.sh`
Expected: FAIL because `.codex-plugin/plugin.json` is missing and the hook commands only use `CLAUDE_PLUGIN_ROOT`.

- [x] **Step 3: Add the manifest and portable hook root**

Create a Codex manifest with package metadata, `"skills": "./skills/"`, `"hooks": "./hooks/hooks.json"`, and rich `interface` metadata. Change each hook command to:

```json
"command": "bash \"${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/pre-push-guard.sh\""
```

- [x] **Step 4: Run the focused test to verify GREEN**

Run: `bash tests/codex-plugin-parity.test.sh`
Expected: PASS for manifest and dual-runtime hook assertions.

### Task 2: Codex workflow entry-point parity

**Files:**
- Create: `skills/otta-setup/SKILL.md`
- Create: `skills/otta-start/SKILL.md`
- Create: `skills/otta-dev/SKILL.md`
- Create: `skills/otta-build/SKILL.md`
- Create: `skills/otta-fix/SKILL.md`
- Create: `skills/otta-ship/SKILL.md`
- Create: `skills/otta-status/SKILL.md`
- Create: `skills/otta-schedule/SKILL.md`
- Create: `skills/otta-remember/SKILL.md`
- Create: `skills/otta-pulse-doctor/SKILL.md`
- Modify: `commands/*.md`
- Modify: `tests/codex-plugin-parity.test.sh`

- [x] **Step 1: Extend the test to require every entry point**

Assert that each `commands/<name>.md` has a matching `skills/otta-<name>/SKILL.md`, valid frontmatter, and a reference to the canonical command document.

- [x] **Step 2: Run the test to verify RED**

Run: `bash tests/codex-plugin-parity.test.sh`
Expected: FAIL listing the missing Codex workflow skills.

- [x] **Step 3: Add thin Codex skills and portable command paths**

Each skill identifies the Otta workflow and instructs Codex to read and follow `../../commands/<name>.md`. Replace executable command examples that assume only `CLAUDE_PLUGIN_ROOT` with the dual-runtime expression.

- [x] **Step 4: Run the focused test to verify GREEN**

Run: `bash tests/codex-plugin-parity.test.sh`
Expected: PASS with all ten entry points discoverable.

### Task 3: Attributed ledger envelope

**Files:**
- Modify: `scripts/ledger-append.sh`
- Modify: `tests/ledger-append.test.sh`
- Modify: `tests/ledger-stream.test.sh`

- [x] **Step 1: Write failing attribution tests**

Invoke `ledger-append.sh` with `--executor codex --harness codex --session-id thread-1 --issue 131 --pr 132 --branch feat/issue-131` and assert the JSON record contains those exact top-level fields. Add a backward-compatibility assertion for an old caller with no new flags.

- [x] **Step 2: Run the tests to verify RED**

Run: `bash tests/ledger-append.test.sh && bash tests/ledger-stream.test.sh`
Expected: FAIL with `unknown arg: --executor`.

- [x] **Step 3: Implement optional flags and runtime defaults**

Parse the six optional flags, default executor/harness from `OTTA_EXECUTOR`/`OTTA_HARNESS`, default Codex session identity from `CODEX_THREAD_ID`, and default the branch from Git. Emit JSON null for unavailable optional fields so the schema is stable.

- [x] **Step 4: Run focused tests to verify GREEN**

Run: `bash tests/ledger-append.test.sh && bash tests/ledger-stream.test.sh`
Expected: PASS with attributed and legacy records.

### Task 4: Correct Claude and Codex OTEL configuration

**Files:**
- Modify: `scripts/otta-codex-setup.sh`
- Modify: `scripts/otta-telemetry-setup.sh`
- Modify: `tests/otta-codex-setup.test.sh`
- Modify: `tests/otta-telemetry-setup.test.sh`
- Modify: `README.md`

- [x] **Step 1: Write failing exporter-selector tests**

Assert Codex config contains `exporter = "otlp-http"` and `metrics_exporter = "otlp-http"` inside `[otel]`; assert Claude resource attributes include `repo=acme/widget,harness=claude_code`.

- [x] **Step 2: Run the tests to verify RED**

Run: `bash tests/otta-codex-setup.test.sh && bash tests/otta-telemetry-setup.test.sh`
Expected: FAIL because Codex selector keys and Claude harness attribution are absent.

- [x] **Step 3: Write the supported configuration**

Merge the selector keys without clobbering unrelated user configuration, keep `log_user_prompt = false`, and retain secret-bearing headers only in mode-0600 ignored files. Update README installation and invocation examples for both runtimes.

- [x] **Step 4: Run plugin verification**

Run: `for t in tests/*.test.sh; do bash "$t"; done`
Expected: every shell test exits 0.
