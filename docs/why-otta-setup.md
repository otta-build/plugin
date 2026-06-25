# Why Otta: per-step pain → benefit

This table is the canonical value copy for `/otta:setup`. It is also used by the README and landing page.

## Proof by self-application

This very wizard shipped through the Otta loop you're installing — built → reviewed → **QA caught a real gap (#26 AC3, the Pulse step had no opt-out)** → fixed → gated → merged.

## The core problem

AI agents code fast but quality is inconsistent — defects ship, runs forget context, and "is this production-ready?" is a guess. Otta makes every Claude Code session a gated TDD pipeline (build → review → verify → ship). **Gates, not prompts, guarantee quality.** Pulse records every verdict so the factory learns. DORA and cost visibility come free.

## Per-step pain → benefit

| Step | Pain it solves | Benefit you get |
|------|---------------|-----------------|
| **base / staging branches** | Otta must know your branch flow to route PRs and deploys | PRs auto-target the right branch; staging-accumulate → promote works |
| **deploy.auto policy** | How far should the pipeline drive: stop at green PR / merge / merge+deploy? | You pick the safety level; `human-approve` ships nothing without you — never an accidental prod deploy |
| **ci.required** | You need one authoritative "is this production-ready?" signal | The gate aggregates YOUR CI checks; agents can't merge red — no green-but-broken |
| **Pulse App** | The loop has amnesia without a memory — runs don't learn from each other | DORA free (deploy frequency, lead time, change-failure rate) + escape detection (what shipped broken) + the LEARN data that improves agents over time |
| **sandbox.credentials** | The pipeline runs Bash commands near your secrets | Agents can't read `~/.aws`, `~/.ssh`, or token env vars — credential exfiltration blocked |
| **CI workflow (if none)** | No CI → the gate's CI check can never go green | A minimal test-runner makes the gate real — the loop closes |
| **Local gate hook** | Gate failures found only after pushing = slow feedback loop | The same gate runs pre-push; fewer red PRs, faster iteration |
| **Telemetry** | Can't improve what you can't see | $/PR, tokens used, per-tool and per-stage timing → spot the slow or expensive stage |

## The payoff

After setup, this repo has:
- **Gated quality** — nothing broken can merge
- **Memory** — Pulse learns from every gate verdict
- **Visibility** — DORA metrics + cost per PR, free
- **Safety** — sandboxed agents can't touch your credentials

Ad-hoc AI coding → a measured, self-improving factory.
