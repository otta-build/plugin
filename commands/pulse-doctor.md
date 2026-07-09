---
description: Diagnose the Otta Pulse GitHub App installation with App JWT auth
argument-hint: [owner/repo]
---

Verify that the Otta Pulse GitHub App can post advisory Check Runs for this repo.
This command uses GitHub App JWT auth, not the normal `gh` user token.

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/otta-pulse-doctor.sh" "$1"
```

If `$1` is empty, omit the argument so the script detects the repo with
`gh repo view`.

Required credentials:

```bash
export OTTA_PULSE_APP_ID=<app-id>
export OTTA_PULSE_PRIVATE_KEY_PATH=/path/to/github-app-private-key.pem
```

or:

```bash
export OTTA_PULSE_APP_ID=<app-id>
export OTTA_PULSE_PRIVATE_KEY='-----BEGIN PRIVATE KEY-----...'
```

Report the script output verbatim, but never print private key material or any
installation token. A healthy result ends with:

```text
OK: Otta Pulse can post GitHub Check Runs for owner/repo.
```
