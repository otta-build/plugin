export const meta = {
  name: 'otta-build',
  description: 'TDD shipping pipeline for one issue: build → spec-review → adversarial verify → ship. Uses the otta-builder/reviewer/qa/devops subagents.',
  phases: [
    { title: 'Build' },
    { title: 'Spec Review' },
    { title: 'Verify' },
    { title: 'Ship' },
  ],
}

// args is the issue number (or { issue }). Seed .pr-body.md with /otta-start first.
const issue = (args && (args.issue ?? args)) || 'the current issue'

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

// 1. BUILD — implement test-first
phase('Build')
const built = await agent(
  `Implement issue #${issue} test-first. The acceptance criteria are in .pr-body.md (seeded by /otta-start). ` +
    `Write the smallest failing test, make it pass, keep changes surgical, and keep .pr-body.md's Verification honest. ` +
    `Return what you changed, the test added, and which ACs it satisfies.`,
  { agentType: 'otta-builder', label: `build:#${issue}`, phase: 'Build' },
)

// 2. SPEC REVIEW — compliance, with one fix loop
phase('Spec Review')
let review = await agent(
  `Review the implementation for issue #${issue} against the acceptance block in .pr-body.md. ` +
    `For each AC cite the file:line that satisfies it. Flag missing or extra behavior.`,
  { agentType: 'otta-reviewer', label: 'spec-review', phase: 'Spec Review', schema: REVIEW_SCHEMA },
)
if (review && !review.compliant) {
  log(`spec review found gaps — sending back to builder`)
  await agent(
    `Spec review found gaps for issue #${issue}:\n${review.gaps}\nFix exactly these. Keep changes surgical.`,
    { agentType: 'otta-builder', label: 'build:fix-spec', phase: 'Build' },
  )
  review = await agent(
    `Re-review issue #${issue} against .pr-body.md after the fix. Confirm COMPLIANT or list remaining gaps.`,
    { agentType: 'otta-reviewer', label: 'spec-review:2', phase: 'Spec Review', schema: REVIEW_SCHEMA },
  )
}

// 3. VERIFY — gate + adversarial per-AC check
phase('Verify')
const verify = await agent(
  `For issue #${issue}: run the project gate (bash scripts/gate.sh if present, else typecheck + affected tests). ` +
    `Then adversarially verify EACH acceptance criterion in .pr-body.md — produce concrete evidence or mark it FAILED. ` +
    `Return the gate result and per-AC verdicts.`,
  { agentType: 'otta-qa', label: 'verify', phase: 'Verify', schema: VERIFY_SCHEMA },
)

// 4. SHIP — only when verify is fully green
phase('Ship')
if (verify && verify.gatePassed && verify.allAcsPass) {
  const shipped = await agent(
    `Issue #${issue} passed verify. Run the Otta gate once more, then commit and open the PR with ` +
      `gh pr create --body-file .pr-body.md. Target staging if .selfloop.yml names one, else main. Return the PR URL.`,
    { agentType: 'otta-devops', label: 'ship', phase: 'Ship' },
  )
  return { issue, status: 'shipped', spec: review, verify, ship: shipped }
}

log(`verify failed — not shipping #${issue}`)
return { issue, status: 'blocked', spec: review, verify }
