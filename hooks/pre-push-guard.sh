#!/usr/bin/env bash
# pre-push-guard.sh — PreToolUse(Bash) hook. Reads the tool-call JSON on stdin;
# if the command is a `git push`, runs the Otta gate and blocks (exit 2) when it
# fails, so an agent can't push past the gate. Silent pass for everything else.
#
# The push may target a repo OTHER than the session repo (`git -C <path> push`,
# or `cd <path> && git push` in a compound command). We resolve the actual
# target repo of each push segment and gate THAT repo's .pr-body.md (only if
# it has one). When resolution is ambiguous (e.g. multiple pushes to
# different repos in one compound command) or a target can't be resolved, we
# fail closed and gate the session repo instead.
#
# Two different failure modes, two different defaults:
#   - RESOLUTION failures (which repo does a detected push target?) fail
#     CLOSED: ambiguous or unresolvable targets gate the session repo rather
#     than risk gating nothing. Being overly cautious here just means an
#     occasional unnecessary gate run.
#   - DETECTION failures (is this command a push at all?) currently fail
#     OPEN: if the segment parser doesn't recognize a command as containing
#     `git` and `push`, push_segments_seen stays 0 and the hook exits 0
#     silently. A push that slips past detection bypasses the gate entirely,
#     which is why the parser errs toward recognizing more shell forms as
#     pushes (subshells, trailing `&`/`|`/`)`, backslash line-continuations)
#     rather than fewer — a false positive here just re-runs the gate, but a
#     false negative ships ungated.
#
# Bypass: set OTTA_SKIP_GATE=1 in the environment.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

# Extract the command (jq if available, else grep fallback).
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
else
  cmd="$input"
fi

[ -n "${OTTA_SKIP_GATE:-}" ] && exit 0

SESSION_TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Collapse shell backslash-newline line continuations (`git \` + newline +
# `push`) into a single line BEFORE segment parsing below splits on
# newlines. Detection is the risky side here: we only ever fail CLOSED on
# ambiguity (see the header note above), so a missed continuation would mean
# a real push slips through ungated (fail OPEN) rather than a false block.
# Erring toward joining continuations, even speculatively, keeps detection
# conservative in the direction that matters.
# Strip stray CRs first (normalizes CRLF to LF) so a CRLF-style continuation
# (`git \` + CR + LF + `push`) collapses the same as a plain LF one — the
# backslash-newline sed below only matches `\` directly followed by LF.
cmd="$(printf '%s' "$cmd" | tr -d '\r' | sed -e :a -e '$!N;s/\\\n/ /;ta')"

# Conservative compound-command split on && , || , ; (not a full shell
# parser, but sufficient for the `cd X && git push` / chained forms we see).
segments="$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||;)/\n/g')"

push_segments_seen=0
targets=""
ambiguous=0
cwd="$PWD"

while IFS= read -r seg; do
  seg_trimmed="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [ -z "$seg_trimmed" ] && continue
  # Strip a leading subshell/group opener (`(`, `{`) and trailing `)`/`}` so
  # `(cd other && git push)` is parsed the same as `cd other && git push`.
  seg_trimmed="$(printf '%s' "$seg_trimmed" | sed -E 's/^[({][[:space:]]*//; s/[[:space:]]*[)}]$//')"
  [ -z "$seg_trimmed" ] && continue

  # Track `cd <dir>` state for subsequent segments in this compound command.
  if printf '%s' "$seg_trimmed" | grep -qE '^cd[[:space:]]+'; then
    dir="$(printf '%s' "$seg_trimmed" | sed -E 's/^cd[[:space:]]+//' | sed -E "s/^[\"']//; s/[\"']\$//")"
    case "$dir" in
      /*) cwd="$dir" ;;
      *) cwd="$cwd/$dir" ;;
    esac
    continue
  fi

  # Is this segment a `git ... push ...`? (word-boundary matches so a path
  # like `push-service` or flag like `--push-option` doesn't false-match, but
  # shell metacharacters right after `push` — `)`, `&`, `|`, `>` — still count,
  # e.g. `(git push)`, `git push&`, `git push|cat`.)
  printf '%s' "$seg_trimmed" | grep -qE '(^|[^a-zA-Z])git([^a-zA-Z-]|$)' || continue
  printf '%s' "$seg_trimmed" | grep -qE '(^|[^a-zA-Z-])push([^a-zA-Z-]|$)' || continue
  push_segments_seen=$((push_segments_seen + 1))

  # Resolve the target dir: apply any `-C <path>` flags cumulatively (each
  # non-absolute -C path is relative to the previous one, per git semantics),
  # else fall back to the tracked cwd (session cwd or preceding `cd`).
  seg_dir="$cwd"
  if printf '%s' "$seg_trimmed" | grep -qE -- '(^|[[:space:]])-C[[:space:]]+'; then
    c_args="$(printf '%s' "$seg_trimmed" | grep -oE -- '-C[[:space:]]+[^[:space:]]+')"
    while IFS= read -r carg; do
      [ -z "$carg" ] && continue
      val="$(printf '%s' "$carg" | sed -E 's/^-C[[:space:]]+//')"
      case "$val" in
        /*) seg_dir="$val" ;;
        *) seg_dir="$seg_dir/$val" ;;
      esac
    done <<EOF
$c_args
EOF
  fi

  seg_top="$(git -C "$seg_dir" rev-parse --show-toplevel 2>/dev/null)" || { ambiguous=1; continue; }
  if [ -z "$targets" ]; then
    targets="$seg_top"
  elif [ "$targets" != "$seg_top" ]; then
    ambiguous=1
  fi
done <<EOF
$segments
EOF

# Not a push command at all.
[ "$push_segments_seen" -eq 0 ] && exit 0

if [ "$ambiguous" -eq 0 ] && [ -n "$targets" ]; then
  # Every push segment resolved cleanly to the same repo — gate that repo.
  TOPLEVEL="$targets"
else
  # Fail closed: unresolved or ambiguous (multiple different targets) —
  # never fail open on the session repo.
  TOPLEVEL="$SESSION_TOPLEVEL"
fi

# Resolve the repo's default branch: origin/HEAD if set, else a conventional
# name as either a remote-tracking or local ref. Non-zero when undeterminable.
default_branch() {
  local top="$1" d c
  if d="$(git -C "$top" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s' "${d#origin/}"
    return 0
  fi
  for c in main master; do
    if git -C "$top" show-ref --verify --quiet "refs/remotes/origin/$c" \
      || git -C "$top" show-ref --verify --quiet "refs/heads/$c"; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# Is HEAD carrying commits the default branch doesn't have? That's our proxy
# for "this push is PR-bound", i.e. work that a PR body is supposed to describe.
ahead_of_default() {
  local top="$1" d base cur n
  d="$(default_branch "$top")" || return 1
  cur="$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
  # Pushing the default branch itself is not PR-bound work.
  [ "$cur" = "$d" ] && return 1
  if git -C "$top" show-ref --verify --quiet "refs/remotes/origin/$d"; then
    base="origin/$d"
  elif git -C "$top" show-ref --verify --quiet "refs/heads/$d"; then
    base="$d"
  else
    return 1
  fi
  n="$(git -C "$top" rev-list --count "$base..HEAD" 2>/dev/null)" || return 1
  [ "${n:-0}" -gt 0 ]
}

if [ ! -f "$TOPLEVEL/.pr-body.md" ]; then
  # `.pr-body.md` is gitignored, so "absent" is now the normal state of a fresh
  # checkout rather than the impossible state it was while the file was tracked.
  # Exiting 0 unconditionally here (as this hook used to) means a branch that
  # never seeded a body pushes with NO gate at all — a silent bypass, strictly
  # worse than the stale-body failures untracking removed.
  #
  # Only Otta-governed repos have a body to require. `.otta.yml` is the same
  # opt-in marker otta-deploy-readiness.sh uses; without it this global hook
  # would block ordinary feature-branch pushes in every unrelated repo.
  [ -f "$TOPLEVEL/.otta.yml" ] || exit 0
  ahead_of_default "$TOPLEVEL" || exit 0

  echo "otta gate blocked this push:" >&2
  echo "  ⛔ [otta-gate:pr-body] no .pr-body.md in $TOPLEVEL, but HEAD is ahead of the default branch." >&2
  echo "     Seed one:  bash scripts/seed-pr-body.sh <issue> --force" >&2
  echo "     Bypass:    OTTA_SKIP_GATE=1 (only for pushes that aren't PR work)" >&2
  exit 2
fi

echo "[otta-gate] re-running gate (pre-push check)" >&2
# Run the gate FROM the resolved target repo. Passing only the body path is not
# enough: the gate's sub-checks are cwd-relative, so a cross-repo push
# (`git -C B push` from a session in A) gated B's body while reading A's repo —
# `check-pr-body.sh` runs a bare `gh issue view`, which infers the repo from the
# cwd's remote, and `check-test-coverage.sh` takes no path at all and diffs
# whatever repo it lands in. That produced false blocks that no in-session
# escape hatch could clear: --no-verify does not apply to a PreToolUse hook, and
# an inline `OTTA_SKIP_GATE=1 git push` prefix never reaches this script's own
# environment.
if ! out="$(cd "$TOPLEVEL" && bash "$HERE/../scripts/otta-gate.sh" "$TOPLEVEL/.pr-body.md" 2>&1)"; then
  echo "otta gate blocked this push:" >&2
  echo "$out" >&2
  exit 2
fi
exit 0
