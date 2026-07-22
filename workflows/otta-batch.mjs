export const meta = {
  name: 'otta-batch',
  description: 'Run the otta-build pipeline across many issues concurrently, one PR each.',
  phases: [{ title: 'Batch' }],
}

// NOTE: a Workflow script wraps everything after `export const meta` in a
// function where static `import`/`export` are illegal, and `meta` must be the
// first statement. So the pure helpers below are plain (non-export) function
// declarations, not a separate module. They are unit-tested by slicing them out
// of this file (see tests/otta-batch-helpers.test.sh).

// Normalize a raw issue arg (array | scalar | undefined) -> deduped string list.
function normalizeIssues(raw) {
  const list = Array.isArray(raw) ? raw : (raw == null ? [] : [raw])
  const seen = new Set()
  const out = []
  for (const x of list) {
    const s = String(x).trim().replace(/^#/, '')
    if (s && !seen.has(s)) { seen.add(s); out.push(s) }
  }
  return out
}

// Map parallel() results (a null = failed/skipped lane) -> summary rows.
function summarizeBatch(results, issues) {
  return issues.map((issue, i) => {
    const r = results[i]
    if (!r) return { issue: String(issue).replace(/^#/, ''), status: 'blocked', reason: 'lane-error-or-null' }
    const row = { issue: r.issue ?? String(issue).replace(/^#/, ''), status: r.status }
    if (r.ship) row.pr = r.ship
    if (r.reason) row.reason = r.reason
    return row
  })
}

// args may arrive as a real object OR as a JSON string (harness serialization
// varies). Normalize to an object before reading fields.
let a = args
if (typeof a === 'string') {
  try { a = JSON.parse(a) } catch { a = { issues: a } }
}

const issues = normalizeIssues(a && (a.issues ?? a))
const root = (a && a.pluginRoot) || '${CLAUDE_PLUGIN_ROOT}'
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
