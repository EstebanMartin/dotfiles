import { expect, test } from 'claude-code/testing'

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
  on('ui.focus', () => ({ value: undefined }))
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
  const typed = await $.prompt.submit({ text: 'use wincmd here' })
  expect(typed.drop).toContain('keymaps.lua L4-5')
  expect((await ui.find({ type: 'Text', text: /use wincmd here/ }))?.text).toBe('use wincmd here')
  await ui.unmount()

  const sent = await $.prompt.submit({ text: 'hi' })
  const note = sent.context?.join('\n') ?? ''
  expect(note).toContain('keymaps.lua L4-5')
  expect(note).toContain('+map("n", "<C-j>", "<C-w>j")')
  expect(note).toContain('use wincmd here')
})

test('vim keys: j moves, v starts a range, c opens the comment box on it', async ($, on) => {
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', () => ({ value: undefined }))
  on('ui.scroll', () => ({ value: {} }))
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
  expect((await $.prompt.submit({ text: 'pair these' })).drop).toContain('L4-5')
  await ui.unmount()

  const sent = await $.prompt.submit({ text: 'hi' })
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
    opened.push([...e.argv])
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
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
    return { value: { exitCode: args.includes(' show :new.txt') ? 128 : 0, stdout, stderr: '' } }
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
  on('process.run', () => ({ value: { exitCode: 128, stdout: '', stderr: 'not a git repository' } }))
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
  on('ui.focus', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: EDIT }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: EDIT.filePath, old_string: 'a', new_string: 'b' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const lines = (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  await $.ui.press({ plugin: 'review-pane', key: lines[1]! })
  await $.prompt.submit({ text: 'use wincmd here' })

  const sent = (await $.prompt.submit({ text: 'hi' })).context?.join('\n') ?? ''
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
  on('ui.focus', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: EDIT }))
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Edit', file_path: EDIT.filePath, old_string: 'a', new_string: 'b' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const lines = (await ui.findAll({ type: 'Button' })).map(b => b.key).filter(k => k?.startsWith('ln:'))
  await $.ui.press({ plugin: 'review-pane', key: lines[1]! })
  await $.prompt.submit({ text: 'use wincmd here' })
  const first = (await $.prompt.submit({ text: 'hi' })).context?.join('\n') ?? ''
  const id = first.match(/- \[([^\]]+)\]/)![1]!
  await $.tool.call({ tool: 'mcp__review-pane__reply', commentId: id, text: 'Done, switched to wincmd.', resolved: true })

  // the cursor still sits on the commented line: r opens the reply box on its discussion
  await $.ui.press({ plugin: 'review-pane', key: 'key:r' })
  expect((await ui.find({ type: 'Text', text: /type it in the prompt/ }))?.text).toContain('Esc')
  const typed = await $.prompt.submit({ text: 'also for <C-h>?' })
  expect(typed.drop).toContain('Reply added')
  expect((await ui.find({ type: 'Text', text: /1 pending/ }))?.text).toContain('1 pending')

  const second = (await $.prompt.submit({ text: 'next' })).context?.join('\n') ?? ''
  expect(second).toContain(`[${id}]`)
  expect(second).toContain('continued discussion')
  expect(second).toContain('You (Claude): Done, switched to wincmd.')
  expect(second).toContain('User: also for <C-h>?')

  // sent once: the prompt after that carries nothing
  expect((await $.prompt.submit({ text: 'again' })).context ?? []).toEqual([])
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
function editsOn(on: Parameters<Parameters<typeof test>[1]>[1], steps: { text: string; before: string; hunk: object }[]) {
  let n = 0
  let text = steps[0]!.before
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', () => ({ value: undefined }))
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
  await $.prompt.submit({ text: 'why capital?' })

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
  await $.prompt.submit({ text: 'pending one' })
  await $.ui.press({ plugin: 'review-pane', key: 'key:z' })
  expect((await again.find({ type: 'Text', text: /f\.txt/ }))?.text).toContain('f.txt') // refused: a comment is pending

  await $.prompt.submit({ text: 'send it' })
  await $.ui.press({ plugin: 'review-pane', key: 'key:z' })
  expect((await again.find({ type: 'Text', text: /Nothing to review yet/ }))?.text).toContain('Nothing to review')
  await again.unmount()
})

test('a long diff is cut at 300 rows until t, and a file Bash moved shows as moved', async ($, on) => {
  const big = Array.from({ length: 400 }, (_, i) => `line ${i}`).join('\n') + '\n'
  let ran = false
  on('command.register', () => ({ value: { command: 'review-pane' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.focus', () => ({ value: undefined }))
  on('clock.now', () => ({ value: 1_700_000_000_000 }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('process.run', (_, e) => {
    const args = e.argv.join(' ')
    if (args.includes('rev-parse')) return { value: { exitCode: 0, stdout: '/repo\n', stderr: '' } }
    if (args.includes(' status ')) return { value: { exitCode: 0, stdout: ran ? ' D old.txt\0?? big.txt\0?? new.txt\0' : '', stderr: '' } }
    if (args.includes(' show :old.txt')) return { value: { exitCode: 0, stdout: 'same\ntext\n', stderr: '' } }
    return { value: { exitCode: 128, stdout: '', stderr: '' } }
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
  on('fs.read', () => ({ value: 'b\n' }))

  await $.session.start({ cwd: '/proj', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /kept\.lua/ }))?.text).toContain('kept.lua')
  await ui.unmount()
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
