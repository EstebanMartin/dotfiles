#!/usr/bin/env bash
# Command palette (prefix k): fuzzy-pick a tmux command and run it.
# Each line is "label<TAB>tmux command"; the command goes through tmux's own
# parser (source-file), so it's written exactly as at the prefix-: prompt.
if ! command -v fzf >/dev/null; then
    tmux display-message -d 0 "Command palette requires fzf"
    exit 1
fi

cmd=$(fzf --tmux center --no-sort --border --prompt="Command Palette > " \
    --delimiter='\t' --with-nth=1 --accept-nth=2 --bind "ctrl-e:abort" <<'EOF'
Detach Session	detach-client
Enter Copy Mode	copy-mode
Kill Current Pane	kill-pane
Kill Current Session	kill-session
Kill Current Window	kill-window
Kill Other Panes	confirm-before -p "Kill other panes? (y/n)" "kill-pane -a"
Kill Other Windows	confirm-before -p "Kill other windows? (y/n)" "kill-window -a"
Kill Server	kill-server
Move Pane to Window	break-pane
New Window	new-window -c "#{pane_current_path}"
Reload Config	source-file ~/.config/tmux/tmux.conf ; display-message "Tmux config reloaded"
Rename Window	command-prompt -I "#W" "rename-window '%%'"
Restart Pane	respawn-pane -k
Rotate Pane Focus	select-pane -Z -t :.+
Select Pane	display-panes
Select Session	choose-tree -s
Select Window	display-popup -E "tmux list-windows -F '#{window_index}: #{window_name}' | fzf --reverse --delimiter=: --bind 'enter:become(tmux select-window -t :{1})'"
Split Horizontal	split-window -v -c "#{pane_current_path}"
Split Vertical	split-window -h -c "#{pane_current_path}"
Toggle Zoom Pane	resize-pane -Z
EOF
)

# nothing picked (Esc / ctrl-e): exit 0 so tmux's `run` doesn't report an error
[ -z "$cmd" ] || printf '%s\n' "$cmd" | tmux source-file -
