#!/usr/bin/env bash
# Unit test for otta-batch.mjs pure helpers (normalizeIssues, summarizeBatch).
# Run: bash tests/otta-batch-helpers.test.sh
#
# otta-batch.mjs is a Workflow script: `export const meta` must be its first
# statement, and everything after is wrapped in a function where static
# import/export are illegal — so the helpers are plain (non-export) function
# declarations, not a separate module. To unit-test the REAL source, slice the
# side-effect-free prefix (meta + the two functions, up to the driver line) and
# append an export so it can be imported.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../workflows/otta-batch.mjs"
fail() { echo "✗ $1" >&2; exit 1; }

# Guard the runtime contract that this file caught the hard way: the script must
# NOT import a helper module (breaks the top-level Workflow loader) and meta must
# be the first line.
head -1 "$SCRIPT" | grep -q '^export const meta' || fail "meta must be the first statement"
grep -q "^import " "$SCRIPT" && fail "otta-batch.mjs must not use static import (Workflow loader rejects it)"

node --input-type=module -e "
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const src = readFileSync('$SCRIPT', 'utf8')
// Slice the side-effect-free prefix (meta + the two plain functions), stopping
// before the driver, which references the ambient 'args' global.
const marker = '// args may arrive as a real object'
const idx = src.indexOf(marker)
if (idx === -1) { console.error('ASSERT driver marker not found in otta-batch.mjs'); process.exit(1) }
// prefix = meta + comments + the two plain function declarations
const prefix = src.slice(0, idx)
const dir = mkdtempSync(join(tmpdir(), 'otta-batch-pure-'))
const sliceFile = join(dir, 'pure.mjs')
writeFileSync(sliceFile, prefix + '\nexport { normalizeIssues, summarizeBatch }\n')

const { normalizeIssues, summarizeBatch } = await import('file://' + sliceFile)
const assert = (c, m) => { if (!c) { console.error('ASSERT ' + m); process.exit(1) } }

// normalizeIssues: trims, strips leading #, dedups, drops empties, stringifies
let n = normalizeIssues(['101', '#102', '102', '  ', '103'])
assert(JSON.stringify(n) === JSON.stringify(['101','102','103']), 'normalize dedup/strip: ' + JSON.stringify(n))
assert(JSON.stringify(normalizeIssues(undefined)) === '[]', 'normalize undefined -> []')
assert(JSON.stringify(normalizeIssues('55')) === JSON.stringify(['55']), 'normalize scalar -> [scalar]')

// summarizeBatch: one row per issue, null lane -> blocked, shipped carries pr
const results = [
  { issue: '1', status: 'shipped', ship: 'https://pr/1' },
  null,
  { issue: '3', status: 'blocked', reason: 'verify-failed' },
]
const rows = summarizeBatch(results, ['1','2','3'])
assert(rows.length === 3, 'three rows')
assert(rows[0].status === 'shipped' && rows[0].pr === 'https://pr/1', 'row0 shipped+pr')
assert(rows[1].status === 'blocked' && rows[1].reason === 'lane-error-or-null', 'row1 null->blocked')
assert(rows[2].status === 'blocked' && rows[2].reason === 'verify-failed', 'row2 reason passthrough')
console.log('ok')
" | grep -q '^ok$' || fail "helper assertions failed"

echo "✓ otta-batch helpers: normalizeIssues + summarizeBatch pass"
