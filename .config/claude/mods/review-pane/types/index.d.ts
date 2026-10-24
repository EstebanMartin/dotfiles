export type Change = {
  id: string
  file: string
  tool: 'Edit' | 'Write'
  /** Unified-diff hunks of this one change */
  diff: string
  at: number
}

export type ReviewComment = {
  id: string
  file: string
  /** The change and the diff rows (first, last) the comment is anchored to; absent on a file comment */
  changeId?: string
  rows?: [number, number]
  /** First and last line number, in the new file unless `side` is 'old' (only removed lines picked) */
  lines?: [number, number]
  side?: 'new' | 'old'
  /** The picked diff lines, with their +/-/space markers */
  snippet?: string[]
  text: string
  status: 'pending' | 'sent'
}

/** The diff rows picked for a comment, inclusive: the comment box is open on them */
export type Selection = { changeId: string; from: number; to: number }

/** A diff row of the open file: where the keyboard cursor sits, or where a visual range began */
export type RowRef = { changeId: string; row: number }

declare module 'claude-code' {
  interface PluginState {
    'review-pane': {
      changes: Change[]
      comments: ReviewComment[]
      selected: string | null
      selection: Selection | null
      cursor: RowRef | null
      /** The row `v` was pressed on, while a visual range is being extended */
      visual: RowRef | null
      /** Each changed file as it was before Claude's first change to it ('' for a file Claude created) */
      baselines: Record<string, string>
      /** The one edit shown for the open file, or null for all its changes as one net diff */
      edit: string | null
      /** Whether the full list of keys is shown under the header */
      showKeys: boolean
    }
  }
}
