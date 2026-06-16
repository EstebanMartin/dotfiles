# =============================================================================
# Environment
# =============================================================================
set -l os (uname)

set -gx CDPATH $HOME/.config
set -gx XDG_CONFIG_HOME "$HOME/.config"
set -gx XDG_DATA_HOME "$HOME/.local/share"
set -gx XDG_CACHE_HOME "$HOME/.cache"

# =============================================================================
# Editor
# =============================================================================
if type -q nvim
    set -gx EDITOR nvim
    set -gx VISUAL nvim
end

# =============================================================================
# 1Password SSH agent
# =============================================================================
if test "$os" = Darwin
    set -g sock "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
else
    set -g sock "$HOME/.1password/agent.sock"
end
if test -S "$sock"
    set -gx SSH_AUTH_SOCK "$sock"
end
set -e sock

# =============================================================================
# Homebrew
# =============================================================================
if test "$os" = Darwin && test -x /opt/homebrew/bin/brew
    set -gx HOMEBREW_PREFIX /opt/homebrew
    set -gx HOMEBREW_CELLAR /opt/homebrew/Cellar
    set -gx HOMEBREW_REPOSITORY /opt/homebrew
    fish_add_path -g /opt/homebrew/bin /opt/homebrew/sbin
    if test -d "$HOMEBREW_PREFIX/share/fish/completions"
        set -gp fish_complete_path "$HOMEBREW_PREFIX/share/fish/completions"
    end
    if test -d "$HOMEBREW_PREFIX/share/fish/vendor_completions.d"
        set -gp fish_complete_path "$HOMEBREW_PREFIX/share/fish/vendor_completions.d"
    end
end

# =============================================================================
# Path
# =============================================================================
fish_add_path -g "$HOME/.local/bin"

# =============================================================================
# Golang
# =============================================================================
if type -q go
    fish_add_path -g "$HOME/go/bin"
end

# =============================================================================
# Podman → Docker symlinks
# =============================================================================
# Symlinks rather than aliases so bash scripts and subprocesses can find them

if type -q podman; and not type -q docker
    mkdir -p ~/.local/bin
    ln -sf (which podman) ~/.local/bin/docker
    fish_add_path ~/.local/bin
end

if type -q podman-compose; and not type -q docker-compose
    mkdir -p ~/.local/bin
    ln -sf (which podman-compose) ~/.local/bin/docker-compose
    fish_add_path ~/.local/bin
end

# =============================================================================
# Local overrides
# =============================================================================
if test -f ~/.config/fish/config.local.fish
    source ~/.config/fish/config.local.fish
end

# Interactive-only config below
status is-interactive; or return

set fish_greeting ""

# =============================================================================
# Ghostty shell integration
# =============================================================================
if set -q GHOSTTY_RESOURCES_DIR
    source "$GHOSTTY_RESOURCES_DIR/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
end

# =============================================================================
# Vi mode
# =============================================================================

set -g fish_key_bindings fish_vi_key_bindings
set fish_cursor_default block
set fish_cursor_insert line
set fish_cursor_replace_one underscore
set fish_cursor_visual block

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

abbr -a cdr 'cd (git rev-parse --show-toplevel)'
if type -q brew
    abbr -a bup 'ssh -T -q git@github.com >/dev/null 2>&1; brew update; brew upgrade; brew cleanup'
end

# =============================================================================
# Aliases
# =============================================================================

alias config='git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
alias ffg='fg (jobs | tail -n +1 | awk -F\'\t\' \'{print $2 "\t" $4}\' | fzf --height=~10 --accept-nth 1)'

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
