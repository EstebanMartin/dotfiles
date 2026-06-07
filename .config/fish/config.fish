# =============================================================================
# Environment
# =============================================================================
set -gx XDG_CONFIG_HOME "$HOME/.config"
set -gx XDG_DATA_HOME "$HOME/.local/share"
set -gx XDG_CACHE_HOME "$HOME/.cache"

if type -q nvim
    set -gx EDITOR nvim
    set -gx VISUAL nvim
end

# =============================================================================
# Terminal
# =============================================================================
set -x TERM xterm-256color
if test "$TERM_PROGRAM" = ghostty
    set -gx TERM xterm-256color
end

# =============================================================================
# Homebrew
# =============================================================================
if test (uname) = Darwin
    eval (/opt/homebrew/bin/brew shellenv)
end

# =============================================================================
# Path
# =============================================================================
export PATH="$HOME/.local/bin:$PATH"

# =============================================================================
# Golang
# =============================================================================
if type -q go
    # Add Go's bin dir to PATH persistently:
    # - fish_add_path deduplicates automatically (no risk of duplicates).
    # - -U stores it in fish_user_paths so it's remembered across sessions.
    fish_add_path -U (go env GOBIN)
    fish_add_path -U (go env GOPATH)/bin
end

# =============================================================================
# Local overrides
# =============================================================================
if test -f ~/.config/fish/config.local.fish
    source ~/.config/fish/config.local.fish
end

# Interactive-only config below
status is-interactive; or return

# =============================================================================
# Vi mode
# =============================================================================
fish_vi_key_bindings

# =============================================================================
# FZF
# =============================================================================
if type -q fzf
    fzf --fish | source
end

# =============================================================================
# Key bindings
# =============================================================================
# Ctrl-Y: accept autosuggestion
bind \cy accept-autosuggestion
bind -M insert \cy accept-autosuggestion

# Ctrl-N/P: navigate completions
bind \cn complete
bind \cp complete-and-search
bind -M insert \cn complete
bind -M insert \cp complete-and-search

# =============================================================================
# Abbreviations
# =============================================================================
abbr -a bup 'ssh -T -q git@github.com >/dev/null 2>&1; brew update; brew upgrade; brew cleanup'
abbr -a cdr 'cd $(git rev-parse --show-toplevel)'

# =============================================================================
# Aliases
# =============================================================================

alias config='git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'

# =============================================================================
# Prompt theme
# =============================================================================

function fish_prompt
    set -l last_status $status

    set -l git_root (git rev-parse --show-toplevel 2>/dev/null)

    if test -n "$git_root"
        # One call for everything: branch, ahead/behind, stash, file statuses
        set -l gs (git status --porcelain=v2 --branch --show-stash 2>/dev/null)

        # Branch name
        set -l git_branch (string match -r --groups-only '^# branch\.head (.+)' $gs)
        set -l is_detached false
        if test "$git_branch" = '(detached)'
            set is_detached true
            set git_branch (string sub -l 7 (string match -r --groups-only '^# branch\.oid (.+)' $gs))
        end

        # Ahead / behind (absent when no upstream)
        set -l ab (string match -r --groups-only '^# branch\.ab \+(\d+) -(\d+)' $gs)
        set -l ahead 0
        set -l behind 0
        if test (count $ab) -ge 2
            set ahead $ab[1]
            set behind $ab[2]
        end

        # Stash count (absent when no stashes)
        set -l stash_count (string match -r --groups-only '^# stash (\d+)' $gs)
        test -z "$stash_count"; and set stash_count 0

        # File-status lines only (strip headers)
        set -l fl (string match -r '^[^#]' $gs)

        # ── Render ────────────────────────────────────────────────────
        echo -n (set_color cyan)(basename $git_root)(set_color normal)

        set -l cwd (pwd)
        if test "$cwd" != "$git_root"
            set -l parts (string split --no-empty '/' (string replace -- "$git_root/" '' $cwd))
            if test (count $parts) -gt 4
                set parts $parts[-4..-1]
            end
            echo -n ' at '(set_color yellow)(string join '/' $parts)(set_color normal)
        end

        if $is_detached
            echo -n ' on '(set_color bryellow)"detached@$git_branch"(set_color normal)
        else
            echo -n ' on '(set_color magenta)$git_branch(set_color normal)
        end

        set -l syms

        # ✚ staged:    type 1/2 entry, X (pos 2) != '.'
        test (count (string match -r '^[12] [^.]' $fl)) -gt 0
        and set -a syms (set_color green) '✚' (set_color normal)

        # ! unstaged:  type 1/2 entry, Y (pos 3) != '.'
        test (count (string match -r '^[12] .[^.]' $fl)) -gt 0
        and set -a syms (set_color yellow) '!' (set_color normal)

        # ? untracked: lines starting with '?'
        test (count (string match -r '^\?' $fl)) -gt 0
        and set -a syms (set_color red) '?' (set_color normal)

        # ✖ conflicts: unmerged entries start with 'u'
        test (count (string match -r '^u' $fl)) -gt 0
        and set -a syms (set_color brred) '✖' (set_color normal)

        test "$stash_count" -gt 0
        and set -a syms (set_color blue) "⚑$stash_count" (set_color normal)

        test "$ahead" -gt 0
        and set -a syms (set_color cyan) "↑$ahead" (set_color normal)

        test "$behind" -gt 0
        and set -a syms (set_color cyan) "↓$behind" (set_color normal)

        if test (count $syms) -gt 0
            echo -n ' ['(string join '' $syms)']'
        end

    else
        # Not in a repo — last 4 of absolute path, ~ for home
        set -l cwd (string replace -- $HOME '~' (pwd))
        set -l parts (string split --no-empty '/' $cwd)
        if test (count $parts) -gt 4
            set parts $parts[-4..-1]
        end
        echo -n (set_color yellow)(string join '/' $parts)(set_color normal)
    end

    if test $last_status -ne 0
        echo -n ' '(set_color red)'●'(set_color normal)
    end

    echo ''
    echo -n '› '
end
