import { decideRepair, normalizeMaxRevisions } from './repair-policy.mjs'

export const meta = {
  name: 'otta-build',
  description: 'TDD shipping pipeline for one issue: build → spec-review → adversarial verify → ship. Uses the builder/reviewer/qa/devops subagents.',
  phases: [
    { title: 'Build' },
    { title: 'Spec Review' },
    { title: 'Verify' },
    { title: 'Ship' },
  ],
}

// args: { issue, pluginRoot }. pluginRoot lets the stages call the real otta
// engine scripts (seed / gate / capture) deterministically instead of prose.
const issue = (args && (args.issue ?? args)) || 'the current issue'
const root = (args && args.pluginRoot) || '${CLAUDE_PLUGIN_ROOT}'
const SEED = `bash "${root}/scripts/seed-pr-body.sh"`
const GATE = `bash "${root}/scripts/otta-gate.sh"`
const WT = `bash "${root}/scripts/otta-worktree.sh"`
const PREPARE_LEARNING = `bash "${root}/scripts/otta-learning-policy.sh" prepare`
// Each stage runs fresh in the session cwd, so it re-derives the SAME isolated
// worktree via the deterministic helper and cd's in before doing anything.
const ENTER = `Enter the run's isolated worktree first: cd "$(${WT} ${issue})". `
const MAX_REVISIONS = normalizeMaxRevisions(args && args.maxRevisions)

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    compliant: { type: 'boolean', description: 'true only if every AC is met and there is no extra scope' },
    gaps: { type: 'string', description: 'specific missing or extra behavior with file references; empty if compliant' },
  },
  required: ['compliant', 'gaps'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    gatePassed: { type: 'boolean' },
    allAcsPass: { type: 'boolean', description: 'true only if every AC has real evidence' },
    detail: { type: 'string', description: 'gate result + per-AC verdicts with evidence or failure reason' },
  },
  required: ['gatePassed', 'allAcsPass', 'detail'],
}
const EVIDENCE_SCHEMA = {
  type: 'object',
  properties: {
    emitted: { type: 'boolean', description: 'true only when the emit command exited zero and local ledger record was verified' },
    detail: { type: 'string' },
  },
  required: ['emitted', 'detail'],
}

// Note: unlike commands/dev.md's direct Task calls (plugin#75), the Workflow
// tool's agent() helper here has no documented `name` option — `label`/`phase`
// are the only namespacing it exposes, and it's unverified whether either
// reaches the harness's "Teammate @X finished" notification chrome. Not
// faking a `name:` field until that's confirmed; see plugin#88 for the gap.
// 1. BUILD — seed the body via the engine if needed, then implement test-first
phase('Build')
const built = await agent(
  `Implement issue #${issue} test-first.\n` +
    `FIRST establish an ISOLATED CLEAN base — the PR must contain only this change and must not touch the session's branch. ` +
    `Create/enter the run's worktree (a separate checkout off the base, on its own branch — name derived from .otta.yml's branch_pattern, default otta/${issue}):\n` +
    `  WT="$(${WT} ${issue})" && cd "$WT"\n` +
    `(pass a base arg to the helper if .otta.yml names a staging branch). Confirm "git log --oneline @{u}..HEAD" is empty. ` +
    `Do NOT build in the session's current checkout.\n` +
    `Resolve the shared per-run learning policy before writing code: ${PREPARE_LEARNING}. ` +
    `Read .otta/run/learning-receipt.json and, when consulted, include .otta/run/consulted-learnings.md as repo rule context. ` +
    `A skipped consultation is non-blocking and keeps its explicit reason.\n` +
    `THEN: if .pr-body.md does not exist, seed it from the issue's acceptance criteria by running:\n` +
    `  ${SEED} ${issue}\n` +
    `Then read .pr-body.md — each "- [ ] AC" is what you must satisfy. ` +
    `Write the smallest failing test, make it pass, keep changes surgical, and keep .pr-body.md's Verification honest. ` +
    `Return what you changed, the test added, and which ACs it satisfies.`,
  { agentType: 'otta:builder', label: `build:#${issue}`, phase: 'Build' },
)

// 2. SPEC REVIEW — bounded repairs; identical blockers twice stop early.
phase('Spec Review')
let review = await agent(
  ENTER +
  `Review the implementation for issue #${issue} against the acceptance block in .pr-body.md. ` +
    `For each AC cite the file:line that satisfies it. Flag missing or extra behavior.`,
  { agentType: 'otta:reviewer', label: 'spec-review', phase: 'Spec Review', schema: REVIEW_SCHEMA },
)
let revision = 0
let previousSignature = ''
while (review && !review.compliant) {
  const decision = decideRepair({ completedRepairs: revision, maxRevisions: MAX_REVISIONS, failure: review.gaps, previousSignature })
  const signature = decision.signature
  if (decision.action === 'stop') {
    log(decision.message)
    const evidence = await agent(ENTER + `Execute bash "${root}/scripts/otta-repair-loop.sh" emit --attempt ${Math.max(revision, 1)} --stage reviewer --failure ${JSON.stringify(signature)} --outcome stalled. Verify the command exits zero and the repair_attempt record exists in the local ledger; return emitted=false on either failure.`,
      { agentType: 'otta:builder', label: 'pulse:stalled', phase: 'Spec Review', schema: EVIDENCE_SCHEMA })
    if (!evidence || !evidence.emitted) return { issue, status: 'blocked', reason: 'evidence-emission-failed', detail: evidence && evidence.detail, spec: review }
    return { issue, status: 'blocked', reason: decision.reason, attempt: revision, failureSignature: signature, spec: review }
  }
  revision = decision.nextAttempt
  previousSignature = signature
  log(`spec review found gaps — repair attempt ${revision} of ${MAX_REVISIONS}: ${signature}`)
  await agent(
    ENTER +
    `Spec review found gaps for issue #${issue}:\n${review.gaps}\nFix exactly these. Keep changes surgical. ` +
    `Record compact Pulse evidence with: bash "${root}/scripts/otta-repair-loop.sh" decide --attempt ${revision} --stage reviewer --failure ${JSON.stringify(signature)} --state .otta/repair-${issue}.state (best-effort when Pulse is configured).`,
    { agentType: 'otta:builder', label: `build:fix-spec:${revision}`, phase: 'Build' },
  )
  review = await agent(
    ENTER +
    `Re-review issue #${issue} against .pr-body.md after the fix. Confirm COMPLIANT or list remaining gaps.`,
    { agentType: 'otta:reviewer', label: `spec-review:${revision + 1}`, phase: 'Spec Review', schema: REVIEW_SCHEMA },
  )
}

// 3. VERIFY — run the real Otta gate (auto-captures the verdict to the ledger),
//    then adversarial per-AC check
phase('Verify')
const verify = await agent(
  ENTER +
  `For issue #${issue}:\n` +
    `1. Run the Otta gate (it also runs the project gate + captures the verdict to the LEARN ledger):\n` +
    `   ${GATE}\n` +
    `2. Run the project's own tests (bash scripts/gate.sh if present, else typecheck + affected tests).\n` +
    `3. Adversarially verify EACH acceptance criterion in .pr-body.md — produce concrete evidence or mark it FAILED.\n` +
    `4. If the change touches UI/frontend files, headlessly launch the app (Playwright MCP — no local Chrome session, this runs unattended) ` +
    `and screenshot the golden path yourself to confirm it renders/works before marking any UI-related AC as passed. Typecheck and unit tests do not verify feature correctness. Skip for backend/CLI-only changes.\n` +
    `Return the gate result (gatePassed) and per-AC verdicts (allAcsPass + detail, including the UI screenshot evidence when applicable).`,
  { agentType: 'otta:qa', label: 'verify', phase: 'Verify', schema: VERIFY_SCHEMA },
)

// 4. SHIP — only when verify is fully green
phase('Ship')
if (verify && verify.gatePassed && verify.allAcsPass) {
  const shipped = await agent(
    ENTER +
    `Issue #${issue} passed verify. Ship it:\n` +
      `1. Run the Otta gate once more — do not push past a failing gate:\n   ${GATE}\n` +
      `2. Commit, then open the PR with: gh pr create --body-file .pr-body.md --title "<conventional title>"\n` +
      `   Target staging if .otta.yml names a staging branch, else main.\n` +
      `3. After the PR is open, tear down the worktree: ${WT} --remove ${issue}\n` +
      `Return the PR URL.`,
    { agentType: 'otta:devops', label: 'ship', phase: 'Ship' },
  )
  return { issue, status: 'shipped', spec: review, verify, ship: shipped }
}

log(`verify failed — not shipping #${issue}`)
return { issue, status: 'blocked', spec: review, verify }
