#!/usr/bin/env bash
# Unit test for otta-batch.mjs pure helpers (normalizeIssues, summarizeBatch).
# Run: bash tests/otta-batch-helpers.test.sh
#
# otta-batch.mjs mirrors otta-build.mjs's shape: pure exports up top, then a
# driver section that references ambient globals (args/log/phase/parallel/
# workflow) injected by the Workflow runtime and ends in a top-level return.
# That driver section is not valid plain-ESM (undeclared globals, top-level
# return outside a function) — same reason otta-build.mjs itself fails
# `node --check` and is tested via grep, not import (see
# tests/build-repair-policy.test.sh). So we import only the side-effect-free
# prefix (meta + the two pure functions), sliced out of the REAL file, up to
# the driver section's first line — this exercises the actual shipped source,
# not a reimplementation.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../workflows/otta-batch.mjs"
fail() { echo "✗ $1" >&2; exit 1; }

node --input-type=module -e "
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const src = readFileSync('$SCRIPT', 'utf8')
const marker = 'const issues = normalizeIssues('
const idx = src.indexOf(marker)
if (idx === -1) { console.error('ASSERT driver marker not found in otta-batch.mjs'); process.exit(1) }
const pureSlice = src.slice(0, idx)
const dir = mkdtempSync(join(tmpdir(), 'otta-batch-pure-'))
const sliceFile = join(dir, 'pure.mjs')
writeFileSync(sliceFile, pureSlice)

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
