#!/usr/bin/env bash

if ! command -v fzf &>/dev/null; then
    tmux display-message -d 0 "Command palette requires fzf"
    exit 1
fi

commands=(
    "Detach Session"
    "Enter Copy Mode"
    "Enter Resize Mode"
    "Kill Current Pane"
    "Kill Current Session"
    "Kill Current Window"
    "Kill Other Panes"
    "Kill Other Windows"
    "Kill Server"
    "Move Pane to Window"
    "New Window"
    "Reload Config"
    "Rename Window"
    "Restart Pane"
    "Rotate Pane Focus"
    "Select Pane"
    "Select Session"
    "Select Window"
    "Split Horizontal"
    "Split Vertical"
    "Toggle Zoom Pane"
)

selected_command=$(
    printf "%s\n" "${commands[@]}" \
        | fzf --tmux center --bind "ctrl-e:abort" --border --prompt="Command Palette > "
)

case "$selected_command" in
    "Detach Session") tmux detach-client ;;
    "Enter Copy Mode") tmux copy-mode ;;
    "Enter Resize Mode") tmux switch-client -T resize-mode ;;
    "Kill Current Pane") tmux kill-pane ;;
    "Kill Current Session") tmux kill-session ;;
    "Kill Current Window") tmux kill-window ;;
    "Kill Other Panes")
        read -r -p "Kill other panes? (y/n) " confirm
        [[ "$confirm" == "y" ]] || break
        current=$(tmux display -p '#{pane_id}')
        tmux list-panes -F '#{pane_id}' | grep -v "$current" | xargs -I{} tmux kill-pane -t {}
        ;;
    "Kill Other Windows")
        read -r -p "Kill other windows? (y/n) " confirm
        [[ "$confirm" == "y" ]] || break
        current=$(tmux display-message -p '#{window_index}')
        tmux list-windows -F '#{window_index}' | grep -v "$current" | xargs -I{} tmux kill-window -t {}
        ;;
    "Kill Server") tmux kill-server ;;
    "Move Pane to Window") tmux break-pane ;;
    "New Window") tmux new-window -c "#{pane_current_path}" ;;
    "Reload Config")
        tmux source-file ~/.config/tmux/tmux.conf &&
        tmux display-message "Tmux config reloaded"
        ;;
    "Rename Window") tmux command-prompt -I "#W" "rename-window '%%'" ;;
    "Restart Pane") tmux respawn-pane -k ;;
    "Rotate Pane Focus")
        zoomed=$(tmux display -p '#{window_zoomed_flag}')
        tmux select-pane -t :.+
        [[ "$zoomed" -eq 1 ]] && tmux resize-pane -Z
        ;;
    "Select Pane") tmux display-panes ;;
    "Select Session") tmux choose-tree -s ;;
    "Select Window")
        tmux list-windows -F '#W' \
            | fzf-tmux -p --prompt="Window > " \
            | xargs tmux select-window -t
        ;;
    "Split Horizontal") tmux split-window -v -c "#{pane_current_path}" ;;
    "Split Vertical") tmux split-window -h -c "#{pane_current_path}" ;;
    "Toggle Zoom Pane") tmux resize-pane -Z ;;
esac
