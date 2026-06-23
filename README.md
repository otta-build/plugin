# Otta — superpowers for shipping

A Claude Code / Codex plugin that makes any agent session follow the **Otta loop**:

```
issue → acceptance criteria → local gate → PR → ship → Otta Pulse (DORA + lifecycle)
```

It's the *discipline layer* of Otta. It needs no private engine and no secrets — just `gh` + `jq` and (optionally) the Otta Pulse GitHub App for metrics.

## Install

```
/plugin marketplace add wiselancer/otta
/plugin install otta
```

Then, once per repo:

```
/otta-setup
```

This installs a pre-push gate hook and walks you through installing the **Otta Pulse** GitHub App (interactive — GitHub requires your consent to install an App).

## Commands

| Command | Does |
|---|---|
| `/otta-start <issue>` | Seed `.pr-body.md` from a GitHub issue's acceptance criteria |
| `/otta-ship` | Run the local gate, then open the PR with the seeded body |
| `/otta-setup` | Install the pre-push gate hook + onboard the Pulse GitHub App |

## What the gate checks (local mirror of the Pulse merge gates)

- a ` ```acceptance ` fenced block in `.pr-body.md`
- a test in the diff, OR `[test-impractical: <reason>]`
- `Fixes #<issue>` — so the issue→PR link exists in GitHub
- `idea_ref:` — so Pulse can join idea → issue → PR → version

Failures surface **before** you push, not in CI. Bypass once with `OTTA_SKIP_GATE=1 git push`.

## How it connects to Otta Pulse

Pulse is the GitHub App that ingests your PR/CI/tag webhooks into an append-only event store and computes DORA metrics. This plugin doesn't talk to Pulse directly — it makes sure every PR body carries the `Fixes #N` + `idea_ref` linkage, which **Pulse already reads from the `pull_request` webhook**. No extra auth, no secret on your machine.

## Scope

This plugin is the discipline layer. The autonomous loop engine (scheduled `sense→score→govern→act→learn` runs) and direct lifecycle emission are separate components — see the Otta roadmap.
