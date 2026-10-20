# =============================================================================
# Environment
# =============================================================================
# not exported: in bash/sh scripts an exported CDPATH can send `cd foo` to
# ~/.config/foo and makes bash print the dir, polluting captured output
set -g CDPATH . $HOME/.config
set -gx XDG_CONFIG_HOME "$HOME/.config"
set -gx XDG_DATA_HOME "$HOME/.local/share"
set -gx XDG_CACHE_HOME "$HOME/.cache"

# =============================================================================
# Homebrew
# =============================================================================
# first, so the `type -q` checks below can see Homebrew-installed tools even in
# non-login shells that didn't get /opt/homebrew/bin from path_helper
if test -x /opt/homebrew/bin/brew
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
# Editor
# =============================================================================
if type -q nvim
    set -q EDITOR; or set -gx EDITOR nvim
    set -q VISUAL; or set -gx VISUAL nvim
end

# =============================================================================
# 1Password SSH agent
# =============================================================================
# check both OS's socket path directly — avoids forking `uname` just to pick one
for sock in "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" "$HOME/.1password/agent.sock"
    if test -S "$sock"
        set -gx SSH_AUTH_SOCK "$sock"
        break
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
    fish_add_path -g ~/.local/bin # in case it didn't exist yet when added above
end

if type -q podman-compose; and not type -q docker-compose
    mkdir -p ~/.local/bin
    ln -sf (which podman-compose) ~/.local/bin/docker-compose
    fish_add_path -g ~/.local/bin
end

# =============================================================================
# Fish LSP
# =============================================================================
set -gx fish_lsp_enabled_handlers formatting logging complete hover rename definition references diagnostics signatureHelp codeAction index

# =============================================================================
# Local overrides
# =============================================================================
if test -f ~/.config/fish/work/config.fish
    source ~/.config/fish/work/config.fish
end

# Interactive-only config below
status is-interactive; or return

set fish_greeting ""

# =============================================================================
# Ghostty shell integration
# =============================================================================
# Ghostty normally auto-injects this; only source it manually when that didn't
# happen (e.g. shell-integration = none), detected by its pending setup hook
if set -q GHOSTTY_RESOURCES_DIR; and not functions -q __ghostty_setup
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
# wt (git worktree helper)
# =============================================================================
if test -x ~/.local/bin/wt
    ~/.local/bin/wt init fish | source
end

# =============================================================================
# FZF widgets (bound below)
# =============================================================================
function fzf_dir_widget -d "Fuzzy-complete a directory relative to the path token under the cursor (e.g. ../<key>)"
    set -l tok (commandline -t | string unescape)
    set -l prefix (string replace -r '[^/]*$' '' -- $tok)
    set -l query (string replace -r '^.*/' '' -- $tok)
    set -l base (string replace -r '^~' $HOME -- $prefix)

    set -l dirs $base*/
    count $dirs >/dev/null; or return

    set -l choice (path basename $dirs | fzf --height=40% --reverse --query=$query \
        --preview "ls -1 "(string escape -- $base)"{} | head -50" --preview-window=right,40%)
    if test -n "$choice"
        set -l out (string escape -n -- $prefix$choice/)
        # keep a leading ~ unescaped so it still expands to $HOME
        string match -q '~*' -- $prefix; and set out (string replace -r '^\\\\~' '~' -- $out)
        commandline -t -- $out
    end
    commandline -f repaint
end

function fzf_repo_root_cd -d "Bare layout: fuzzy-cd to another worktree. Normal repo: fuzzy-checkout a branch"
    set -l common (git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    or return

    if string match -q '*/.git' -- $common
        # normal repo: switch branch (most recent first, current one excluded)
        # quoted so a detached HEAD (empty current) still passes a pattern
        set -l current (git branch --show-current)
        set -l choice (git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads \
            | string match -v -- "$current" | fzf --height=40% --reverse \
            --preview 'git log --oneline --color=always -10 {}' --preview-window=right,50%)
        test -n "$choice"; and git checkout $choice
        commandline -f repaint
        return
    end

    # bare layout: project dir is the parent of <project>/.bare
    set -l root (path dirname $common)
    set -l here (git rev-parse --show-toplevel 2>/dev/null)

    # other worktrees: paths and branches (parallel lists)
    set -l paths
    set -l branches
    set -l wt_path
    set -l branch
    for line in (git worktree list --porcelain)
        switch $line
            case 'worktree *'
                set wt_path (string sub -s 10 -- $line)
                set branch
            case 'branch *'
                set branch (string replace refs/heads/ '' -- (string sub -s 8 -- $line))
            case detached
                set branch detached
            case bare
                set wt_path
            case ''
                test -n "$wt_path" -a "$wt_path" != "$here"; or continue
                set -a paths $wt_path
                set -a branches $branch
                set wt_path
        end
    end
    test (count $paths) -gt 0; or return

    # one row per worktree: "<dir>\t(<branch>)"; branch only when it differs from the dir name
    set -l rows
    for i in (seq (count $paths))
        set -l name (string replace -- "$root/" '' $paths[$i])
        set -l info
        test "$branches[$i]" != "$name"; and set -a info "($branches[$i])"
        set -a rows (printf '%s\t%s' $name "$info")
    end

    set -l choice (printf '%s\n' $rows | fzf --height=40% --reverse --delimiter=\t \
        --preview "ls -1 "(string escape -- $root)"/{1} | head -50" --preview-window=right,40%)
    test -n "$choice"; and cd -- $root/(string split \t -- $choice)[1]
    commandline -f repaint
end

# =============================================================================
# Key bindings
# =============================================================================
# Ctrl-Y: accept the selected completion if the pager is open, otherwise the autosuggestion
set -l accept_cmd 'if commandline --paging-mode; commandline -f cancel; else; commandline -f accept-autosuggestion; end'
bind ctrl-y $accept_cmd
bind -M insert ctrl-y $accept_cmd

# Ctrl-N/P: navigate history (prefix-searches if there is text; moves in the pager when open)
bind ctrl-n down-or-search
bind ctrl-p up-or-search
bind -M insert ctrl-n down-or-search
bind -M insert ctrl-p up-or-search

# Ctrl-E: edit the command line in $EDITOR
bind ctrl-e edit_command_buffer
bind -M insert ctrl-e edit_command_buffer

# Ctrl-W: fuzzy-cd into a worktree/folder at the root of the (bare) repo
bind ctrl-w fzf_repo_root_cd
bind -M insert ctrl-w fzf_repo_root_cd

# Alt-G: fuzzy-complete a directory under the path token (e.g. `cd ../<Alt-G>`)
bind alt-g fzf_dir_widget
bind -M insert alt-g fzf_dir_widget

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

alias dot='git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
alias ffg='fg (jobs | awk -F\'\t\' \'{print $2 "\t" $4}\' | fzf --height=~10 --accept-nth 1)'
