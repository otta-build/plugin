#!/usr/bin/env bash
# Install Otta's natural-language routing contract into repository context.
set -euo pipefail

repo_root="${1:-}"
harnesses="${2:-claude,codex}"
[ -n "$repo_root" ] || { echo "usage: $0 <repository-root> [claude,codex]" >&2; exit 2; }
[ -d "$repo_root" ] || { echo "repository root does not exist: $repo_root" >&2; exit 2; }

policy_block() {
  cat <<'EOF'
<!-- otta:intent-begin -->
## Otta intent routing

Natural language is the normal interface. Explicit Otta invocation always wins.
Read-only and status requests never authorize writes.

| Operation | Route when intent means |
| --- | --- |
| setup | first state-changing request without a valid Otta contract |
| start | begin a known issue and seed acceptance criteria |
| dev | standard issue-linked implementation |
| build | explicit autonomous builder-reviewer-QA-devops pipeline |
| fix | tiny issue-linked change |
| ship | release, staging, or production intent |
| status | released, blocked, continue, or resume intent |
| schedule | recurring autonomous work intent |
| remember | promote a verified delivery learning |
| pulse-doctor | diagnose missing Otta/Pulse checks |

Precedence: explicit Otta invocation; direct setup, status, schedule, or memory intent; issue-linked dev or fix; then release intent. Pause instead of guessing for an ambiguous production target, rollback, or unconfigured repository.
<!-- otta:intent-end -->
EOF
}

install_file() {
  file="$1"
  tmp="${file}.otta-intent.$$"
  if [ -f "$file" ]; then
    awk '
      $0 == "<!-- otta:intent-begin -->" { skipping=1; next }
      $0 == "<!-- otta:intent-end -->" { skipping=0; next }
      !skipping { print }
    ' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  while [ -s "$tmp" ] && [ -z "$(tail -n 1 "$tmp")" ]; do
    sed '$d' "$tmp" > "${tmp}.trim"
    mv "${tmp}.trim" "$tmp"
  done
  if [ -s "$tmp" ]; then printf '\n' >> "$tmp"; fi
  policy_block >> "$tmp"
  mv "$tmp" "$file"
}

case ",$harnesses," in
  *,claude,*) install_file "$repo_root/CLAUDE.md" ;;
esac
case ",$harnesses," in
  *,codex,*) install_file "$repo_root/AGENTS.md" ;;
esac

case ",$harnesses," in
  *,claude,*|*,codex,*) ;;
  *) echo "unknown harness list: $harnesses (expected claude,codex)" >&2; exit 2 ;;
esac
