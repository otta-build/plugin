export const meta = {
  name: 'otta-batch',
  description: 'Run the otta-build pipeline across many issues concurrently, one PR each.',
  phases: [{ title: 'Batch' }],
}

// Pure: normalize a raw issue arg (array | scalar | undefined) -> deduped string list.
export function normalizeIssues(raw) {
  const list = Array.isArray(raw) ? raw : (raw == null ? [] : [raw])
  const seen = new Set()
  const out = []
  for (const x of list) {
    const s = String(x).trim().replace(/^#/, '')
    if (s && !seen.has(s)) { seen.add(s); out.push(s) }
  }
  return out
}

// Pure: map parallel() results (a null = failed/skipped lane) -> summary rows.
export function summarizeBatch(results, issues) {
  return issues.map((issue, i) => {
    const r = results[i]
    if (!r) return { issue: String(issue).replace(/^#/, ''), status: 'blocked', reason: 'lane-error-or-null' }
    const row = { issue: r.issue ?? String(issue).replace(/^#/, ''), status: r.status }
    if (r.ship) row.pr = r.ship
    if (r.reason) row.reason = r.reason
    return row
  })
}

const issues = normalizeIssues(args && (args.issues ?? args))
const root = (args && args.pluginRoot) || '${CLAUDE_PLUGIN_ROOT}'
const CHILD = `${root}/workflows/otta-build.mjs`

if (!issues.length) return { error: 'no issues provided — usage: /otta:batch 101 102 103', issues: [] }

log(`batch: dispatching ${issues.length} issue(s) — ${issues.join(', ')}`)
phase('Batch')

// Fan out: each lane is the UNCHANGED otta-build pipeline, invoked by scriptPath
// (workflows are not name-registered). One-level nest — otta-build uses agent()
// only, never workflow(). A thrown lane resolves to null (parallel() contract).
const results = await parallel(
  issues.map(issue => () => workflow({ scriptPath: CHILD }, { issue, pluginRoot: root })),
)

const rows = summarizeBatch(results, issues)
const summary = rows
  .map(r => `#${r.issue}: ${r.status}${r.pr ? ' ' + r.pr : ''}${r.reason ? ' (' + r.reason + ')' : ''}`)
  .join('\n')
log(`batch complete:\n${summary}`)
return { issues: rows, summary }
