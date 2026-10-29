import { expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

/** A prompt as typed at the composer */
const asTyped = (text: string) => ({ text, wait: false, origin: { kind: 'composer' } as const })
/** The engine's answers to the pane moving its focus ring and scrolling, which no test looks at */
const focused = () => ({})
const scrolled = () => ({})
/** A finished process, as `$.process.run` resolves */
const exited = (exitCode: number, stdout: string, stderr = '') => ({
  value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false },
})

const PANE = {
  plugin: 'review-pane',
  component: 'Pane',
  requestId: 'review',
  props: {
    title: 'Review',
    isFocused: true,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const EDIT = {
  filePath: '/tmp/demo/keymaps.lua',
  oldString: 'a',
  newString: 'b',
  originalFile: null, // before unknown: the pane falls back to showing each edit
  userModified: false,
  replaceAll: false,
  structuredPatch: [
    {
      oldStart: 3,
      oldLines: 2,
      newStart: 3,
      newLines: 4,
      lines: [' local map = vim.keymap.set', '+map("n", "<C-j>", "<C-w>j")', '+map("n", "<C-k>", "<C-w>k")', ' map("n", "<C-l>", "<C-w>l")'],
    },
  ],
}

test('a comment on a picked line range reaches the next prompt', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.focus', focused)
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: EDIT }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: EDIT.filePath, old_string: 'a', new_string: 'b' })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /keymaps\.lua/ }))?.text).toContain('keymaps.lua')
    await ui.unmount()
  }

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const lines = (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  expect(lines.length).toBe(4)

  await $.ui.press({ plugin: 'review-pane', key: lines[1]! })
  await $.ui.press({ plugin: 'review-pane', key: lines[2]! })
  const typed = await $.prompt.submit(asTyped('use wincmd here'))
  expect(typed.drop).toContain('keymaps.lua L4-5')
  expect((await ui.find({ type: 'Text', text: /use wincmd here/ }))?.text).toBe('use wincmd here')
  await ui.unmount()

  const sent = await $.prompt.submit(asTyped('hi'))
  const note = sent.context?.join('\n') ?? ''
  expect(note).toContain('keymaps.lua L4-5')
  expect(note).toContain('+map("n", "<C-j>", "<C-w>j")')
  expect(note).toContain('use wincmd here')
})

test('vim keys: j moves, v starts a range, c opens the comment box on it', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', focused)
  on('ui.scroll', scrolled)
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: EDIT }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: EDIT.filePath, old_string: 'a', new_string: 'b' })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await $.ui.press({ plugin: 'review-pane', key: 'key:j' })
  await $.ui.press({ plugin: 'review-pane', key: 'key:v' })
  await $.ui.press({ plugin: 'review-pane', key: 'key:j' })
  await $.ui.press({ plugin: 'review-pane', key: 'key:c' })
  expect((await ui.find({ type: 'Text', text: /on L4-5/ }))?.text).toContain('L4-5')
  expect((await $.prompt.submit(asTyped('pair these'))).drop).toContain('L4-5')
  await ui.unmount()

  const sent = await $.prompt.submit(asTyped('hi'))
  expect(sent.context?.join('\n') ?? '').toContain('keymaps.lua L4-5')
})

test('o publishes a new page on first use, remembers it, and updates it after', async ($, on) => {
  const calls: Record<string, unknown>[] = []
  const opened: string[][] = []
  const store = new Map<string, unknown>()
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.toast', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/work' }))
  on('fs.read', () => ({ value: '<title>Change Review</title>' }))
  on('fs.write', () => ({ value: undefined }))
  on('store.get', (_, e) => ({ value: store.get(e.key) }))
  on('store.set', (_, e) => {
    store.set(e.key, e.value)
    return { value: undefined }
  })
  on('process.run', (_, e) => {
    if (e.argv[0] !== 'git') opened.push([...e.argv]) // git: the repo lookups for saving reviews
    return exited(0, '', '')
  })
  on('tool.call', (_, e) => {
    if (e.tool !== 'Artifact') return { result: EDIT }
    calls.push({ ...e })
    return { result: {}, text: 'Published index.html at https://claude.ai/artifact/AbC123 (Version 1)' }
  })

  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: EDIT.filePath, old_string: 'a', new_string: 'b' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })

  await $.ui.press({ plugin: 'review-pane', key: 'key:o' })
  expect(calls[0]).toMatchObject({ file_path: '/work/.claude/review-pane/index.html', capabilities: { comments: {} } })
  expect(calls[0]?.url).toBeUndefined()
  expect(store.get('webUrl')).toBe('https://claude.ai/artifact/AbC123')
  expect(opened[0]).toEqual(['open', 'https://claude.ai/artifact/AbC123'])

  await $.ui.press({ plugin: 'review-pane', key: 'key:o' })
  expect(calls[1]).toMatchObject({ url: 'https://claude.ai/artifact/AbC123' })
  expect(calls[1]?.capabilities).toBeUndefined()
  await ui.unmount()
})

test('two edits of one file show as one net diff, and e steps through each edit', async ($, on) => {
  const before = 'a\nb\nc\n'
  const after = 'a\nB\nc\nd\n'
  let edits = 0
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('fs.read', () => ({ value: after }))
  on('tool.call', () => {
    edits += 1
    const first = { oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ['-b', '+B'] }
    const second = { oldStart: 3, oldLines: 1, newStart: 3, newLines: 2, lines: [' c', '+d'] }
    return { result: { ...EDIT, filePath: '/f.txt', originalFile: edits === 1 ? before : 'a\nB\nc\n', structuredPatch: [edits === 1 ? first : second] } }
  })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: '/f.txt', old_string: 'b', new_string: 'B' })
  await $.tool.call({ tool: 'Edit', file_path: '/f.txt', old_string: 'c', new_string: 'c\nd' })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.findAll({ type: 'Button' })).some(b => b.key?.startsWith('ln:net:'))).toBe(true) // drawn as one net diff
  expect((await ui.find({ type: 'Text', text: / all / }))?.text).toBe(' all ')
  const net = (await ui.findAll({ type: 'Button' })).filter(b => b.key?.startsWith('ln:net:'))
  expect(net.length).toBe(5) // a, -b, +B, c, +d

  await $.ui.press({ plugin: 'review-pane', key: 'key:e' })
  expect((await ui.findAll({ type: 'Button' })).some(b => b.key?.startsWith('ln:net:'))).toBe(false) // one edit shown
  expect(await ui.find({ type: 'Text', text: / Edited$/ })).toBeUndefined() // a plain edit's tab says enough
  await ui.unmount()
})

test('a file edited before its "before" was saved is rebuilt by undoing its edits', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  // the file now: both edits in, and a later line no recorded edit made
  on('fs.read', () => ({ value: 'a\nB\nc\nd\nlater\n' }))
  let n = 0
  on('tool.call', () => {
    n += 1
    const hunk = n === 1
      ? { oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ['-b', '+B'] }
      : { oldStart: 3, oldLines: 1, newStart: 3, newLines: 2, lines: [' c', '+d'] }
    return { result: { ...EDIT, filePath: '/g.txt', originalFile: null, structuredPatch: [hunk] } }
  })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: '/g.txt', old_string: 'b', new_string: 'B' })
  await $.tool.call({ tool: 'Edit', file_path: '/g.txt', old_string: 'c', new_string: 'c\nd' })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.findAll({ type: 'Button' })).some(b => b.key?.startsWith('ln:net:'))).toBe(true) // drawn as one net diff
  await ui.unmount()
})

test('a file a Bash command changes in a git repo shows up, compared with git index', async ($, on) => {
  let ran = false
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_, e) => {
    const args = e.argv.join(' ')
    const stdout = args.includes('rev-parse')
      ? '/repo\n'
      : args.includes(' status ')
        ? ran ? ' M a.txt\0?? new.txt\0' : '' // clean before the command
        : args.includes(' show :a.txt') ? 'one\ntwo\n' : ''
    return exited(args.includes(' show :new.txt') ? 128 : 0, stdout)
  })
  on('fs.read', (_, e) => ({ value: e.path === '/repo/a.txt' ? 'one\nTWO\n' : 'hello\n' }))
  on('tool.call', () => {
    ran = true
    return { result: { stdout: '', stderr: '' } }
  })

  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: "sed -i '' s/two/TWO/ a.txt && echo hello > new.txt" })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /a\.txt/ }))?.text).toContain('a.txt')
  expect((await ui.find({ type: 'Text', text: /new\.txt/ }))?.text).toContain('new.txt')
  const rows = (await ui.findAll({ type: 'Button' })).filter(b => b.key?.startsWith('ln:'))
  expect(rows.length).toBe(3) // one, -two, +TWO
  await ui.unmount()
})

test('outside git, a Bash command changing a file Claude edited is tracked too', async ($, on) => {
  let content = 'a\nB\nc\n'
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/plain' }))
  on('process.run', () => exited(128, '', 'not a git repository'))
  on('fs.read', () => ({ value: content }))
  on('tool.call', (_, e) => {
    if (e.tool === 'Bash') {
      content = 'a\nB\nc\nd\n'
      return { result: { stdout: '', stderr: '' } }
    }
    return { result: { ...EDIT, filePath: '/plain/f.txt', originalFile: 'a\nb\nc\n', structuredPatch: [{ oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ['-b', '+B'] }] } }
  })

  await $.session.start({ cwd: '/plain', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: '/plain/f.txt', old_string: 'b', new_string: 'B' })
  await $.tool.call({ tool: 'Bash', command: 'echo d >> f.txt' })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.findAll({ type: 'Button' })).some(b => b.key?.startsWith('ln:net:'))).toBe(true) // drawn as one net diff
  expect((await ui.find({ type: 'Text', text: /by Bash/ }))?.text).toContain('by Bash')
  await ui.unmount()
})

test('Claude answers a sent comment with the reply tool, and the pane shows it', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('tool.register', () => ({ value: { tool: 'mcp__review-pane__reply' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', focused)
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: EDIT }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: EDIT.filePath, old_string: 'a', new_string: 'b' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const lines = (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  await $.ui.press({ plugin: 'review-pane', key: lines[1]! })
  await $.prompt.submit(asTyped('use wincmd here'))

  const sent = (await $.prompt.submit(asTyped('hi'))).context?.join('\n') ?? ''
  const id = sent.match(/- \[([^\]]+)\]/)?.[1]
  expect(id).toBeTruthy()
  expect(sent).toContain('mcp__review-pane__reply')

  const missing = await $.tool.call({ tool: 'mcp__review-pane__reply', commentId: 'nope', text: 'x' })
  expect(missing.deny).toContain('No review comment')

  const answered = await $.tool.call({ tool: 'mcp__review-pane__reply', commentId: id!, text: 'Switched to wincmd.', resolved: true })
  expect(answered.deny).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Switched to wincmd/ }))?.text).toContain('Switched to wincmd.')
  expect((await ui.find({ type: 'Text', text: /resolved/ }))?.text).toContain('resolved')
  await ui.unmount()
})

test('after Claude replies, r continues the discussion and the next prompt carries it', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('tool.register', () => ({ value: { tool: 'mcp__review-pane__reply' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', focused)
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: EDIT }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: EDIT.filePath, old_string: 'a', new_string: 'b' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const lines = (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  await $.ui.press({ plugin: 'review-pane', key: lines[1]! })
  await $.prompt.submit(asTyped('use wincmd here'))
  const first = (await $.prompt.submit(asTyped('hi'))).context?.join('\n') ?? ''
  const id = first.match(/- \[([^\]]+)\]/)![1]!
  await $.tool.call({ tool: 'mcp__review-pane__reply', commentId: id, text: 'Done, switched to wincmd.', resolved: true })

  // the cursor still sits on the commented line: r opens the reply box on its discussion
  await $.ui.press({ plugin: 'review-pane', key: 'key:r' })
  expect((await ui.find({ type: 'Text', text: /type it in the prompt/ }))?.text).toContain('Esc')
  const typed = await $.prompt.submit(asTyped('also for <C-h>?'))
  expect(typed.drop).toContain('Reply added')
  expect((await ui.find({ type: 'Text', text: /1 pending/ }))?.text).toContain('1 pending')

  const second = (await $.prompt.submit(asTyped('next'))).context?.join('\n') ?? ''
  expect(second).toContain(`[${id}]`)
  expect(second).toContain('continued discussion')
  expect(second).toContain('You (Claude): Done, switched to wincmd.')
  expect(second).toContain('User: also for <C-h>?')

  // sent once: the prompt after that carries nothing
  expect((await $.prompt.submit(asTyped('again'))).context ?? []).toEqual([])
  await ui.unmount()
})

test('past six files the list folds to the open file, and f finds one fuzzily', async ($, on) => {
  const paths = ['/w/a/one.lua', '/w/a/two.lua', '/w/b/three.lua', '/w/b/four.lua', '/w/c/five.lua', '/w/c/six.lua', '/w/c/seven.lua']
  let n = 0
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: { ...EDIT, filePath: paths[n++]! } }))

  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  for (const p of paths) await $.tool.call({ tool: 'Edit', file_path: p, old_string: 'a', new_string: 'b' })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /file 1 of 7/ }))?.text).toContain('a/')
  expect(await ui.find({ type: 'Text', text: /seven\.lua/ })).toBeUndefined()

  await $.ui.press({ plugin: 'review-pane', key: 'key:f' })
  expect((await ui.find({ type: 'Text', text: /seven\.lua/ }))?.text).toContain('seven.lua') // empty query: every file

  await $.ui.input({ plugin: 'review-pane', key: 'finder', text: 'csev', kind: 'change' })
  expect((await ui.find({ type: 'Text', text: /seven\.lua/ }))?.text).toContain('seven.lua')
  expect(await ui.find({ type: 'Text', text: /three\.lua/ })).toBeUndefined()

  await $.ui.input({ plugin: 'review-pane', key: 'finder', text: 'csev' }) // Enter opens the top match
  expect((await ui.find({ type: 'Text', text: /file 6 of 7/ }))?.text).toContain('c/') // c/seven.lua, sorted by path
  expect(await ui.find({ type: 'Text', text: /Enter opens the first/ })).toBeUndefined() // the finder closed
  await ui.unmount()
})

/** A session on /f.txt whose edits each set the file's text and report the patch that made it */
function editsOn(on: Parameters<TestBody>[1], steps: { text: string; before: string; hunk: object }[]) {
  let n = 0
  let text = steps[0]!.before
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', focused)
  on('ui.toast', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1_700_000_000_000 + n }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('fs.read', () => ({ value: text }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))
  on('tool.call', () => {
    const step = steps[n++]!
    text = step.text
    return { result: { ...EDIT, filePath: '/f.txt', originalFile: step.before, structuredPatch: [step.hunk] } }
  })
  return () => $edit
}
const $edit = { tool: 'Edit', file_path: '/f.txt', old_string: 'a', new_string: 'b' } as const

test('a comment on the net diff follows its line through later edits, and is outdated once the line is gone', async ($, on) => {
  editsOn(on, [
    { before: 'a\nb\nc\n', text: 'a\nB\nc\n', hunk: { oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ['-b', '+B'] } },
    { before: 'a\nB\nc\n', text: 'x\na\nB\nc\n', hunk: { oldStart: 1, oldLines: 1, newStart: 1, newLines: 2, lines: ['+x', ' a'] } },
    { before: 'x\na\nB\nc\n', text: 'x\na\nb\nc\n', hunk: { oldStart: 3, oldLines: 1, newStart: 3, newLines: 1, lines: ['-B', '+b'] } },
  ])
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call($edit)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const rows = (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  await $.ui.press({ plugin: 'review-pane', key: rows[2]! }) // +B
  await $.prompt.submit(asTyped('why capital?'))

  await $.tool.call($edit) // a line added above: the comment moves down with +B
  expect((await ui.find({ type: 'Text', text: /why capital/ }))?.text).toBe('why capital?')
  expect(await ui.find({ type: 'Text', text: /Outdated/ })).toBeUndefined()

  await $.tool.call($edit) // B undone: the commented line is not in the diff any more
  expect((await ui.find({ type: 'Text', text: /Outdated/ }))?.text).toContain('Outdated')
  expect((await ui.find({ type: 'Text', text: /why capital/ }))?.text).toBe('why capital?')
  await ui.unmount()
})

test('m marks a file viewed until Claude changes it again, and z starts the file over once nothing is pending', async ($, on) => {
  editsOn(on, [
    { before: 'a\nb\n', text: 'a\nB\n', hunk: { oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ['-b', '+B'] } },
    { before: 'a\nB\n', text: 'a\nB\nc\n', hunk: { oldStart: 2, oldLines: 1, newStart: 2, newLines: 2, lines: [' B', '+c'] } },
  ])
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call($edit)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })

  await $.ui.press({ plugin: 'review-pane', key: 'key:m' })
  expect((await ui.find({ type: 'Text', text: /1\/1 viewed/ }))?.text).toContain('viewed')
  await $.tool.call($edit)
  expect(await ui.find({ type: 'Text', text: /1\/1 viewed/ })).toBeUndefined()

  await ui.unmount()
  const again = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const rows = (await again.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  await $.ui.press({ plugin: 'review-pane', key: rows[1]! })
  await $.prompt.submit(asTyped('pending one'))
  await $.ui.press({ plugin: 'review-pane', key: 'key:z' })
  expect((await again.find({ type: 'Text', text: /f\.txt/ }))?.text).toContain('f.txt') // refused: a comment is pending

  await $.prompt.submit(asTyped('send it'))
  await $.ui.press({ plugin: 'review-pane', key: 'key:z' })
  expect((await again.find({ type: 'Text', text: /Nothing to review yet/ }))?.text).toContain('Nothing to review')
  await again.unmount()
})

test('a long diff is cut at 300 rows until t, and a file Bash moved shows as moved', async ($, on) => {
  const big = Array.from({ length: 400 }, (_, i) => `line ${i}`).join('\n') + '\n'
  let ran = false
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', focused)
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_, e) => {
    const args = e.argv.join(' ')
    if (args.includes('rev-parse')) return exited(0, '/repo\n', '')
    if (args.includes(' status ')) return exited(0, ran ? ' D old.txt\0?? big.txt\0?? new.txt\0' : '', '')
    if (args.includes(' show :old.txt')) return exited(0, 'same\ntext\n', '')
    return exited(128, '', '')
  })
  on('fs.read', (_, e) => {
    if (e.path === '/repo/big.txt') return { value: big }
    if (e.path === '/repo/new.txt') return { value: 'same\ntext\n' }
    throw new Error('ENOENT')
  })
  on('tool.call', () => {
    ran = true
    return { result: { stdout: '', stderr: '' } }
  })

  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'seq 0 399 > big.txt && git mv old.txt new.txt' })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /old\.txt/ })).toBeUndefined() // the move is one file, not a deletion
  expect((await ui.find({ type: 'Text', text: /more rows? not drawn/ }))?.text).toContain('t draws')
  await $.ui.press({ plugin: 'review-pane', key: 'key:t' })
  expect(await ui.find({ type: 'Text', text: /not drawn/ })).toBeUndefined()

  await $.ui.press({ plugin: 'review-pane', key: 'key:l' })
  expect((await ui.find({ type: 'Text', text: /from old\.txt/ }))?.text).toContain('old.txt')
  await ui.unmount()
})

test('a new session in the same folder picks up the last review', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('store.get', (_, e) =>
    e.key === 'review:/proj'
      ? { value: { changes: [{ id: 'k1', file: '/proj/kept.lua', tool: 'Edit', diff: '@@ -1,1 +1,1 @@\n-a\n+b', at: 1 }], comments: [], viewed: {}, baselines: {} } }
      : { value: undefined },
  )
  on('store.keys', () => ({ value: ['review:/proj', 'review:/elsewhere'] }))
  on('fs.read', () => ({ value: 'b\n' }))

  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /kept\.lua/ }))?.text).toContain('kept.lua')
  await ui.unmount()
})

test('each repository keeps its own saved review', async ($, on) => {
  const saved = new Map<string, unknown>()
  const paths = ['/proj/lib/a.lua', '/home/me/.config/b.lua']
  let n = 0
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/proj' }))
  on('store.keys', () => ({ value: [] }))
  on('store.set', (_, e) => {
    saved.set(e.key, e.value)
    return { value: undefined }
  })
  // /proj is a git repository; the config folder is in none
  on('process.run', (_, e) => (e.argv.join(' ').includes('/proj') ? exited(0, '/proj\n') : exited(128, '', 'not a git repository')))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))
  on('tool.call', () => ({ result: { ...EDIT, filePath: paths[n++]! } }))

  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  for (const p of paths) await $.tool.call({ tool: 'Edit', file_path: p, old_string: 'a', new_string: 'b' })
  await $.prompt.submit(asTyped('hi'))

  const filesIn = (key: string) => ((saved.get(key) as { changes: { file: string }[] }).changes ?? []).map(c => c.file)
  expect([...saved.keys()].sort()).toEqual(['review:/home/me/.config', 'review:/proj'])
  expect(filesIn('review:/proj')).toEqual(['/proj/lib/a.lua'])
  expect(filesIn('review:/home/me/.config')).toEqual(['/home/me/.config/b.lua'])
})

test('undo still works when lines were added later inside an edited block', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  // the edit added "y" between "x" and "}"; later "z" was added between "y" and "}"
  on('fs.read', () => ({ value: '{\nx\ny\nz\n}\n' }))
  on('tool.call', () => ({
    result: { ...EDIT, filePath: '/h.txt', originalFile: null, structuredPatch: [{ oldStart: 1, oldLines: 3, newStart: 1, newLines: 4, lines: [' {', ' x', '+y', ' }'] }] },
  }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: '/h.txt', old_string: 'x', new_string: 'x\ny' })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.findAll({ type: 'Button' })).some(b => b.key?.startsWith('ln:net:'))).toBe(true) // drawn as one net diff
  await ui.unmount()
})

test('w jumps to the next open comment across files and puts the cursor on it', async ($, on) => {
  const toasts: string[] = []
  const paths = ['/w/a.lua', '/w/b.lua']
  let n = 0
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', focused)
  on('ui.scroll', scrolled)
  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))
  on('tool.call', () => ({ result: { ...EDIT, filePath: paths[n++]! } }))

  await $.session.start({ cwd: '/w', surface: 'terminal', isInteractive: true })
  for (const p of paths) await $.tool.call({ tool: 'Edit', file_path: p, old_string: 'a', new_string: 'b' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })

  // a comment on b.lua's second line, while a.lua is open
  await $.ui.press({ plugin: 'review-pane', key: 'key:l' })
  const rows = (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  await $.ui.press({ plugin: 'review-pane', key: rows[1]! })
  await $.prompt.submit(asTyped('look here'))
  await $.ui.press({ plugin: 'review-pane', key: 'key:h' })

  await $.ui.press({ plugin: 'review-pane', key: 'key:w' })
  expect(toasts.at(-1)).toBe('Open comment 1 of 1')
  expect((await ui.find({ type: 'Text', text: /b\.lua/ }))?.text).toContain('b.lua')
  expect((await ui.find({ type: 'Text', text: /▸/ }))).toBeDefined()
  await ui.unmount()
})

test('a hunk separator names the function or section the hunk sits in', async ($, on) => {
  const now = 'package x\n\n// --- Behaviors ---\nfunc (b Behavior) Try() {\n\ta := 1\n\tb := 2\n\treturn\n}\n'
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('fs.read', () => ({ value: now }))
  on('tool.call', () => ({
    result: { ...EDIT, filePath: '/x.go', originalFile: now.replace('b := 2', 'b := 3'), structuredPatch: [{ oldStart: 5, oldLines: 3, newStart: 5, newLines: 3, lines: ['\ta := 1', '-\tb := 3', '+\tb := 2', '\treturn'] }] },
  }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: '/x.go', old_string: 'b := 3', new_string: 'b := 2' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /⋯ line/ }))?.text).toContain('· func (b Behavior) Try()')
  await ui.unmount()
})

test('a long comment heading is named without its aside, and cut with …', async ($, on) => {
  const now = '# --- Language servers (vim.lsp.enable in plugin/nvim-lspconfig.lua) ---\nbrew_install a\nbrew_install b\nbrew_install c\nbrew_install d\n'
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('fs.read', () => ({ value: now }))
  on('tool.call', () => ({
    result: { ...EDIT, filePath: '/setup.sh', originalFile: now.replace('install d', 'install e'), structuredPatch: [{ oldStart: 4, oldLines: 2, newStart: 4, newLines: 2, lines: [' brew_install c', '-brew_install e', '+brew_install d'] }] },
  }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: '/setup.sh', old_string: 'e', new_string: 'd' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /⋯ line/ }))?.text).toMatch(/· Language servers$/)
  await ui.unmount()
})
