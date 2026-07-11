import assert from 'node:assert/strict'
import { decideRepair, normalizeMaxRevisions } from '../workflows/repair-policy.mjs'

assert.equal(normalizeMaxRevisions(undefined), 3)
for (const invalid of [-1, 0, NaN, Infinity, 'wat', 1.5]) assert.equal(normalizeMaxRevisions(invalid), 3)
assert.equal(normalizeMaxRevisions('4'), 4)

let result = decideRepair({ completedRepairs: 0, maxRevisions: 3, failure: 'Missing test', previousSignature: '' })
assert.deepEqual(result, { action: 'retry', nextAttempt: 1, completedRepairs: 0, maxRevisions: 3, signature: 'missing test', outcome: 'retry' })
for (const completedRepairs of [1, 2]) {
  result = decideRepair({ completedRepairs, maxRevisions: 3, failure: `new blocker ${completedRepairs}`, previousSignature: 'different blocker' })
  assert.equal(result.action, 'retry', `repair ${completedRepairs + 1} must still be allowed`)
  assert.equal(result.nextAttempt, completedRepairs + 1)
}
result = decideRepair({ completedRepairs: 1, maxRevisions: 3, failure: ' AUTH guard ; missing test ', previousSignature: 'auth guard, missing test' })
assert.equal(result.action, 'stop'); assert.equal(result.reason, 'repeated-blockers')
assert.match(result.message, /after 1 of 3 repair attempts.*repeated twice.*auth guard, missing test/i); assert.equal(result.outcome, 'stalled')
result = decideRepair({ completedRepairs: 3, maxRevisions: 3, failure: 'New blocker', previousSignature: 'old blocker' })
assert.equal(result.action, 'stop'); assert.equal(result.reason, 'max-revisions')
assert.match(result.message, /Stopped after completing 3 of 3.*new blocker/i); assert.equal(result.outcome, 'stalled')
console.log('repair-policy: retry, repeated, max, and max validation pass')
