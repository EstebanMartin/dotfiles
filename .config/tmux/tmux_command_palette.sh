#!/usr/bin/env bash
if ! command -v fzf &>/dev/null; then
    tmux display-message -d 0 "Command palette requires fzf"
    exit 1
fi

commands=()

commands+=("Detach Session")
cmd_detach_session() { tmux detach-client; }

commands+=("Enter Copy Mode")
cmd_enter_copy_mode() { tmux copy-mode; }

commands+=("Kill Current Pane")
cmd_kill_current_pane() { tmux kill-pane; }

commands+=("Kill Current Session")
cmd_kill_current_session() { tmux kill-session; }

commands+=("Kill Current Window")
cmd_kill_current_window() { tmux kill-window; }

commands+=("Kill Other Panes")
cmd_kill_other_panes() { tmux confirm-before -p "Kill other panes? (y/n)" "kill-pane -a"; }

commands+=("Kill Other Windows")
cmd_kill_other_windows() { tmux confirm-before -p "Kill other windows? (y/n)" "kill-window -a"; }

commands+=("Kill Server")
cmd_kill_server() { tmux kill-server; }

commands+=("Move Pane to Window")
cmd_move_pane_to_window() { tmux break-pane; }

commands+=("New Window")
cmd_new_window() { tmux new-window -c "#{pane_current_path}"; }

commands+=("Reload Config")
cmd_reload_config() {
    tmux source-file ~/.config/tmux/tmux.conf &&
    tmux display-message "Tmux config reloaded"
}

commands+=("Rename Window")
cmd_rename_window() { tmux command-prompt -I "#W" "rename-window '%%'"; }

commands+=("Restart Pane")
cmd_restart_pane() { tmux respawn-pane -k; }

commands+=("Rotate Pane Focus")
cmd_rotate_pane_focus() { tmux select-pane -Z -t :.+; } # -Z keeps the window zoomed

commands+=("Select Pane")
cmd_select_pane() { tmux display-panes; }

commands+=("Select Session")
cmd_select_session() { tmux choose-tree -s; }

commands+=("Select Window")
cmd_select_window() {
    tmux list-windows -F '#{window_index}: #{window_name}' \
        | fzf --tmux center --prompt="Window > " --delimiter=: \
            --bind 'enter:become(tmux select-window -t :{1})'
}

commands+=("Split Horizontal")
cmd_split_horizontal() { tmux split-window -v -c "#{pane_current_path}"; }

commands+=("Split Vertical")
cmd_split_vertical() { tmux split-window -h -c "#{pane_current_path}"; }

commands+=("Toggle Zoom Pane")
cmd_toggle_zoom_pane() { tmux resize-pane -Z; }

selected_command=$(
    printf "%s\n" "${commands[@]}" \
        | fzf --tmux center --no-sort --bind "ctrl-e:abort" --border --prompt="Command Palette > "
)

[[ -z "$selected_command" ]] && exit 0

fn="cmd_$(echo "$selected_command" | tr '[:upper:] ' '[:lower:]_')"
"$fn"
