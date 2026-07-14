# Otta progress protocol

Harness-native progress is a projection, not the source of truth. Durable Otta ledger, PR, check, and deployment evidence remains authoritative.

## Profiles

| Profile | Entry point | Visible stages |
| --- | --- | --- |
| Read-only | no delivery command or skill | no Otta delivery progress |
| Tiny fix | `/otta:fix` or `$otta-fix` | Build → Gate → PR |
| Interactive delivery | `/otta:dev` or `$otta-dev` | Seed → Learn → Build → Review → QA → Ship |
| Autonomous delivery | `/otta:build` or `$otta-build` | Seed → Learn → Build → Review → QA → Ship |

Append Deploy → Verify only when repository policy performs deployment. Command routing selects the profile; do not add a second model classifier.

## State and transitions

Each stage is `pending`, `in_progress`, `completed`, or `blocked`. Exactly one may be `in_progress`. Update native progress only for a meaningful transition: stage start, completion, blocker, recovery, profile escalation, or evidence-backed resumption change.

Do not emit routine narration, polling commentary, or prose that restates native task, Workflow, plan, agent, or tool output.

## Attention events

- Decision required — ask the smallest unblocking question.
- Failure or blocker — name the stage, concrete reason, and next action.
- Material risk change — name what changed and how execution changes.
- Completion — report evidence and remaining human action.

## Resumption

Reconstruct resumed state from the Otta status path. Never assume a resumed run starts at Seed or Build. Conflicting evidence blocks optimistic advancement. If durable lookup is unavailable, label the projection session-only.

## Fallback

Without native progress tooling, render the selected compact stages once in Markdown, then emit only attention events.
