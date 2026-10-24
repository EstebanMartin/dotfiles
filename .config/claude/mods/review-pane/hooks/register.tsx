import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderElement } from 'claude-code'

import type { Change, ReviewComment, RowRef, Selection } from '../types'

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

let counter = 0
const newId = (now: number) => `${now.toString(36)}-${(counter += 1)}`
/** What the open comment box holds, for its Add button; typing never redraws */
let draft = ''

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
  return diff === null ? null : { id: `net:${file}`, file, tool: 'Edit', diff, at: edits[edits.length - 1]!.at }
}

// ─── The open file and the cursor ───────────────────────────────────────────

const rowKey = (ref: RowRef) => `ln:${ref.changeId}:${ref.row}`
const sameRow = (a: RowRef | null, b: RowRef) => a !== null && a.changeId === b.changeId && a.row === b.row

/** The open file, what the pane shows of it, its lines in order, and the cursor resolved to one of them */
async function openFile($: EngineInterface) {
  const list = await read($, changes)
  const files = [...new Set(list.map(c => c.file))]
  const current = await read($, selected)
  const file = current && files.includes(current) ? current : files[0]
  const edits = list.filter(c => c.file === file)
  const view = await read($, edit)
  const chosen = edits.find(c => c.id === view)
  const net = chosen || !file ? null : await netChangeOf($, file, edits)
  // The one edit picked, else the net change, else every edit when the net cannot be told
  const shown = chosen ? [chosen] : net ? [net] : edits

  const lines: RowRef[] = []
  const hunkStarts: number[] = []
  for (const change of shown) {
    toRows(change.diff).forEach((row, i) => {
      if (row.kind === 'hunk') hunkStarts.push(lines.length)
      else lines.push({ changeId: change.id, row: i })
    })
  }
  const at = await read($, cursor)
  const index = Math.max(0, at ? lines.findIndex(l => sameRow(at, l)) : 0)
  return { list, files, file, edits, chosen, shown, lines, hunkStarts, index, here: lines[index] ?? null }
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
  draft = ''
  await update($, visual, () => null)
  await update($, selection, () => next)
  try {
    await $.ui.focus({ requestId: PANE, key: 'inline' })
  } catch {
    // the field draws on the next pass with autoFocus
  }
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

async function keyFile($: EngineInterface, dir: 1 | -1) {
  const { files, file } = await openFile($)
  await showView($, files[(files.indexOf(file ?? '') + dir + files.length) % files.length] ?? null, null)
  await keyMove($, 0)
}

async function keyEdit($: EngineInterface) {
  const { file, edits, chosen } = await openFile($)
  const order = [null, ...edits.map(c => c.id)]
  await showView($, file ?? null, order[(order.indexOf(chosen?.id ?? null) + 1) % order.length] ?? null)
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

async function keyRemove($: EngineInterface) {
  const { here } = await openFile($)
  if (!here) return
  const isOnHere = (c: ReviewComment) =>
    c.status === 'pending' && c.changeId === here.changeId && !!c.rows && here.row >= c.rows[0] && here.row <= c.rows[1]
  const target = (await read($, comments)).findLast(isOnHere)
  if (target) await update($, comments, list => list.filter(c => c.id !== target.id))
}

async function keyCancel($: EngineInterface) {
  await update($, visual, () => null)
  await update($, selection, () => null)
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

function asMessage(list: readonly ReviewComment[]): string {
  const parts = list.map(c => {
    const where = c.lines ? `${c.file} ${whereOf(c)}` : `${c.file} (whole file)`
    const code = c.snippet?.length ? `\n  \`\`\`diff\n${c.snippet.map(l => `  ${l}`).join('\n')}\n  \`\`\`` : ''
    return `- ${where}:${code}\n  ${c.text}`
  })
  return ['Review comments left in the review pane on files you changed. Address each one:', ...parts].join('\n')
}

async function takePending($: EngineInterface): Promise<ReviewComment[]> {
  const pending = (await read($, comments)).filter(c => c.status === 'pending')
  if (pending.length > 0) await update($, comments, list => list.map(c => ({ ...c, status: 'sent' as const })))
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
  draft = ''
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

// ─── Hooks ──────────────────────────────────────────────────────────────────

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'review-pane',
      description: 'Open the review pane: files Claude changed, their diffs, and your comments',
    })
    return next(e)
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
    const pending = await takePending($)
    return pending.length === 0 ? next(e) : next({ ...e, context: [...(e.context ?? []), asMessage(pending)] })
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    if (!('Input' in ui)) {
      const { Text } = ui
      return <Text dimColor>Open the review pane in the terminal or desktop app to leave comments.</Text>
    }
    const { Box, Text, Button, Input, Code } = ui
    const { list, files, file, edits, chosen, shown, here } = await openFile($)
    const notes = await read($, comments)
    const sel = await read($, selection)
    const from = await read($, visual)
    const isKeysOpen = await read($, showKeys)
    const pending = notes.filter(c => c.status === 'pending')
    const rule = <Text dimColor>{'─'.repeat(Math.max(20, e.props.bodyColumns))}</Text>
    const halfPage = Math.max(1, Math.floor(e.props.scroll.bodyRows / 2))

    if (!file) {
      return (
        <Box flexDirection="column" paddingY={1} gap={1}>
          <Text bold>Nothing to review yet</Text>
          <Text dimColor>Files Claude creates or edits in this session show up here as diffs you can comment on.</Text>
        </Box>
      )
    }

    const width = Math.max(2, ...shown.flatMap(c => toRows(c.diff).map(r => String(Math.max(r.oldN ?? 0, r.newN ?? 0)).length)))
    const pad = (n?: number) => String(n ?? '').padStart(width)
    const gutter = width * 2 + 4

    /** Rows shown as picked: the open comment box's, or the visual range from `v` to the cursor */
    const pickedIn = (changeId: string): Selection | null => {
      if (sel?.changeId === changeId) return sel
      if (from?.changeId === changeId && here?.changeId === changeId) {
        return { changeId, from: Math.min(from.row, here.row), to: Math.max(from.row, here.row) }
      }
      return null
    }

    const Counts = ({ add, del }: { add: number; del: number }) => (
      <Text>
        <Text color="diffAdded">+{add}</Text> <Text color="diffRemoved">−{del}</Text>
      </Text>
    )

    /** One shortcut: drawn as `j: down`, pressed by its letter while the pane has the keyboard */
    const Key = ({ k, label, run }: { k: string; label: string; run: () => unknown }) => (
      <Button key={`key:${k}`} plain hotkey={k} onPress={() => void run()}>
        <Text dimColor>{label}</Text>
      </Button>
    )

    /** A marker and a label, for the open file and the edit shown */
    const Choice = ({ isOn, children }: { isOn: boolean; children: string }) => (
      <Text>
        <Text color={isOn ? 'claude' : 'inactive'}>{isOn ? '▸ ' : '  '}</Text>
        <Text bold={isOn} dimColor={!isOn}>
          {children}
        </Text>
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
              <Text color={isSent ? 'success' : 'warning'}>{isSent ? '✓ sent' : '◷ pending'}</Text>
            </Text>
            {!isSent && (
              <Button key={`del:${c.id}`} plain dimColor label="delete" onPress={() => update($, comments, all => all.filter(o => o.id !== c.id))} />
            )}
          </Box>
          <Text dimColor={isSent}>{c.text}</Text>
        </Box>
      )
    }

    const composer = (change: Change, open: Selection) => (
      <Box key={`compose:${change.id}`} marginLeft={gutter} flexDirection="column" borderStyle="round" borderColor="claude" paddingX={1}>
        <Text>
          <Text bold>New comment</Text>
          <Text dimColor> on {whereOf(spanOf(toRows(change.diff), open))} · Enter adds it, Esc leaves the box</Text>
        </Text>
        <Input
          key="inline"
          placeholder="Leave a comment"
          submitLabel="add comment"
          autoFocus
          rows={2}
          value=""
          onInput={(value: string) => {
            draft = value
          }}
          onSubmit={(value: string) => void addLineComment($, change, open, value)}
        />
        <Box gap={1}>
          <Button key="addinline" variant="primary" label="Add comment" onPress={() => void addLineComment($, change, open, draft)} />
          <Button key="cancel" label="Cancel" onPress={() => void keyCancel($)} />
        </Box>
      </Box>
    )

    const renderChange = (change: Change) => {
      const rows = toRows(change.diff)
      const picked = pickedIn(change.id)
      const threads = notes.filter(n => n.changeId === change.id)
      const isCommented = (i: number) => threads.some(n => n.rows && i >= n.rows[0] && i <= n.rows[1])
      const isNet = change.id.startsWith('net:')

      const out: RenderElement[] = []
      rows.forEach((row, i) => {
        if (row.kind === 'hunk') {
          const last = rows.findLastIndex(r => r.hunk === row.hunk)
          out.push(
            <Box key={`hunk:${change.id}:${i}`} justifyContent="space-between">
              <Text color="subtle"> {row.text}</Text>
              <Button key={`hunkbtn:${change.id}:${i}`} plain onPress={() => openComposer($, { changeId: change.id, from: i + 1, to: last })}>
                <Text color="suggestion">+ comment on hunk </Text>
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
                  {isCursor ? '❯' : isPicked ? '▌' : isCommented(i) ? '●' : ' '}
                </Text>
                <Text inverse={isPicked} color={isPicked ? 'suggestion' : isCursor ? 'claude' : undefined} dimColor={!isPicked && !isCursor} bold={isCursor}>
                  {pad(row.oldN)} {pad(row.newN)}
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
        for (const n of threads) if (n.rows?.[1] === i) out.push(thread(n, gutter))
      })

      return (
        <Box key={`change:${change.id}`} flexDirection="column" borderStyle="round" borderColor="inactive">
          <Box justifyContent="space-between" paddingX={1}>
            <Text>
              <Text bold>{isNet ? 'All changes' : isCreate(change.diff) ? 'Created' : 'Edited'}</Text>
              <Text dimColor>
                {isNet ? ` · ${plural(edits.length, 'edit')} as one diff` : ` · edit ${edits.indexOf(change) + 1} of ${edits.length}`}
              </Text>
            </Text>
            <Counts {...tally([change.diff])} />
          </Box>
          {rows.length === 0 ? <Text dimColor> No net change: the file is back to how it was.</Text> : out}
        </Box>
      )
    }

    return (
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
                <Counts {...tally(list.map(c => c.diff))} />
                <Text dimColor> · </Text>
                <Text color={pending.length > 0 ? 'warning' : 'inactive'}>{pending.length} pending</Text>
              </Text>
            </Box>
          </Box>
          <Box columnGap={2} flexWrap="wrap">
            <Key k="i" label={isKeysOpen ? 'hide keys' : 'keys'} run={() => update($, showKeys, open => !open)} />
            {!isKeysOpen && <Text dimColor>j/k move · v range · c comment · s send</Text>}
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
              <Key k="e" label="next edit" run={() => keyEdit($)} />
            </Box>
            <Box columnGap={2} flexWrap="wrap">
              <Text bold>Comment</Text>
              <Key k="v" label={from ? 'end range' : 'range'} run={() => keyVisual($)} />
              <Key k="c" label="comment" run={() => keyComment($)} />
              <Key k="a" label="on hunk" run={() => keyHunkComment($)} />
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

        <Box flexDirection="column">
          {files.map(path => {
            const noted = notes.filter(c => c.file === path && c.status === 'pending').length
            return (
              <Button key={`file:${path}`} plain onPress={() => showView($, path, null)}>
                <Choice isOn={path === file}>{path.split('/').pop() ?? path}</Choice>
                <Text dimColor>  {path.split('/').slice(-3, -1).join('/')}  </Text>
                <Counts {...tally(list.filter(c => c.file === path).map(c => c.diff))} />
                {noted > 0 && <Text color="warning">  ● {noted}</Text>}
              </Button>
            )
          })}
        </Box>
        {rule}

        <Box flexDirection="column" gap={1}>
          {edits.length > 1 && (
            <Box columnGap={2} flexWrap="wrap">
              <Button key="view:all" plain onPress={() => showView($, file, null)}>
                <Choice isOn={!chosen}>All changes</Choice>
              </Button>
              {edits.map((c, i) => (
                <Button key={`view:${c.id}`} plain onPress={() => showView($, file, c.id)}>
                  <Choice isOn={chosen === c}>{`Edit ${i + 1}`}</Choice>
                  <Text dimColor> {isCreate(c.diff) ? 'created' : 'edited'}</Text>
                </Button>
              ))}
            </Box>
          )}
          {shown.map(renderChange)}
        </Box>

        <Box flexDirection="column">
          <Text bold>File comments</Text>
          {notes.filter(c => c.file === file && !c.changeId).map(n => thread(n, 0))}
          <Input
            key="comment"
            placeholder="Add a note on the whole file (12-20: also works)"
            submitLabel="add"
            value=""
            onSubmit={(value: string) => void addFileComment($, file, value)}
          />
        </Box>
        {rule}

        <Box justifyContent="space-between" flexWrap="wrap" gap={1}>
          <Box gap={1}>
            <Button
              key="send"
              variant="primary"
              label={pending.length === 0 ? 'Nothing to send' : `Send ${plural(pending.length, 'comment')} to Claude`}
              onPress={() => void sendNow($)}
            />
            <Button key="clear" label="Clear sent" onPress={() => update($, comments, all => all.filter(c => c.status !== 'sent'))} />
          </Box>
          <Text dimColor>Pending comments also ride along with your next message.</Text>
        </Box>
      </Box>
    )
  })
}
