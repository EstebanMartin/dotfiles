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
  await $.ui.input({ plugin: 'review-pane', key: 'inline', text: 'use wincmd here' })
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
  await $.ui.input({ plugin: 'review-pane', key: 'inline', text: 'pair these' })
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
  expect((await ui.find({ type: 'Text', text: /All changes/ }))?.text).toContain('All changes')
  expect((await ui.find({ type: 'Text', text: /2 edits as one diff/ }))?.text).toContain('2 edits')
  const net = (await ui.findAll({ type: 'Button' })).filter(b => b.key?.startsWith('ln:net:'))
  expect(net.length).toBe(5) // a, -b, +B, c, +d

  await $.ui.press({ plugin: 'review-pane', key: 'key:e' })
  expect((await ui.find({ type: 'Text', text: /edit 1 of 2/ }))?.text).toContain('edit 1 of 2')
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
  expect((await ui.find({ type: 'Text', text: /2 edits as one diff/ }))?.text).toContain('2 edits')
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
  expect((await ui.find({ type: 'Text', text: /as one diff/ }))?.text).toContain('as one diff')
  await ui.unmount()
})
