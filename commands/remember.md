---
description: Promote a signal-gated learning (decision|gotcha|failed-approach) into the repo's LEARNINGS.md
argument-hint: <category> <learning text>
---

Promote a durable learning into this repo's `LEARNINGS.md`.

**Signal gate — only record if it clears the bar:**
- `decision` — an architectural or process choice with lasting impact
- `gotcha` — a non-obvious trap that burned time and will recur
- `failed-approach` — an approach that was tried and ruled out, with the reason

Skip transient notes, one-offs, or anything re-derivable from code or git history.

1. Pick the category that best fits: `decision`, `gotcha`, or `failed-approach`.
2. Distill the learning into a single concise sentence.
3. Run the bundled script:

   ```bash
   bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/scripts/otta-remember.sh" <category> "<learning text>"
   ```

The script appends a dated, deduplicated entry to `./LEARNINGS.md` (creating the file with a header if it does not exist).
