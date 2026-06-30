#!/usr/bin/env bash
# otta-runner-setup.sh — generate self-hosted runner setup for a GitHub repo
#
# Usage: bash otta-runner-setup.sh <owner/repo>
#
# Outputs to stdout:
#   1. The gh api command to fetch a registration token (AC3)
#   2. The docker run command to start the runner (AC2)
#
# Writes docs/runner-setup.md with full instructions (AC2).
#
# Does NOT call gh api or require any credentials — all output is
# template/instructional only (the token fetch command is printed, not executed).
set -euo pipefail

REPO="${1:-}"

if [ -z "$REPO" ]; then
  echo "Usage: $0 <owner/repo>" >&2
  exit 1
fi

OWNER="${REPO%%/*}"
REPO_NAME="${REPO#*/}"

# Sanitize: replace / and any non-alphanumeric (except dash) with dash
SLUG="$(echo "${OWNER}-${REPO_NAME}" | tr '/' '-' | tr -cs 'a-zA-Z0-9-' '-' | sed 's/-*$//')"
CONTAINER_NAME="otta-runner-${SLUG}"

TOKEN_CMD="gh api repos/${REPO}/actions/runners/registration-token --method POST --jq .token"

DOCKER_CMD="docker run -d \\
  --name ${CONTAINER_NAME} \\
  -e REPO_URL=https://github.com/${REPO} \\
  -e RUNNER_TOKEN=\${TOKEN_FROM_GH_API} \\
  -e RUNNER_NAME=otta-runner \\
  -e LABELS=self-hosted,otta \\
  -e RUNNER_SCOPE=repo \\
  myoung34/github-runner:latest"

# ---------------------------------------------------------------------------
# stdout output (shown to the agent/user immediately)
# ---------------------------------------------------------------------------
cat <<EOF

## Self-hosted runner setup for ${REPO}

### Step 1: Get a registration token

Run this command to fetch a short-lived registration token (valid 1 hour):

  ${TOKEN_CMD}

Store the token in TOKEN_FROM_GH_API.

### Step 2: Start the runner container

  ${DOCKER_CMD}

Replace \${TOKEN_FROM_GH_API} with the token from Step 1.

### Note on scope
This registers a repo-level runner (RUNNER_SCOPE=repo).
For an org-level runner, change RUNNER_SCOPE=org and update REPO_URL to https://github.com/${OWNER}.

See docs/runner-setup.md for full instructions.
EOF

# ---------------------------------------------------------------------------
# Write docs/runner-setup.md
# ---------------------------------------------------------------------------
mkdir -p docs

cat > docs/runner-setup.md <<DOCEOF
# Self-hosted GitHub Actions Runner

## Why self-hosted?

GitHub's free tier for **private repos** includes only ~2,000 Actions minutes/month.
With Otta's gated pipeline (builder → reviewer → QA → DevOps), each PR can consume
4–6 CI runs, exhausting the quota in ~15 PRs. A self-hosted runner runs on your own
infrastructure with no minute limits.

## Registration token

Tokens are short-lived (~1 hour). Generate a fresh one before starting the container:

\`\`\`bash
${TOKEN_CMD}
\`\`\`

Store the output as \`TOKEN_FROM_GH_API\`.

## Start the runner

\`\`\`bash
${DOCKER_CMD}
\`\`\`

Replace \`\${TOKEN_FROM_GH_API}\` with the token above.

## Image

Uses [myoung34/github-runner](https://github.com/myoung34/docker-github-actions-runner)
— the community standard for containerised GitHub self-hosted runners.

## Scope: repo-level vs org-level

| Setting | RUNNER_SCOPE | REPO_URL |
|---------|-------------|----------|
| Repo-level (default) | \`repo\` | \`https://github.com/${REPO}\` |
| Org-level | \`org\` | \`https://github.com/${OWNER}\` |

Org-level requires a PAT with **Administration: Read & Write** on the organisation.

## Using self-hosted runners in CI

In your workflow file, set \`runs-on: self-hosted\` (or \`[self-hosted, otta]\`):

\`\`\`yaml
jobs:
  test:
    runs-on: [self-hosted, otta]
    steps:
      - uses: actions/checkout@v4
      - run: npm test
\`\`\`

## Token renewal (keep the runner alive)

Registration tokens expire after 1 hour. For a durable setup, use a **PAT** with
\`repo\` + \`workflow\` scopes set in the \`ACCESS_TOKEN\` env var instead:

\`\`\`bash
docker run -d \\
  --name ${CONTAINER_NAME} \\
  -e REPO_URL=https://github.com/${REPO} \\
  -e ACCESS_TOKEN=\${GITHUB_PAT} \\
  -e RUNNER_NAME=otta-runner \\
  -e LABELS=self-hosted,otta \\
  -e RUNNER_SCOPE=repo \\
  myoung34/github-runner:latest
\`\`\`

The image will auto-refresh the registration token on restart when \`ACCESS_TOKEN\` is set.
DOCEOF

echo ""
echo "docs/runner-setup.md written."
