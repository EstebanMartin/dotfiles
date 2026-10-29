export type Change = {
  id: string
  file: string
  /** 'Bash' for a change a shell command made, found by comparing files around the call */
  tool: 'Edit' | 'Write' | 'Bash'
  /** Unified-diff hunks of this one change */
  diff: string
  at: number
  /** The path a shell command moved the file from */
  renamedFrom?: string
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
  /** The discussion after the comment: Claude's answers (its `reply` tool) and the user's follow-ups */
  replies?: Reply[]
  /** Set by Claude's reply when it considers the comment handled */
  isResolved?: boolean
}

export type Reply = {
  /** Who wrote it; absent on replies stored before the user could answer, which are Claude's */
  author?: 'you' | 'claude'
  text: string
  at: number
  /** A follow-up of the user's: pending until it rides along with a prompt */
  status?: 'pending' | 'sent'
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
      /** The file finder's query while it is open (f), null when closed */
      finder: string | null
      /** Files marked viewed, each with the id of its last change then: a later change clears the mark */
      viewed: Record<string, string>
      /** Whether long diffs are drawn whole instead of cut at the row limit */
      fullDiff: boolean
      /** Whether long code lines wrap instead of being cut at the pane's edge */
      wrapLines: boolean
      /** Whether the field for a note on the whole file is open */
      noteOpen: boolean
      /** The comment whose discussion the next prompt answers, while its reply box is open */
      replyTo: string | null
    }
  }
}
