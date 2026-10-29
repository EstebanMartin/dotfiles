import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderElement } from 'claude-code'

import type { Change, Reply, ReviewComment, RowRef, Selection } from '../types'

// ─── State ──────────────────────────────────────────────────────────────────

const PANE = 'review'
const changes = atom({ plugin: 'review-pane', key: 'changes' } as const, [])
const comments = atom({ plugin: 'review-pane', key: 'comments' } as const, [])
const baselines = atom({ plugin: 'review-pane', key: 'baselines' } as const, {})
const selected = atom({ plugin: 'review-pane', key: 'selected' } as const, null)
const edit = atom({ plugin: 'review-pane', key: 'edit' } as const, null)
const cursor = atom({ plugin: 'review-pane', key: 'cursor' } as const, null)
const visual = atom({ plugin: 'review-pane', key: 'visual' } as const, null)
const selection = atom({ plugin: 'review-pane', key: 'selection' } as const, null)
const showKeys = atom({ plugin: 'review-pane', key: 'showKeys' } as const, false)
const replyTo = atom({ plugin: 'review-pane', key: 'replyTo' } as const, null)
const finder = atom({ plugin: 'review-pane', key: 'finder' } as const, null)

/** Matches the finder lists */
const FINDER_SHOWN = 12

/**
 * How well a query matches a path, fuzzily: its letters in order, scored higher for runs of
 * consecutive letters, for letters starting a word (after / . _ -) and for hits in the file name.
 * Null when the letters are not all there in order.
 */
function fuzzyScore(query: string, path: string): number | null {
  const q = query.toLowerCase().replace(/\s+/g, '')
  const p = path.toLowerCase()
  if (!q) return 0
  const nameAt = p.lastIndexOf('/') + 1
  let score = 0
  let at = -1
  for (const ch of q) {
    const found = p.indexOf(ch, at + 1)
    if (found < 0) return null
    score += 1
    if (found === at + 1) score += 5
    if (found === 0 || '/._-'.includes(p[found - 1]!)) score += 8
    if (found >= nameAt) score += 3
    at = found
  }
  return score - p.length / 100
}
const viewed = atom({ plugin: 'review-pane', key: 'viewed' } as const, {})
const fullDiff = atom({ plugin: 'review-pane', key: 'fullDiff' } as const, false)

/** Diff rows drawn per change before the rest is cut (t draws them all): each row is a highlighted button */
const MAX_ROWS = 300

/** Up to this many changed files the list is always open; past it, it folds to the open file's line until f */
const FILES_SHOWN = 6

/** The deepest folder holding every file, so the list shows paths from there */
function commonDir(files: readonly string[]): string {
  const parts = files.map(f => f.split('/').slice(0, -1))
  const first = parts[0] ?? []
  let n = 0
  while (n < first.length && parts.every(p => p[n] === first[n])) n++
  return first.slice(0, n).join('/')
}

let counter = 0
const newId = (now: number) => `${now.toString(36)}-${(counter += 1)}`

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`

// ─── Diffs ──────────────────────────────────────────────────────────────────

type Hunk = { oldStart: number; oldLines: number; newStart: number; newLines: number; lines: string[] }

/** One row of a change's diff: a hunk header or a line with its numbers */
type Row = { kind: 'hunk' | 'add' | 'del' | 'ctx'; text: string; hunk: number; oldN?: number; newN?: number }
type Op = { kind: ' ' | '-' | '+'; text: string }

const MARK = { add: '+', del: '-', ctx: ' ', hunk: '' } as const

const isCreate = (diff: string) => diff.startsWith('@@ -0,0')
const splitLines = (text: string) => (text === '' ? [] : text.replace(/\n$/, '').split('\n'))

function toDiff(hunks: readonly Hunk[], created?: string): string {
  if (hunks.length === 0 && created !== undefined) {
    const lines = splitLines(created)
    return `@@ -0,0 +1,${lines.length} @@\n${lines.map(l => `+${l}`).join('\n')}`
  }
  return hunks.map(h => `@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@\n${h.lines.join('\n')}`).join('\n')
}

function toRows(diff: string): Row[] {
  const rows: Row[] = []
  let oldN = 0
  let newN = 0
  let hunk = -1
  for (const line of diff.split('\n')) {
    const header = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
    if (header) {
      hunk += 1
      oldN = Math.max(1, Number(header[1]))
      newN = Math.max(1, Number(header[2]))
      rows.push({ kind: 'hunk', text: line, hunk })
    } else if (line.startsWith('+')) rows.push({ kind: 'add', text: line.slice(1), hunk, newN: newN++ })
    else if (line.startsWith('-')) rows.push({ kind: 'del', text: line.slice(1), hunk, oldN: oldN++ })
    else if (!line.startsWith('\\')) rows.push({ kind: 'ctx', text: line.slice(1), hunk, oldN: oldN++, newN: newN++ })
  }
  return rows
}

function tally(diffs: readonly string[]) {
  const rows = diffs.flatMap(toRows)
  return { add: rows.filter(r => r.kind === 'add').length, del: rows.filter(r => r.kind === 'del').length }
}

/** Line diff (Myers): each line of `a` and `b` as kept, removed or added, in order; null past a size worth diffing here */
function diffLines(a: readonly string[], b: readonly string[]): Op[] | null {
  const n = a.length
  const m = b.length
  const max = n + m
  if (max > 20000) return null
  const off = max + 1
  const v = new Int32Array(2 * max + 3)
  const trace: Int32Array[] = []
  const prev = (t: Int32Array, k: number, d: number) => k === -d || (k !== d && t[off + k - 1]! < t[off + k + 1]!)
  search: for (let d = 0; d <= max; d++) {
    trace.push(v.slice())
    for (let k = -d; k <= d; k += 2) {
      let x = prev(v, k, d) ? v[off + k + 1]! : v[off + k - 1]! + 1
      let y = x - k
      while (x < n && y < m && a[x] === b[y]) {
        x++
        y++
      }
      v[off + k] = x
      if (x >= n && y >= m) break search
    }
  }
  const ops: Op[] = []
  let x = n
  let y = m
  for (let d = trace.length - 1; d >= 0; d--) {
    const t = trace[d]!
    const k = x - y
    const prevK = prev(t, k, d) ? k + 1 : k - 1
    const prevX = t[off + prevK]!
    while (x > prevX && y > prevX - prevK) {
      ops.push({ kind: ' ', text: a[--x]! })
      y--
    }
    if (d > 0) ops.push(x === prevX ? { kind: '+', text: b[--y]! } : { kind: '-', text: a[--x]! })
  }
  return ops.reverse()
}

/** A unified diff from `before` to `after` with three lines of context, '' when they match; null when too large */
function netDiff(before: string, after: string): string | null {
  const ops = diffLines(splitLines(before), splitLines(after))
  if (!ops) return null
  const ranges: [number, number][] = []
  ops.forEach((op, i) => {
    if (op.kind === ' ') return
    const last = ranges[ranges.length - 1]
    if (last && i - 3 <= last[1] + 1) last[1] = Math.min(ops.length - 1, i + 3)
    else ranges.push([Math.max(0, i - 3), Math.min(ops.length - 1, i + 3)])
  })
  let oldN = 0
  let newN = 0
  let at = 0
  const count = (op: Op) => {
    if (op.kind !== '+') oldN++
    if (op.kind !== '-') newN++
  }
  const out: string[] = []
  for (const [from, to] of ranges) {
    while (at < from) count(ops[at++]!)
    const span = ops.slice(from, to + 1)
    const oldLines = span.filter(op => op.kind !== '+').length
    const newLines = span.filter(op => op.kind !== '-').length
    out.push(`@@ -${oldLines ? oldN + 1 : oldN},${oldLines} +${newLines ? newN + 1 : newN},${newLines} @@`)
    for (const op of span) {
      out.push(`${op.kind}${op.text}`)
      count(op)
    }
    at = to + 1
  }
  return out.join('\n')
}

/** Where `block` sits in `lines`, the match nearest `near`; -1 when it is nowhere */
function findBlock(lines: readonly string[], block: readonly string[], near: number): number {
  if (block.length === 0) return Math.min(near, lines.length)
  let best = -1
  for (let i = 0; i + block.length <= lines.length; i++) {
    const isMatch = block.every((line, j) => lines[i + j] === line)
    if (isMatch && (best < 0 || Math.abs(i - near) < Math.abs(best - near))) best = i
  }
  return best
}

/**
 * Rebuilds how a file looked before the recorded edits by undoing them on its text, newest first.
 * Only each run of changed lines is matched, by content and nearest its line number, so lines
 * added later around or between them leave it working; undefined when a run is no longer there.
 */
function undoEdits(now: string, edits: readonly Change[]): string | undefined {
  let lines = splitLines(now)
  for (const change of [...edits].reverse()) {
    // Runs of removed and added lines, with where they sat in the new text and the line kept just before them
    const runs: { at: number; olds: string[]; news: string[]; before?: string }[] = []
    let newN = 1
    let lastKept: string | undefined
    let run: (typeof runs)[number] | undefined
    for (const row of toRows(change.diff)) {
      if (row.kind === 'hunk' || row.kind === 'ctx') {
        run = undefined
        lastKept = row.kind === 'ctx' ? row.text : undefined
        newN = row.kind === 'ctx' ? newN + 1 : Math.max(1, Number(row.text.match(/\+(\d+)/)?.[1] ?? 1))
        continue
      }
      if (!run) runs.push((run = { at: newN - 1, olds: [], news: [], before: lastKept }))
      if (row.kind === 'del') run.olds.push(row.text)
      else {
        run.news.push(row.text)
        newN++
      }
    }
    for (const r of runs.reverse()) {
      const kept = r.news.length > 0 || r.before === undefined ? -1 : findBlock(lines, [r.before], r.at - 1)
      const at =
        r.news.length > 0 ? findBlock(lines, r.news, r.at) : r.before === undefined ? Math.min(r.at, lines.length) : kept < 0 ? -1 : kept + 1
      if (at < 0) return undefined
      lines = [...lines.slice(0, at), ...r.olds, ...lines.slice(at + r.news.length)]
    }
  }
  return lines.length > 0 ? `${lines.join('\n')}\n` : ''
}

// ─── Changes a shell command made ───────────────────────────────────────────

/** Past this many changed files in the repo, only files the pane already tracks are compared around a Bash call */
const MAX_DIRTY = 300
/** Files larger than this are not compared */
const MAX_BYTES = 1_000_000

/** Files as they were just before a Bash call (null: not there), and the git root they were listed from */
type Snapshot = { root: string | null; before: Record<string, string | null> }

async function gitOut($: EngineInterface, argv: string[]) {
  try {
    const out = await $.process.run(argv, { timeoutMs: 5000 })
    return out.exitCode === 0 ? out.stdout : null
  } catch {
    return null
  }
}

async function readOrNull($: EngineInterface, file: string): Promise<string | null> {
  try {
    return await $.fs.read(file)
  } catch {
    return null
  }
}

/** Absolute paths git lists as changed or untracked in `root` (`status -z`: a rename's old path follows it) */
async function dirtyFiles($: EngineInterface, root: string): Promise<string[]> {
  const out = await gitOut($, ['git', '-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all'])
  if (!out) return []
  const files: string[] = []
  const parts = out.split('\0')
  for (let i = 0; i < parts.length; i++) {
    const entry = parts[i]!
    if (entry.length < 4) continue
    files.push(`${root}/${entry.slice(3)}`)
    if (entry[0] === 'R' || entry[0] === 'C') i++
  }
  return files
}

/** The files a Bash call may change, read before it runs: the ones the pane tracks, and git's changed ones */
async function snapshot($: EngineInterface): Promise<Snapshot> {
  const root = (await gitOut($, ['git', '-C', await $.session.cwd(), 'rev-parse', '--show-toplevel']))?.trim() || null
  const dirty = root ? await dirtyFiles($, root) : []
  const tracked = (await read($, changes)).map(c => c.file)
  const files = new Set([...tracked, ...(dirty.length <= MAX_DIRTY ? dirty : [])])
  const before: Record<string, string | null> = {}
  for (const file of files) before[file] = await readOrNull($, file)
  return { root: dirty.length <= MAX_DIRTY ? root : null, before }
}

/** Records what a Bash call changed: each file now compared with the snapshot, or with git's index when it was clean */
async function recordBash($: EngineInterface, snap: Snapshot) {
  const after = snap.root ? await dirtyFiles($, snap.root) : []
  const found: { file: string; was: string | null; now: string | null }[] = []
  for (const file of new Set([...Object.keys(snap.before), ...after])) {
    const was =
      file in snap.before
        ? snap.before[file]!
        : snap.root
          ? await gitOut($, ['git', '-C', snap.root, 'show', `:${file.slice(snap.root.length + 1)}`])
          : null
    const now = await readOrNull($, file)
    if (was === now || [was ?? '', now ?? ''].some(t => t.length > MAX_BYTES || t.includes('\0'))) continue
    found.push({ file, was, now })
  }

  // A file that went away and one that appeared with mostly the same lines is one file moved
  const moves = new Map<string, string>()
  for (const born of found.filter(f => f.was === null && f.now !== null)) {
    const gone = found.find(f => f.now === null && f.was !== null && ![...moves.values()].includes(f.file) && isSimilar(f.was, born.now!))
    if (gone) moves.set(born.file, gone.file)
  }
  const movedAway = new Set(moves.values())

  const recorded: Change[] = []
  for (const { file, was, now } of found) {
    if (movedAway.has(file)) continue
    const from = moves.get(file)
    const before = from ? found.find(f => f.file === from)!.was! : (was ?? '')
    const diff = netDiff(before, now ?? '')
    if (diff === null || (diff === '' && !from)) continue
    await update($, baselines, all => (file in all ? all : { ...all, [file]: before }))
    const at = await $.clock.now()
    recorded.push({ id: newId(at), file, tool: 'Bash', diff, at, ...(from ? { renamedFrom: from } : {}) })
  }
  if (recorded.length === 0) return
  const isFirst = (await read($, changes)).length === 0
  await update($, changes, list => [...list, ...recorded].slice(-300))
  await update($, selected, current => current ?? recorded[0]!.file)
  if (isFirst) void $.ui.open({ id: PANE, title: 'Review' })
}

/** Whether two texts share at least half their lines in order: the test for a moved file */
function isSimilar(a: string, b: string): boolean {
  if (a === b) return true
  const ops = diffLines(splitLines(a), splitLines(b))
  const kept = ops?.filter(op => op.kind === ' ').length ?? 0
  return kept * 2 >= Math.max(splitLines(a).length, splitLines(b).length, 1)
}

/** A file's net change, from before Claude's first change to it to how it is on disk now; null when that cannot be told */
async function netChangeOf($: EngineInterface, file: string, edits: readonly Change[]): Promise<Change | null> {
  if (edits.length === 0) return null
  let now = ''
  try {
    now = await $.fs.read(file)
  } catch {
    // deleted since: everything it had is removed
  }
  const before = (await read($, baselines))[file] ?? (isCreate(edits[0]!.diff) ? '' : undoEdits(now, edits))
  const diff = before === undefined ? null : netDiff(before, now)
  const renamedFrom = edits.find(c => c.renamedFrom)?.renamedFrom
  return diff === null ? null : { id: `net:${file}`, file, tool: 'Edit', diff, at: edits[edits.length - 1]!.at, ...(renamedFrom ? { renamedFrom } : {}) }
}

/** Each file's net +/− counts, kept until Claude changes the file again: reading every file on each redraw is too slow */
const countCache = new Map<string, { key: string; add: number; del: number }>()

async function countsOf($: EngineInterface, file: string, edits: readonly Change[]) {
  const key = `${edits.length}:${edits[edits.length - 1]?.id}`
  const cached = countCache.get(file)
  if (cached?.key === key) return cached
  const net = await netChangeOf($, file, edits)
  const counts = { key, ...tally(net ? [net.diff] : edits.map(c => c.diff)) }
  countCache.set(file, counts)
  return counts
}

// ─── Comments found again on the diff shown ─────────────────────────────────

/**
 * Where a line comment sits in a change's rows now. A single edit's diff never changes, so its own
 * rows stand; anywhere else (the net diff, rebuilt as Claude keeps editing) the commented lines are
 * found again by content, nearest their line numbers. Null when they are not in this diff any more.
 */
function locate(c: ReviewComment, change: Change, rows: readonly Row[]): [number, number] | null {
  if (!c.rows) return null
  if (c.changeId === change.id && !change.id.startsWith('net:')) return c.rows
  const want = c.snippet ?? []
  if (want.length === 0) return null
  const idx = rows.flatMap((r, i) => (r.kind === 'hunk' ? [] : [i]))
  const textAt = (i: number) => `${MARK[rows[i]!.kind]}${rows[i]!.text}`
  const near = c.lines?.[0] ?? 0
  let best: [number, number] | null = null
  let bestGap = Infinity
  for (let s = 0; s + want.length <= idx.length; s++) {
    if (!want.every((w, j) => textAt(idx[s + j]!) === w)) continue
    const first = rows[idx[s]!]!
    const gap = Math.abs(((c.side === 'old' ? first.oldN : first.newN) ?? 0) - near)
    if (gap < bestGap) {
      bestGap = gap
      best = [idx[s]!, idx[s + want.length - 1]!]
    }
  }
  return best
}

/** Every line comment on the shown changes, by id: the change and rows it sits on now */
function anchorsOn(notes: readonly ReviewComment[], shown: readonly Change[]) {
  const anchors = new Map<string, { changeId: string; rows: [number, number] }>()
  for (const change of shown) {
    const rows = toRows(change.diff)
    for (const n of notes) {
      if (n.file !== change.file || anchors.has(n.id)) continue
      const at = locate(n, change, rows)
      if (at) anchors.set(n.id, { changeId: change.id, rows: at })
    }
  }
  return anchors
}

// ─── The open file and the cursor ───────────────────────────────────────────

const rowKey = (ref: RowRef) => `ln:${ref.changeId}:${ref.row}`
const sameRow = (a: RowRef | null, b: RowRef) => a !== null && a.changeId === b.changeId && a.row === b.row

/** The open file, what the pane shows of it, its lines in order, and the cursor resolved to one of them */
async function openFile($: EngineInterface) {
  const list = await read($, changes)
  // By path, so a folder's files sit together in the list and h/l walk them in that order
  const files = [...new Set(list.map(c => c.file))].sort()
  const current = await read($, selected)
  const file = current && files.includes(current) ? current : files[0]
  const edits = list.filter(c => c.file === file)
  const view = await read($, edit)
  const chosen = edits.find(c => c.id === view)
  const net = chosen || !file ? null : await netChangeOf($, file, edits)
  // The one edit picked, else the net change, else every edit when the net cannot be told
  const shown = chosen ? [chosen] : net ? [net] : edits

  // The cursor walks only the rows drawn: a long diff is cut at MAX_ROWS until t
  const limit = (await read($, fullDiff)) ? Infinity : MAX_ROWS
  const lines: RowRef[] = []
  const hunkStarts: number[] = []
  for (const change of shown) {
    toRows(change.diff).forEach((row, i) => {
      if (i >= limit) return
      if (row.kind === 'hunk') hunkStarts.push(lines.length)
      else lines.push({ changeId: change.id, row: i })
    })
  }
  const at = await read($, cursor)
  const index = Math.max(0, at ? lines.findIndex(l => sameRow(at, l)) : 0)
  return { list, files, file, edits, chosen, shown, lines, hunkStarts, index, here: lines[index] ?? null, limit }
}

/** Shows a file, and one of its edits or (null) all of them as one diff, from the top with nothing picked */
async function showView($: EngineInterface, file: string | null, id: string | null) {
  await update($, selected, () => file)
  await update($, edit, () => id)
  await update($, cursor, () => null)
  await update($, visual, () => null)
  await update($, selection, () => null)
}

/** Puts the cursor on a line: the focus ring follows it, and the pane scrolls to show it */
async function moveTo($: EngineInterface, ref: RowRef | undefined) {
  if (!ref) return
  await update($, visual, v => (v && v.changeId !== ref.changeId ? null : v))
  await update($, cursor, () => ref)
  try {
    await $.ui.focus({ requestId: PANE, key: rowKey(ref) })
    await $.ui.scroll({ to: { key: rowKey(ref) }, in: PANE })
  } catch {
    // the row draws on the next pass; the cursor mark is already there
  }
}

async function openComposer($: EngineInterface, next: Selection) {
  await update($, visual, () => null)
  await update($, replyTo, () => null)
  await update($, selection, () => next)
}

// ─── The vim-style keys, each pressed by its letter while the pane has the keyboard ─

async function keyMove($: EngineInterface, step: number) {
  const { lines, index } = await openFile($)
  await moveTo($, lines[Math.max(0, Math.min(lines.length - 1, index + step))])
}

async function keyHunk($: EngineInterface, dir: 1 | -1) {
  const { lines, hunkStarts, index } = await openFile($)
  const target = dir > 0 ? hunkStarts.find(h => h > index) : hunkStarts.findLast(h => h < index)
  await moveTo($, lines[target ?? (dir > 0 ? lines.length - 1 : 0)])
}

/** Whether a file is marked viewed and Claude has not changed it since */
const isViewed = (marks: Record<string, string>, list: readonly Change[], file: string) =>
  marks[file] !== undefined && marks[file] === list.findLast(c => c.file === file)?.id

async function keyFile($: EngineInterface, dir: 1 | -1) {
  const { list, files, file } = await openFile($)
  const marks = await read($, viewed)
  // Files not yet viewed come first: viewed ones are skipped while any other is left
  const order = Array.from({ length: files.length }, (_, k) => files[(files.indexOf(file ?? '') + dir * (k + 1) + files.length * 2) % files.length]!)
  const next = order.find(f => !isViewed(marks, list, f)) ?? order[0] ?? null
  await showView($, next, null)
  await keyMove($, 0)
}

/** m: marks the open file viewed, or clears the mark */
async function keyViewed($: EngineInterface) {
  const { list, file } = await openFile($)
  if (!file) return
  const last = list.findLast(c => c.file === file)?.id
  await update($, viewed, marks => {
    const { [file]: was, ...rest } = marks
    return was !== undefined && was === last ? rest : last ? { ...rest, [file]: last } : rest
  })
}

/**
 * Starts the review over from how the files are now: their changes, comments and marks are dropped,
 * and Claude's next change to one is compared with today's text. Refused while comments are unsent.
 */
async function startOver($: EngineInterface, only: string | null) {
  const inScope = (f: string) => only === null || f === only
  const unsent = (await read($, comments)).filter(c => inScope(c.file) && hasPending(c)).length
  if (unsent > 0) {
    $.ui.toast(`Send or delete the ${plural(unsent, 'pending comment')} first`)
    return
  }
  const dropped = new Set((await read($, changes)).map(c => c.file).filter(inScope))
  await update($, changes, list => list.filter(c => !inScope(c.file)))
  await update($, comments, list => list.filter(c => !inScope(c.file)))
  await update($, baselines, all => Object.fromEntries(Object.entries(all).filter(([f]) => !inScope(f))))
  await update($, viewed, all => Object.fromEntries(Object.entries(all).filter(([f]) => !inScope(f))))
  for (const f of dropped) countCache.delete(f)
  await showView($, null, null)
  if (only === null) await forgetReviews($)
  $.ui.toast(only === null ? 'Review started over' : `Started over on ${only.split('/').pop()}`)
}

/** e / b: the next or previous edit of the open file, "all" counting as the one before the first */
async function keyEdit($: EngineInterface, dir: 1 | -1 = 1) {
  const { file, edits, chosen } = await openFile($)
  const order = [null, ...edits.map(c => c.id)]
  await showView($, file ?? null, order[(order.indexOf(chosen?.id ?? null) + dir + order.length) % order.length] ?? null)
}

/** Up to this many edits every tab is drawn; past it, `1 2 3 4 … 76 77`, plus the shown one and its neighbours */
const TABS_SHOWN = 9

/** The edit tabs to draw, by index, with null where a run of them is left out */
function editWindow(count: number, at: number): (number | null)[] {
  if (count <= TABS_SHOWN) return Array.from({ length: count }, (_, i) => i)
  const around = at < 0 ? [] : [at - 1, at, at + 1]
  const keep = [...new Set([0, 1, 2, 3, count - 2, count - 1, ...around])].filter(i => i >= 0 && i < count).sort((a, b) => a - b)
  return keep.flatMap((i, k) => (k > 0 && i - keep[k - 1]! > 1 ? [null, i] : [i]))
}

async function keyVisual($: EngineInterface) {
  const { here } = await openFile($)
  await update($, visual, v => (v ? null : here))
}

async function keyComment($: EngineInterface) {
  const { here } = await openFile($)
  if (!here) return
  const from = await read($, visual)
  const other = from && from.changeId === here.changeId ? from.row : here.row
  await openComposer($, { changeId: here.changeId, from: Math.min(other, here.row), to: Math.max(other, here.row) })
}

async function keyHunkComment($: EngineInterface) {
  const { shown, here } = await openFile($)
  const change = shown.find(c => c.id === here?.changeId)
  if (!here || !change) return
  const rows = toRows(change.diff)
  const hunk = rows[here.row]?.hunk
  const from = rows.findIndex(r => r.hunk === hunk && r.kind !== 'hunk')
  await openComposer($, { changeId: here.changeId, from, to: rows.findLastIndex(r => r.hunk === hunk) })
}

/** The last line comment whose lines, as found again on the diff shown, cover the cursor */
async function commentAtCursor($: EngineInterface, isWanted: (c: ReviewComment) => boolean) {
  const { shown, here } = await openFile($)
  if (!here) return undefined
  const notes = await read($, comments)
  const anchors = anchorsOn(notes, shown)
  return notes.findLast(c => {
    const at = anchors.get(c.id)
    return isWanted(c) && at?.changeId === here.changeId && here.row >= at.rows[0] && here.row <= at.rows[1]
  })
}

async function keyRemove($: EngineInterface) {
  const target = await commentAtCursor($, c => c.status === 'pending')
  if (target) await update($, comments, list => list.filter(c => c.id !== target.id))
}

/** Opens the reply box on the discussion under the cursor: the prompt then answers it */
async function keyReply($: EngineInterface) {
  const target = await commentAtCursor($, () => true)
  if (target) await startReply($, target.id)
}

async function startReply($: EngineInterface, id: string) {
  await update($, visual, () => null)
  await update($, selection, () => null)
  await update($, replyTo, () => id)
}

/** f: opens the file finder, its field taking the keys */
async function keyFinder($: EngineInterface) {
  await update($, finder, q => q ?? '')
  try {
    await $.ui.focus({ requestId: PANE, key: 'finder' })
  } catch {
    // the field draws on the next pass with autoFocus
  }
}

/** The comment w last jumped to, so the next press goes on from it */
let lastJump: string | null = null

/**
 * w: jumps to the next comment still open (unsent, or sent and not resolved), across files in list
 * order then by line, wrapping: its file is opened on all changes and the cursor put on its lines.
 */
async function keyNextComment($: EngineInterface) {
  const { files } = await openFile($)
  const open = (await read($, comments)).filter(c => hasPending(c) || !c.isResolved)
  if (open.length === 0) {
    $.ui.toast('No open comments')
    return
  }
  const order = [...open].sort((a, b) => files.indexOf(a.file) - files.indexOf(b.file) || (a.lines?.[0] ?? 0) - (b.lines?.[0] ?? 0))
  const next = order[(order.findIndex(c => c.id === lastJump) + 1) % order.length]!
  lastJump = next.id
  await showView($, next.file, null)
  const { shown } = await openFile($)
  const at = anchorsOn([next], shown).get(next.id)
  if (at) await moveTo($, { changeId: at.changeId, row: at.rows[0] })
  $.ui.toast(`Open comment ${order.indexOf(next) + 1} of ${order.length}${at || !next.rows ? '' : ' (outdated, under the file)'}`)
}

/** Opens a file from the finder or the list, and closes the finder */
async function openFound($: EngineInterface, path: string) {
  await showView($, path, null)
  await update($, finder, () => null)
}

async function keyCancel($: EngineInterface) {
  await update($, visual, () => null)
  await update($, selection, () => null)
  await update($, replyTo, () => null)
  await update($, finder, () => null)
  const at = await read($, cursor)
  if (at) await moveTo($, at)
}

// ─── Comments ───────────────────────────────────────────────────────────────

/** A file comment's typed line range, as `12-20:` or `L12:` before the text */
const LINES = /^L?(\d+)(?:\s*-\s*L?(\d+))?\s*:\s*/i

const range = (a: number, b: number) => (a === b ? `L${a}` : `L${a}-${b}`)

/** The line numbers picked rows cover: in the new file, or the old one when only removed lines are picked */
function spanOf(rows: readonly Row[], picked: Selection) {
  const span = rows.slice(picked.from, picked.to + 1).filter(r => r.kind !== 'hunk')
  const news = span.flatMap(r => (r.newN === undefined ? [] : [r.newN]))
  const side: 'new' | 'old' = news.length > 0 ? 'new' : 'old'
  const nums = side === 'new' ? news : span.flatMap(r => (r.oldN === undefined ? [] : [r.oldN]))
  const lines: [number, number] | undefined = nums.length > 0 ? [Math.min(...nums), Math.max(...nums)] : undefined
  return { span, side, lines }
}

function whereOf(c: Pick<ReviewComment, 'lines' | 'side'>): string {
  return c.lines ? `${c.side === 'old' ? 'old ' : ''}${range(c.lines[0], c.lines[1])}` : ''
}

const isPendingReply = (r: Reply) => r.author === 'you' && r.status === 'pending'
/** A new comment, or a discussion with a follow-up of the user's not yet sent */
const hasPending = (c: ReviewComment) => c.status === 'pending' || (c.replies ?? []).some(isPendingReply)

function asMessage(list: readonly ReviewComment[]): string {
  const parts = list.map(c => {
    const where = c.lines ? `${c.file} ${whereOf(c)}` : `${c.file} (whole file)`
    const code = c.snippet?.length ? `\n  \`\`\`diff\n${c.snippet.map(l => `  ${l}`).join('\n')}\n  \`\`\`` : ''
    const talk = (c.replies ?? []).map(r => `\n  ${r.author === 'you' ? 'User' : 'You (Claude)'}: ${r.text}`).join('')
    return `- [${c.id}] ${where}${talk ? ' (continued discussion; answer the last message)' : ''}:${code}\n  User: ${c.text}${talk}`
  })
  return [
    'Review comments left in the review pane on files you changed. Address each one:',
    ...parts,
    `Then answer each with the ${REPLY_TOOL} tool, passing its id in brackets: what you changed, or why you did not. Set resolved when it is handled.`,
  ].join('\n')
}

const REPLY_TOOL = 'mcp__review-pane__reply'

/** Claude's answer on a comment, from its `reply` tool; an error text when there is no such comment */
async function addReply($: EngineInterface, id: string, text: string, isResolved: boolean): Promise<ReviewComment | string> {
  const found = (await read($, comments)).find(c => c.id === id)
  if (!found) return `No review comment with id "${id}". Use the id shown in brackets in the review message.`
  if (!text.trim()) return 'The reply text is empty.'
  const reply: Reply = { author: 'claude', text: text.trim(), at: await $.clock.now() }
  await update($, comments, list =>
    list.map(c => (c.id === id ? { ...c, replies: [...(c.replies ?? []), reply], isResolved: isResolved || c.isResolved } : c)),
  )
  return found
}

/** The user's follow-up in a discussion: pending until the next prompt, and the discussion open again */
async function addUserReply($: EngineInterface, id: string, value: string) {
  const text = value.trim()
  if (!text) return
  const reply: Reply = { author: 'you', text, at: await $.clock.now(), status: 'pending' }
  await update($, comments, list => list.map(c => (c.id === id ? { ...c, replies: [...(c.replies ?? []), reply], isResolved: false } : c)))
  await update($, replyTo, () => null)
}

async function takePending($: EngineInterface): Promise<ReviewComment[]> {
  const pending = (await read($, comments)).filter(hasPending)
  if (pending.length > 0) {
    await update($, comments, list =>
      list.map(c => ({ ...c, status: 'sent' as const, replies: c.replies?.map(r => (isPendingReply(r) ? { ...r, status: 'sent' as const } : r)) })),
    )
  }
  return pending
}

async function sendNow($: EngineInterface) {
  const taken = await takePending($)
  if (taken.length > 0) void $.prompt.submit({ text: asMessage(taken) })
}

async function addLineComment($: EngineInterface, change: Change, picked: Selection, value: string) {
  const text = value.trim()
  if (!text) return
  const { span, side, lines } = spanOf(toRows(change.diff), picked)
  const comment: ReviewComment = {
    id: newId(await $.clock.now()),
    file: change.file,
    changeId: change.id,
    rows: [picked.from, picked.to],
    lines,
    side,
    snippet: span.map(r => `${MARK[r.kind]}${r.text}`),
    text,
    status: 'pending',
  }
  await update($, comments, all => [...all, comment])
  await update($, selection, () => null)
  await moveTo($, { changeId: change.id, row: picked.to })
}

async function addFileComment($: EngineInterface, file: string, value: string) {
  const match = value.trim().match(LINES)
  const text = match ? value.trim().slice(match[0].length).trim() : value.trim()
  if (!text) return
  const [from, to] = match ? [Number(match[1]), Number(match[2] ?? match[1])] : []
  const lines: [number, number] | undefined = from && to ? [Math.min(from, to), Math.max(from, to)] : undefined
  const comment: ReviewComment = { id: newId(await $.clock.now()), file, lines, text, status: 'pending' }
  await update($, comments, all => [...all, comment])
}

// ─── The web review ─────────────────────────────────────────────────────────

/** Where the web review is published from, inside the session's working directory (the publish tool reads only there) */
const WORK_DIR = '.claude/review-pane'
/** The `$.store` key holding this machine's web review page, created on first use */
const WEB_URL_KEY = 'webUrl'
const ARTIFACT_URL = /https:\/\/claude\.ai\/(?:code\/)?artifact\/[A-Za-z0-9-]+/
/** Diff text that may hold a credential: such a review goes through Claude, who checks it before publishing */
const SECRET =
  /((api[_-]?key|secret|token|passw(or)?d)\w*\s*[:=]\s*['"][^'"\s]{8,}['"]|BEGIN [A-Z ]*PRIVATE KEY|\bsk-[A-Za-z0-9_-]{20,}|\bgh[pousr]_[A-Za-z0-9]{30,}|\bAKIA[0-9A-Z]{16}\b)/i
/** Ways to hand a link to the browser, tried in order: macOS, Linux, WSL, Windows */
const OPENERS: readonly (readonly string[])[] = [['open'], ['xdg-open'], ['wslview'], ['cmd', '/c', 'start', '""']]
const LANGUAGES: Record<string, string> = {
  lua: 'lua', ts: 'typescript', tsx: 'typescript', js: 'javascript', jsx: 'javascript', mjs: 'javascript',
  py: 'python', json: 'json', md: 'markdown', sh: 'bash', bash: 'bash', zsh: 'bash', fish: 'bash',
  vim: 'vim', toml: 'ini', yaml: 'yaml', yml: 'yaml', css: 'css', html: 'xml', go: 'go', rs: 'rust',
}

/** Whether this load of the mod has read its page: the publish tool updates only a page read or published in the session */
let hasReadPage = false

/** Opens a link in the person's browser; the Artifact tool's own open does not reach the screen from a mod */
async function openInBrowser($: EngineInterface, url: string): Promise<boolean> {
  for (const opener of OPENERS) {
    try {
      if ((await $.process.run([...opener, url], { timeoutMs: 5000 })).exitCode === 0) return true
    } catch {
      // not on this system: try the next one
    }
  }
  return false
}

/** Publishes the pane's changes to the web review page and opens it, without a turn of Claude's */
async function openOnWeb($: EngineInterface) {
  const list = await read($, changes)
  const files = await Promise.all(
    [...new Set(list.map(c => c.file))].map(async path => {
      const edits = list.filter(c => c.file === path)
      const net = await netChangeOf($, path, edits)
      return {
        path,
        language: LANGUAGES[path.split('.').pop()?.toLowerCase() ?? ''] ?? '',
        ...(net ? { net: net.diff } : {}),
        changes: edits.map(c => ({ tool: c.tool, verb: isCreate(c.diff) ? 'Created' : 'Edited', diff: c.diff })),
      }
    }),
  )
  const dir = `${await $.session.cwd()}/${WORK_DIR}`
  const page = `${dir}/index.html`
  const data = `${dir}/changes.json`
  const json = JSON.stringify({ title: 'Session changes', note: 'Files Claude changed in this session.', files }, null, 1)
  await $.fs.write(`${dir}/.gitignore`, '*\n')
  await $.fs.write(page, await $.fs.read(`${$.plugin.root}/web/index.html`))
  await $.fs.write(data, json)

  const stored = await $.store.get(WEB_URL_KEY)
  let url = typeof stored === 'string' ? stored : undefined

  const askClaude = (why: string) => {
    $.ui.toast(`${why} Asking Claude to publish it instead…`)
    void $.prompt.submit({
      text: `Publish the review pane's current changes to the web review page and open it: ${why} The page is ${page} and its data ${data} (publish it as changes.json); check the data, then ${url ? `update ${url}` : 'publish it as a new artifact'}.`,
    })
  }

  if (SECRET.test(json)) return askClaude('The changes may contain a credential.')

  $.ui.toast('Publishing the web review…')
  try {
    if (url && !hasReadPage) {
      const current = await $.tool.call({ tool: 'Artifact', action: 'read', url })
      // A page that cannot be read any more (deleted, or another account's) is replaced by a new one
      if (current.deny !== undefined || current.isError) url = undefined
    }
    const published = await $.tool.call({
      tool: 'Artifact',
      file_path: page,
      files: { 'changes.json': data },
      label: 'Session changes',
      ...(url
        ? { url }
        : {
            icon: 'code',
            description: 'Diffs of the files Claude changed, with line comments you can send to Claude.',
            capabilities: { comments: {} },
          }),
    })
    if (published.deny !== undefined || published.isError) {
      throw new Error(published.deny ?? published.text ?? 'the publish tool reported an error')
    }
    const at = url ?? published.text?.match(ARTIFACT_URL)?.[0]
    if (!at) throw new Error('the page was published but its link was not in the result')
    if (at !== stored) await $.store.set(WEB_URL_KEY, at)
    hasReadPage = true
    $.ui.toast((await openInBrowser($, at)) ? 'Web review opened in your browser' : `Published; open ${at} to see it`)
  } catch (error) {
    const why = error instanceof Error ? error.message : String(error)
    $.ui.log(`review-pane: publish failed: ${why}`)
    askClaude(`Publishing from the pane did not work (${why.slice(0, 160)}).`)
  }
}

// ─── Kept across sessions ───────────────────────────────────────────────────

/**
 * A review is saved per repository, so a session in one repo does not pick up another's: the `$.store`
 * key of the files under one root (their git repository, or, for files in none, the folder they share).
 */
const STORE_PREFIX = 'review:'
const storeKey = (root: string) => `${STORE_PREFIX}${root}`
/** The store holds 4 MiB in all; past this a review is kept without its "before" texts, then not at all */
const MAX_SAVED = 1_500_000

type SavedReview = { changes?: Change[]; comments?: ReviewComment[]; viewed?: Record<string, string>; baselines?: Record<string, string> }

/** Each folder's git repository root, or null for none; asked once per folder per load */
const repoRoots = new Map<string, string | null>()
/** The roots this load saved a review under, so one emptied since (or started over) is removed */
const savedRoots = new Set<string>()

async function repoRootOf($: EngineInterface, dir: string): Promise<string | null> {
  if (!repoRoots.has(dir)) repoRoots.set(dir, (await gitOut($, ['git', '-C', dir, 'rev-parse', '--show-toplevel']))?.trim() || null)
  return repoRoots.get(dir) ?? null
}

/** The root of every file: its repository, else the folder all such files share */
async function rootsOf($: EngineInterface, files: readonly string[]) {
  const roots = new Map<string, string | null>()
  for (const f of files) roots.set(f, await repoRootOf($, f.slice(0, f.lastIndexOf('/')) || '/'))
  const loose = files.filter(f => roots.get(f) === null)
  const shared = commonDir(loose) || '/'
  return new Map(files.map(f => [f, roots.get(f) ?? shared]))
}

async function saveReview($: EngineInterface) {
  const list = await read($, changes)
  const roots = await rootsOf($, [...new Set(list.map(c => c.file))])
  const notes = await read($, comments)
  const marks = await read($, viewed)
  const befores = await read($, baselines)
  const now = new Set(roots.values())
  for (const root of savedRoots) if (!now.has(root)) await $.store.delete(storeKey(root))
  for (const root of now) {
    const isHere = (f: string) => roots.get(f) === root
    const pick = <T,>(all: Record<string, T>) => Object.fromEntries(Object.entries(all).filter(([f]) => isHere(f)))
    const review: SavedReview = { changes: list.filter(c => isHere(c.file)), comments: notes.filter(c => isHere(c.file)), viewed: pick(marks), baselines: pick(befores) }
    if (JSON.stringify(review).length > MAX_SAVED) review.baselines = {}
    if (JSON.stringify(review).length > MAX_SAVED) continue
    await $.store.set(storeKey(root), review)
    savedRoots.add(root)
  }
}

/** Removes every review this load saved, and the ones it picked up */
async function forgetReviews($: EngineInterface) {
  for (const root of savedRoots) await $.store.delete(storeKey(root))
  savedRoots.clear()
}

/**
 * Picks up the reviews saved for this session's repository (or folder), and for folders inside it,
 * when this session has none of its own yet.
 */
async function restoreReview($: EngineInterface, cwd: string) {
  if ((await read($, changes)).length > 0) return
  const here = (await repoRootOf($, cwd)) ?? cwd
  const keys = (await $.store.keys()).filter(k => k.startsWith(STORE_PREFIX))
  const mine = keys.map(k => k.slice(STORE_PREFIX.length)).filter(root => root === here || root.startsWith(`${here}/`))
  for (const root of mine) {
    const saved = (await $.store.get(storeKey(root))) as SavedReview | undefined
    if (!saved?.changes?.length) continue
    await update($, changes, list => [...list, ...saved.changes!])
    await update($, comments, list => [...list, ...(saved.comments ?? [])])
    await update($, viewed, all => ({ ...all, ...saved.viewed }))
    await update($, baselines, all => ({ ...all, ...saved.baselines }))
    savedRoots.add(root)
  }
}

// ─── Hooks ──────────────────────────────────────────────────────────────────

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await restoreReview($, e.cwd).catch(() => undefined)
    await $.command.register({
      name: 'review-pane',
      description: 'Open the review pane: files Claude changed, their diffs, and your comments',
    })
    await $.tool.register({
      name: 'reply',
      description:
        "Answers a comment the user left in the review pane on a file you changed: what you did about it, or why not. The comment's id is in brackets in the review message. The user sees the reply under their comment.",
      inputSchema: {
        type: 'object',
        properties: {
          commentId: { type: 'string', description: 'The id in brackets before the comment' },
          text: { type: 'string', description: 'The reply, a sentence or two' },
          resolved: { type: 'boolean', description: 'True when the comment is fully handled' },
        },
        required: ['commentId', 'text'],
      },
      isDeferred: false,
    })
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    await saveReview($).catch(() => undefined)
    return next(e)
  })

  on('tool.call', { tool: REPLY_TOOL }, async ($, e) => {
    const input = e as unknown as { commentId?: unknown; text?: unknown; resolved?: unknown }
    const answer = await addReply($, String(input.commentId ?? ''), String(input.text ?? ''), input.resolved === true)
    if (typeof answer === 'string') return { deny: answer }
    return { result: `Reply added under the comment on ${answer.file}${answer.lines ? ` ${whereOf(answer)}` : ''}.` }
  })

  on('command.run', { command: 'review-pane' }, async $ => {
    const opened = await $.ui.open({ id: PANE, title: 'Review', focus: true })
    return {
      text: opened.isPlaced
        ? 'Review pane opened. j/k move, c comments; the keys are listed at the top.'
        : 'The review pane is waiting for room to show.',
    }
  }).catch(() => ({ text: 'The review pane could not open.' }))

  on('tool.call', async ($, e, next) => {
    if (e.tool === 'Bash') {
      // Compared around the call, never failing it: a throw here would run the command again from the catch below
      const snap = await snapshot($).catch(() => null)
      const ran = await next(e)
      if (snap && ran.deny === undefined) await recordBash($, snap).catch(() => undefined)
      return ran
    }
    const ran = await next(e)
    if ((e.tool !== 'Edit' && e.tool !== 'Write') || ran.deny !== undefined || ran.isError) return ran
    const result = ran.result as {
      filePath: string
      structuredPatch?: Hunk[]
      type?: 'create' | 'update'
      content?: string
      originalFile?: string | null
      staged?: boolean
    }
    if (!result?.filePath || result.staged) return ran
    const diff = toDiff(result.structuredPatch ?? [], result.type === 'create' ? result.content : undefined)
    if (diff === '') return ran

    const before = result.type === 'create' ? '' : result.originalFile
    if (typeof before === 'string') {
      await update($, baselines, all => (result.filePath in all ? all : { ...all, [result.filePath]: before }))
    }
    const now = await $.clock.now()
    const change: Change = { id: newId(now), file: result.filePath, tool: e.tool, diff, at: now }
    const isFirst = (await read($, changes)).length === 0
    await update($, changes, list => [...list, change].slice(-300))
    await update($, selected, current => current ?? change.file)
    if (isFirst) void $.ui.open({ id: PANE, title: 'Review' })
    return ran
  }).catch(($, e, next) => next(e))

  on('prompt.submit', async ($, e, next) => {
    if (e.command || e.isMeta) return next(e)
    // While a reply box is open, the prompt is the user's next message in that discussion
    const answering = await read($, replyTo)
    const discussion = answering ? (await read($, comments)).find(c => c.id === answering) : undefined
    if (discussion && e.text.trim() !== '' && !e.text.trim().startsWith('/')) {
      await addUserReply($, discussion.id, e.text)
      return { drop: `Reply added on ${discussion.file.split('/').pop()}${discussion.lines ? ` ${whereOf(discussion)}` : ''}; s sends it` }
    }
    // While a comment box is open, the prompt is the comment: it stays in the pane, no turn starts
    const open = await read($, selection)
    const change = open && (await openFile($)).shown.find(c => c.id === open.changeId)
    // A slash command is never a comment, even one the engine did not mark as a command
    if (open && change && e.text.trim() !== '' && !e.text.trim().startsWith('/')) {
      await addLineComment($, change, open, e.text)
      return { drop: `Comment added on ${change.file.split('/').pop()} ${whereOf(spanOf(toRows(change.diff), open))}` }
    }
    const pending = await takePending($)
    // Saved at each prompt too, so a session that ends without its end event still leaves its review
    await saveReview($).catch(() => undefined)
    return pending.length === 0 ? next(e) : next({ ...e, context: [...(e.context ?? []), asMessage(pending)] })
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    if (!('Input' in ui)) {
      const { Text } = ui
      return <Text dimColor>Open the review pane in the terminal or desktop app to leave comments.</Text>
    }
    const { Box, Text, Button, Input, Code } = ui
    const { list, files, file, edits, chosen, shown, here, limit } = await openFile($)
    const notes = await read($, comments)
    const marks = await read($, viewed)
    const counts = new Map(await Promise.all(files.map(async f => [f, await countsOf($, f, list.filter(c => c.file === f))] as const)))
    const anchors = anchorsOn(notes, shown)
    // In the net view a line comment not found any more sits under the file, marked outdated
    const outdated = shown.some(c => c.id.startsWith('net:')) ? notes.filter(n => n.file === file && n.rows && !anchors.has(n.id)) : []
    const viewedCount = files.filter(f => isViewed(marks, list, f)).length
    const fileNotes = notes.filter(c => c.file === file && !c.changeId)
    const sel = await read($, selection)
    const from = await read($, visual)
    const isKeysOpen = await read($, showKeys)
    const answering = await read($, replyTo)
    const pending = notes.filter(hasPending)
    const halfPage = Math.max(1, Math.floor(e.props.scroll.bodyRows / 2))

    if (!file) {
      return (
        <Box flexDirection="column" paddingY={1} gap={1}>
          <Text bold>Nothing to review yet</Text>
          <Text dimColor>Files Claude creates or edits in this session show up here as diffs you can comment on.</Text>
        </Box>
      )
    }

    // One line-number column: the new file's number, or the old one on a removed line
    const numberOf = (r: Row) => (r.kind === 'del' ? r.oldN : r.newN)
    const width = Math.max(2, ...shown.flatMap(c => toRows(c.diff).map(r => String(numberOf(r) ?? 0).length)))
    const pad = (n?: number) => String(n ?? '').padStart(width)
    const gutter = width + 4

    /** Rows shown as picked: the open comment box's, or the visual range from `v` to the cursor */
    const pickedIn = (changeId: string): Selection | null => {
      if (sel?.changeId === changeId) return sel
      if (from?.changeId === changeId && here?.changeId === changeId) {
        return { changeId, from: Math.min(from.row, here.row), to: Math.max(from.row, here.row) }
      }
      return null
    }

    /** `+3 −1`, leaving out a side that is zero */
    const Counts = ({ add, del }: { add: number; del: number }) => (
      <Text>
        {add > 0 && <Text color="diffAdded">+{add}</Text>}
        {add > 0 && del > 0 && ' '}
        {del > 0 && <Text color="diffRemoved">−{del}</Text>}
      </Text>
    )

    /** One shortcut: drawn as `j: down`, pressed by its letter while the pane has the keyboard */
    const Key = ({ k, label, run }: { k: string; label: string; run: () => unknown }) => (
      <Button key={`key:${k}`} plain hotkey={k} onPress={() => void run()}>
        <Text dimColor>{label}</Text>
      </Button>
    )

    /** A marker and a label, for the open file in the file list */
    const Choice = ({ isOn, children }: { isOn: boolean; children: string }) => (
      <Text>
        <Text color={isOn ? 'claude' : 'inactive'}>{isOn ? '▸ ' : '  '}</Text>
        <Text bold={isOn} dimColor={!isOn}>
          {children}
        </Text>
      </Text>
    )

    const isListOpen = files.length <= FILES_SHOWN
    const query = await read($, finder)
    // Ranked by fuzzy score over the path from the shared folder; all files, by path, while the query is empty
    const found =
      query === null
        ? []
        : files
            .flatMap(p => {
              const score = fuzzyScore(query, p.slice(commonDir(files).length + 1))
              return score === null ? [] : [{ p, score }]
            })
            .sort((a, b) => b.score - a.score || a.p.localeCompare(b.p))
            .map(m => m.p)
    const base = commonDir(files)
    const dirOf = (path: string) => path.slice(base.length + 1).split('/').slice(0, -1).join('/') || '.'
    /** Where a file sits, for the folded line: its folder from the shared one, or the shared one itself, home as ~ */
    const placeOf = (path: string) => {
      const dir = dirOf(path)
      return dir === '.' ? `${base.replace(/^\/(Users|home)\/[^/]+/, '~')}/` : `${dir}/`
    }
    /** What one change was: `Edited by Bash`, `Created`, `Moved from lua/old.lua` */
    const describe = (c: Change) =>
      `${c.renamedFrom ? 'Moved' : isCreate(c.diff) ? 'Created' : 'Edited'}${c.tool === 'Bash' ? ' by Bash' : ''}` +
      (c.renamedFrom ? ` from ${c.renamedFrom.slice(base.length + 1) || c.renamedFrom}` : '')
    const legend = [
      ...(edits.some(c => isCreate(c.diff) && c.tool !== 'Bash') ? ['+ created'] : []),
      ...(edits.some(c => c.tool === 'Bash') ? ['$ by Bash'] : []),
    ]
    const dirs = [...new Set(files.map(dirOf))]
    const nameOf = (path: string) => path.split('/').pop() ?? path
    const nameWidth = Math.max(...files.map(p => nameOf(p).length))
    const pendingElsewhere = notes.filter(c => c.file !== file && hasPending(c)).length

    /** A file in the list: name padded so the counts line up; picking one folds the list again */
    const fileRow = (path: string, indent: number, isAligned = true) => {
      const noted = notes.filter(c => c.file === path && hasPending(c)).length
      return (
        <Box key={`filerow:${path}`} marginLeft={indent}>
          <Button
            key={`file:${path}`}
            plain
            onPress={() => openFound($, path)}
          >
            <Choice isOn={path === file}>{isAligned ? nameOf(path).padEnd(nameWidth) : nameOf(path)}</Choice>
            <Text color="success">{isViewed(marks, list, path) ? ' ✓ ' : '   '}</Text>
            <Counts {...(counts.get(path) ?? { add: 0, del: 0 })} />
            {noted > 0 && <Text color="warning">  ● {noted}</Text>}
          </Button>
        </Box>
      )
    }

    /** One edit tab: padded so the inverted one reads as a chip */
    const Tab = ({ isOn, children }: { isOn: boolean; children: string }) => (
      <Text inverse={isOn} bold={isOn} color={isOn ? 'claude' : undefined} dimColor={!isOn}>
        {` ${children} `}
      </Text>
    )

    const thread = (c: ReviewComment, indent: number) => {
      const isSent = c.status === 'sent'
      return (
        <Box key={`note:${c.id}`} marginLeft={indent} borderStyle="round" borderColor={isSent ? 'inactive' : 'suggestion'} paddingX={1} flexDirection="column">
          <Box justifyContent="space-between">
            <Text>
              <Text bold>You</Text>
              <Text dimColor> on {c.lines ? whereOf(c) : 'the whole file'}</Text>
              {'  '}
              <Text color={c.isResolved ? 'success' : isSent ? 'inactive' : 'warning'}>
                {c.isResolved ? '✓ resolved' : isSent ? '✓ sent' : '◷ pending'}
              </Text>
            </Text>
            {isSent ? (
              <Button key={`replybtn:${c.id}`} plain dimColor label="reply" onPress={() => startReply($, c.id)} />
            ) : (
              <Button key={`del:${c.id}`} plain dimColor label="delete" onPress={() => update($, comments, all => all.filter(o => o.id !== c.id))} />
            )}
          </Box>
          <Text dimColor={isSent}>{c.text}</Text>
          {(c.replies ?? []).map((r, i) => (
            <Text key={`reply:${c.id}:${i}`}>
              <Text bold color={r.author === 'you' ? undefined : 'claude'}>
                {r.author === 'you' ? 'You' : 'Claude'}{' '}
              </Text>
              {r.text}
              {isPendingReply(r) && <Text color="warning"> ◷ pending</Text>}
            </Text>
          ))}
          {answering === c.id && (
            <Text>
              <Text bold color="claude">Reply</Text>
              <Text dimColor> · Esc, then type it in the prompt · q cancels</Text>
            </Text>
          )}
        </Box>
      )
    }

    // The comment is typed in the prompt box, which wraps: the `prompt.submit` hook takes it
    const composer = (change: Change, open: Selection) => (
      <Box key={`compose:${change.id}`} marginLeft={gutter} flexDirection="column" borderStyle="round" borderColor="claude" paddingX={1}>
        <Text>
          <Text bold>New comment</Text>
          <Text dimColor> on {whereOf(spanOf(toRows(change.diff), open))} · Esc, then type it in the prompt · q cancels</Text>
        </Text>
      </Box>
    )

    const renderChange = (change: Change) => {
      const rows = toRows(change.diff)
      const picked = pickedIn(change.id)
      // Each comment where its lines are found now, not where they were when it was written
      const threads = notes.flatMap(n => {
        const at = anchors.get(n.id)
        return at?.changeId === change.id ? [{ n, rows: at.rows }] : []
      })
      const isCommented = (i: number) => threads.some(t => i >= t.rows[0] && i <= t.rows[1])
      const isNet = change.id.startsWith('net:')
      const hidden = rows.length - Math.min(rows.length, limit)

      const out: RenderElement[] = []
      rows.forEach((row, i) => {
        if (i >= limit) return
        if (row.kind === 'hunk') {
          const last = rows.findLastIndex(r => r.hunk === row.hunk)
          out.push(
            // A quiet separator in place of the raw `@@ -a,b +c,d @@` header
            <Box key={`hunk:${change.id}:${i}`} justifyContent="space-between">
              <Text dimColor>{` ${' '.repeat(width)}  ⋯ line ${numberOf(rows[i + 1] ?? row) ?? ''}`}</Text>
              <Button key={`hunkbtn:${change.id}:${i}`} plain onPress={() => openComposer($, { changeId: change.id, from: i + 1, to: last })}>
                <Text dimColor>+ note on hunk </Text>
              </Button>
            </Box>,
          )
        } else {
          const ref = { changeId: change.id, row: i }
          const isCursor = sameRow(here, ref)
          const isPicked = picked !== null && i >= picked.from && i <= picked.to
          const tint = row.kind === 'add' ? 'diffAddedDimmed' : row.kind === 'del' ? 'diffRemovedDimmed' : undefined
          const sign = row.kind === 'add' ? 'diffAdded' : row.kind === 'del' ? 'diffRemoved' : 'inactive'
          out.push(
            <Box key={`row:${change.id}:${i}`} backgroundColor={tint}>
              <Button
                key={rowKey(ref)}
                plain
                onPress={async () => {
                  // A second line in the same change extends a one-line pick into a range
                  const isRange = sel?.changeId === change.id && sel.from === sel.to && sel.from !== i
                  await update($, cursor, () => ref)
                  await openComposer($, isRange ? { changeId: change.id, from: Math.min(sel.from, i), to: Math.max(sel.from, i) } : { changeId: change.id, from: i, to: i })
                }}
              >
                <Text color={isCursor ? 'claude' : 'suggestion'} bold>
                  {isCursor ? '▸' : isPicked ? '▌' : isCommented(i) ? '●' : ' '}
                </Text>
                <Text inverse={isPicked} color={isPicked ? 'suggestion' : isCursor ? 'claude' : undefined} dimColor={!isPicked && !isCursor} bold={isCursor}>
                  {pad(numberOf(row))}
                </Text>
                <Text color={sign}> {MARK[row.kind]} </Text>
              </Button>
              <Box flexGrow={1} flexShrink={1}>
                <Code source={row.text === '' ? ' ' : row.text} path={change.file} wrap="truncate-end" />
              </Box>
            </Box>,
          )
        }
        if (sel?.changeId === change.id && i === sel.to) out.push(composer(change, sel))
        for (const t of threads) if (t.rows[1] === i) out.push(thread(t.n, gutter))
      })
      if (hidden > 0) {
        out.push(
          <Text key={`more:${change.id}`} dimColor>
            {` … ${plural(hidden, 'more row')} not drawn · t draws the whole diff`}
          </Text>,
        )
      }

      return (
        <Box key={`change:${change.id}`} flexDirection="column">
          {/* Its own title only when several changes are drawn at once (the net could not be told) */}
          {shown.length > 1 && (
            <Box justifyContent="space-between">
              <Text>
                <Text bold>{`Edit ${edits.indexOf(change) + 1}`}</Text>
                <Text dimColor>{` · ${describe(change)}`}</Text>
              </Text>
              <Counts {...tally([change.diff])} />
            </Box>
          )}
          {rows.length === 0 ? (
            <Text dimColor>{change.renamedFrom ? ' Moved without changing its text.' : ' No net change: the file is back to how it was.'}</Text>
          ) : (
            out
          )}
        </Box>
      )
    }

    return (
      // One blank row between the sections: header, file, diff, notes, buttons
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="column">
          <Box justifyContent="space-between" flexWrap="wrap" columnGap={2}>
            <Box flexShrink={0}>
              <Text bold color="claude">
                Review
              </Text>
            </Box>
            <Box flexShrink={0}>
              <Text>
                <Text dimColor>{plural(files.length, 'file')} · </Text>
                {viewedCount > 0 && <Text dimColor>{viewedCount}/{files.length} viewed · </Text>}
                <Counts
                  add={[...counts.values()].reduce((s, c) => s + c.add, 0)}
                  del={[...counts.values()].reduce((s, c) => s + c.del, 0)}
                />
                {pending.length > 0 && <Text color="warning"> · {pending.length} pending</Text>}
              </Text>
            </Box>
          </Box>
          <Box columnGap={2} flexWrap="wrap">
            <Key k="i" label={isKeysOpen ? 'hide keys' : 'keys'} run={() => update($, showKeys, open => !open)} />
            {!isKeysOpen && <Text dimColor>j/k move · v range · c comment · r reply · s send</Text>}
          </Box>
          {/* Always drawn so every key works; hidden until i opens it */}
          <Box display={isKeysOpen ? 'flex' : 'none'} flexDirection="column" borderStyle="round" borderColor="inactive" paddingX={1}>
            <Box columnGap={2} flexWrap="wrap">
              <Text bold>Move   </Text>
              <Key k="j" label="down" run={() => keyMove($, 1)} />
              <Key k="k" label="up" run={() => keyMove($, -1)} />
              <Key k="d" label="½ page down" run={() => keyMove($, halfPage)} />
              <Key k="u" label="½ page up" run={() => keyMove($, -halfPage)} />
              <Key k="g" label="top" run={() => keyMove($, -Infinity)} />
            </Box>
            <Box columnGap={2} flexWrap="wrap">
              <Text bold>Jump   </Text>
              <Key k="n" label="next hunk" run={() => keyHunk($, 1)} />
              <Key k="p" label="prev hunk" run={() => keyHunk($, -1)} />
              <Key k="l" label="next file" run={() => keyFile($, 1)} />
              <Key k="h" label="prev file" run={() => keyFile($, -1)} />
              <Key k="f" label="find file" run={() => keyFinder($)} />
              <Key k="e" label="next edit" run={() => keyEdit($, 1)} />
              <Key k="b" label="prev edit" run={() => keyEdit($, -1)} />
              <Key k="t" label={limit === Infinity ? 'cut long diffs' : 'whole diff'} run={() => update($, fullDiff, isWhole => !isWhole)} />
            </Box>
            <Box columnGap={2} flexWrap="wrap">
              <Text bold>Review </Text>
              <Key k="m" label={isViewed(marks, list, file) ? 'unmark viewed' : 'mark viewed'} run={() => keyViewed($)} />
              <Key k="z" label="start over on file" run={() => startOver($, file)} />
            </Box>
            <Box columnGap={2} flexWrap="wrap">
              <Text bold>Comment</Text>
              <Key k="v" label={from ? 'end range' : 'range'} run={() => keyVisual($)} />
              <Key k="c" label="comment" run={() => keyComment($)} />
              <Key k="a" label="on hunk" run={() => keyHunkComment($)} />
              <Key k="r" label="reply" run={() => keyReply($)} />
              <Key k="w" label="next open comment" run={() => keyNextComment($)} />
              <Key k="x" label="delete" run={() => keyRemove($)} />
              <Key k="q" label="cancel" run={() => keyCancel($)} />
            </Box>
            <Box columnGap={2} flexWrap="wrap">
              <Text bold>Share  </Text>
              <Key k="s" label="send to Claude" run={() => sendNow($)} />
              <Key k="o" label="open on web" run={() => openOnWeb($)} />
            </Box>
          </Box>
        </Box>

        {query !== null ? (
          // The finder: the field filters as you type; Enter or a press opens a file
          <Box flexDirection="column">
            <Input
              key="finder"
              label="Find "
              placeholder="part of a changed file's path"
              submitLabel="open"
              value={query}
              autoFocus
              onInput={(value: string) => void update($, finder, () => value)}
              onSubmit={() => void (found[0] && openFound($, found[0]))}
            />
            {found.slice(0, FINDER_SHOWN).map(p => (
              <Box key={`found:${p}`}>
                {fileRow(p, 0, false)}
                <Text dimColor>{`  ${dirOf(p)}/`}</Text>
              </Box>
            ))}
            <Text dimColor>
              {found.length === 0
                ? 'No changed file matches'
                : `${found.length > FINDER_SHOWN ? `${found.length - FINDER_SHOWN} more · ` : ''}Enter opens the first · Esc, then q closes`}
            </Text>
          </Box>
        ) : isListOpen ? (
          <Box flexDirection="column">
            {dirs.map(dir => (
              <Box key={`dir:${dir}`} flexDirection="column">
                {dirs.length > 1 && <Text dimColor>{dir}/</Text>}
                {files.filter(p => dirOf(p) === dir).map(p => fileRow(p, dirs.length > 1 ? 2 : 0))}
              </Box>
            ))}
          </Box>
        ) : (
          <Box columnGap={2} flexWrap="wrap">
            {fileRow(file, 0, false)}
            <Text dimColor>
              {placeOf(file)} · file {files.indexOf(file) + 1} of {files.length}
              {viewedCount > 0 ? ` · ${viewedCount}/${files.length} viewed` : ''}
              {pendingElsewhere > 0 ? ` · ● ${pendingElsewhere} in other files` : ''} · f find · h/l switch
            </Text>
          </Box>
        )}

        <Box flexDirection="column" gap={1}>
          {/*
            One row says what is shown: the edit tabs (`all 1 2 3+ 4$`, the shown one inverted) when there are
            several, then what the shown edit was (or the tabs' legend under "all"), and its counts at the end
          */}
          <Box justifyContent="space-between" columnGap={2}>
            <Box columnGap={1} flexWrap="wrap">
              {edits.length > 1 && (
                <Box columnGap={1} flexWrap="wrap">
                  <Text dimColor>Edits</Text>
                  <Button key="view:all" plain onPress={() => showView($, file, null)}>
                    <Tab isOn={!chosen}>all</Tab>
                  </Button>
                  {editWindow(edits.length, chosen ? edits.indexOf(chosen) : -1).map((i, k) => {
                    const c = i === null ? undefined : edits[i]
                    if (i === null || !c) return <Text key={`gap:${k}`} dimColor>…</Text>
                    return (
                      <Button key={`view:${c.id}`} plain onPress={() => showView($, file, c.id)}>
                        <Tab isOn={chosen === c}>{`${i + 1}${c.tool === 'Bash' ? '$' : isCreate(c.diff) ? '+' : ''}`}</Tab>
                      </Button>
                    )
                  })}                </Box>
              )}
              {chosen ? (
                // A plain edit needs no word beside its tab; one Bash made, a creation or a move does
                (chosen.tool === 'Bash' || chosen.renamedFrom || isCreate(chosen.diff)) && <Text dimColor>{` ${describe(chosen)}`}</Text>
              ) : edits.length > 1 ? (
                legend.length > 0 && <Text dimColor>{` ${legend.join(' · ')}`}</Text>
              ) : (
                edits[0] && <Text bold>{describe(edits[0])}</Text>
              )}
            </Box>
            {chosen && (
              <Box flexShrink={0}>
                <Counts {...tally([chosen.diff])} />
              </Box>
            )}
          </Box>
          {shown.map(renderChange)}
        </Box>

        <Box flexDirection="column">
          {fileNotes.length > 0 && <Text bold>Notes on the whole file</Text>}
          {fileNotes.map(n => thread(n, 0))}
          {outdated.length > 0 && <Text dimColor>Outdated: their lines changed since, so they are no longer in the diff</Text>}
          {outdated.map(n => thread(n, 0))}
          <Input
            key="comment"
            placeholder="Note on the whole file (12-20: for lines)"
            submitLabel="add"
            value=""
            onSubmit={(value: string) => void addFileComment($, file, value)}
          />
        </Box>

        {/* Only what applies now: send when something is pending, clear when something was sent */}
        <Box columnGap={1} flexWrap="wrap" alignItems="center">
          {pending.length > 0 && (
            <Button key="send" variant="primary" label={`Send ${plural(pending.length, 'comment')} to Claude`} onPress={() => void sendNow($)} />
          )}
          {notes.some(c => c.status === 'sent') && (
            <Button key="clear" label="Clear sent" onPress={() => update($, comments, all => all.filter(c => c.status !== 'sent'))} />
          )}
          <Button key="startover" label="Start over" onPress={() => startOver($, null)} />
          {pending.length > 0 && <Text dimColor>or they go with your next message</Text>}
        </Box>
      </Box>
    )
  })
}
