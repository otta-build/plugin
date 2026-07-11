---
name: otta-dev
description: Reference for builders and reviewers using the Otta shipping loop — AC layer tags, gate rules, and evidence requirements.
---

# Otta Dev Reference

## AC Layer Tags

### Verification labels

Acceptance criteria may contain exactly one verification label:
`[test]`, `[review]`, or `[human]`. Put it before or after an existing layer
tag such as `[data-layer]`, `[ui-layer]`, or `[e2e]`; layer tags are independent
and do not affect verification classification. Unlabelled criteria remain compatible and
are explicitly classified as `[test]`. Use
`scripts/otta-repair-loop.sh classify '<criterion>'` when routing evidence.

- `[test]`: deterministic automated evidence.
- `[review]`: reviewer judgment with concrete references.
- `[human]`: explicit human approval; automation must stop rather than infer it.

Layer tags on acceptance criteria make the required evidence type explicit at the point the AC is written. The gate (`otta-gate.sh`) enforces evidence type at the point the AC is checked off.

### Layer key

| Tag | Meaning | Evidence required |
|-----|---------|-------------------|
| `[data-layer]` | Schema + mutations + unit tests. No UI required. | Unit test or command output. |
| `[ui-layer]`   | Working page/component visible in the app.       | Preview URL or screenshot. |
| `[e2e]`        | Full user flow: link → action → observable result. | e2e tool output, preview URL, or recorded flow. |

### Rules

- A `[ui-layer]` or `[e2e]` AC checked off with only unit test evidence (test file path, `npm run test`, jest/vitest output) is a **gate failure**: `AC tagged [ui-layer]/[e2e] requires preview URL or e2e evidence — unit test insufficient.`
- A `[data-layer]` AC checked off with unit test evidence always **passes** the layer check.
- If a PR closes only `[data-layer]` ACs while the issue still has unclosed `[ui-layer]`/`[e2e]` ACs, the gate emits a **warning** (not a failure): `Issue has unclosed [ui-layer]/[e2e] ACs — issue will remain open after merge.`

### Seeding

When you run `seed-pr-body.sh`, layer tags from the issue's AC checkboxes are preserved verbatim in `.pr-body.md`. If any layer-tagged ACs are present, the seeded body includes an inline layer key comment as a reminder.

### Usage in an issue

Write layer tags directly in the AC checkbox text:

```markdown
- [ ] AC1 `[data-layer]`: Given migrations run, when the schema is queried, then the new columns exist — bash tests/schema.test.sh
- [ ] AC2 `[ui-layer]`: Given the feature flag is on, when the user visits /dashboard, then the new widget is visible — https://staging.example.com/dashboard (screenshot)
- [ ] AC3 `[e2e]`: Given a new user signs up, when they complete onboarding, then they land on the success page — Playwright run output or loom
```
