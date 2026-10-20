#!/usr/bin/env bash
# Command palette (prefix k): fuzzy-pick a tmux command and run it.
#
# Each entry is a label and the tmux command it runs, written exactly as at
# the prefix-: prompt ({ } wraps a command that runs inside another one).

# Same fuzzy window picker as prefix w in tmux.conf (quoted heredoc: kept verbatim)
pick_window=$(cat <<'EOF'
display-popup -E "tmux list-windows -F '#{window_index}: #{window_name}' | fzf --reverse --delimiter=: --bind 'enter:become(tmux select-window -t :{1})'"
EOF
)

entries=(
    # Sessions
    "Select Session"         'choose-tree -s'
    "Detach Session"         'detach-client'
    "Kill Current Session"   'kill-session'
    "Kill Server"            'kill-server'

    # Windows
    "New Window"             'new-window -c "#{pane_current_path}"'
    "Select Window"          "$pick_window"
    "Rename Window"          'command-prompt -I "#W" { rename-window "%%" }'
    "Kill Current Window"    'kill-window'
    "Kill Other Windows"     'confirm-before -p "Kill other windows? (y/n)" { kill-window -a }'

    # Panes
    "Split Horizontal"       'split-window -v -c "#{pane_current_path}"'
    "Split Vertical"         'split-window -h -c "#{pane_current_path}"'
    "Select Pane"            'display-panes'
    "Rotate Pane Focus"      'select-pane -Z -t :.+'
    "Toggle Zoom Pane"       'resize-pane -Z'
    "Move Pane to Window"    'break-pane'
    "Restart Pane"           'respawn-pane -k'
    "Kill Current Pane"      'kill-pane'
    "Kill Other Panes"       'confirm-before -p "Kill other panes? (y/n)" { kill-pane -a }'

    # Other
    "Enter Copy Mode"        'copy-mode'
    "Reload Config"          'source-file ~/.config/tmux/tmux.conf ; display-message "Tmux config reloaded"'
)

if ! command -v fzf >/dev/null; then
    tmux display-message -d 0 "Command palette requires fzf"
    exit 1
fi

# fzf shows only the labels and returns the picked entry's command
cmd=$(printf '%s\t%s\n' "${entries[@]}" |
    fzf --tmux center --no-sort --border --prompt="Command Palette > " \
        --delimiter='\t' --with-nth=1 --accept-nth=2 --bind "ctrl-e:abort")

# Run it through tmux's own parser, the same one that reads tmux.conf.
# Nothing picked (Esc / ctrl-e): exit 0 so tmux's `run` doesn't report an error.
[ -z "$cmd" ] || printf '%s\n' "$cmd" | tmux source-file -
