export function normalizeMaxRevisions(value) {
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : 3
}

export function normalizeFailure(detail) {
  return String(detail || '').toLowerCase().split(/[;|\n]+/)
    .map((part) => part.trim().replace(/\s+/g, ' ')).filter(Boolean)
    .sort().filter((part, index, all) => part !== all[index - 1]).join(', ')
}

export function decideRepair({ completedRepairs, maxRevisions, failure, previousSignature = '' }) {
  const max = normalizeMaxRevisions(maxRevisions)
  const signature = normalizeFailure(failure)
  if (completedRepairs > 0 && signature && signature === previousSignature) {
    return { action: 'stop', reason: 'repeated-blockers', completedRepairs, maxRevisions: max, signature,
      outcome: 'stalled', message: `Escalated after ${completedRepairs} of ${max} repair attempts: the same blockers repeated twice without meaningful progress: ${signature}.` }
  }
  if (completedRepairs >= max) {
    return { action: 'stop', reason: 'max-revisions', completedRepairs, maxRevisions: max, signature,
      outcome: 'stalled', message: `Stopped after completing ${completedRepairs} of ${max} repair attempts. Remaining blockers: ${signature}.` }
  }
  return { action: 'retry', nextAttempt: completedRepairs + 1, completedRepairs, maxRevisions: max, signature, outcome: 'retry' }
}
