---
description: Gated fast path for tiny (≤2 files, no new public behavior) changes — surgical edit → minimal .pr-body → gate → PR
argument-hint: <issue-number>
---

Run the Otta **fast path** for issue **#$1** — a tiny, surgical change that skips the multi-agent review pipeline but NEVER skips the gate or lifecycle traceability.

## When to use which tier

| Change size | Command | Review | Gate |
|---|---|---|---|
| Tiny: ≤2 files, no new public behavior | `/otta:fix` | Light (you) | ✓ always |
| Standard: anything else | `/otta:dev` or `/otta:build` | Full pipeline | ✓ always |

**Tiny ≠ ungated.** The fast path (cavecrew-builder style) optimizes execution cost only — the gate and PR are mandatory in every tier. cavecrew-builder never skips the gate.

> **Branch-protection enforcement** (structural guarantee that direct-to-main is impossible) is owned by #75 / #65.

---

## Steps

1. **Make the surgical edit** directly — touch ≤2 files, change no public interfaces, add no new behavior. If you find the change is larger, switch to `/otta:dev` or `/otta:build`.

2. **Seed a minimal `.pr-body.md`** (or update if it already exists). It must contain:
   - `idea_ref:` pointing to the real origin (e.g. `issue:#$1`, `intercom:...`, `sentry:...`)
   - `Fixes #$1` GitHub linkage
   - Either a test (file + command), or `[test-impractical: <reason>]` with a real reason
   - A short summary of what changed

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/seed-pr-body.sh" $1
   ```

   Then edit the seeded file: set `idea_ref` to the real origin, confirm `Fixes #$1` is present, add your verification line.

3. **Run the gate** (mandatory — never skip):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-gate.sh"
   ```

   If it fails, fix what it reports and re-run. A direct-to-main commit is forbidden — the gate and PR are what make the change traceable and safe.

4. **Open the PR** using the seeded body verbatim:

   ```bash
   gh pr create --body-file .pr-body.md --title "<conventional-commit title>"
   ```

   Use `--base staging` if `.otta.yml` names a staging branch; otherwise `--base main`.

---

## Invariants — never break these

- **Never commit directly to main.** Always a PR, always through the gate.
- **Never ungated.** The gate runs on every change, tiny or not.
- **Always traceable.** `idea_ref` + `Fixes #N` in the body let Pulse join the idea → issue → PR → version chain automatically.

The fast path saves pipeline cost (no builder/reviewer/qa subagents). It does not save gate cost, PR cost, or traceability cost — those are non-negotiable in every tier.
