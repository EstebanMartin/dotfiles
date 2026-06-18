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
set -l sock
if test "$os" = Darwin
    set sock "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
else
    set sock "$HOME/.1password/agent.sock"
end

if test -S "$sock"
    set -gx SSH_AUTH_SOCK "$sock"
end

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
    set -l last_status $status # must be first — $status is overwritten by every command

    # git rev-parse returns the repo root path, or empty string if not in a repo
    set -l git_root (git rev-parse --show-toplevel 2>/dev/null)

    if test -n "$git_root"

        # single git call: --porcelain=v2 for stable machine-readable format,
        # --branch adds branch/upstream/ahead-behind headers, --show-stash adds stash count
        set -l gs (git status --porcelain=v2 --branch --show-stash 2>/dev/null)

        # ── Render ───────────────────────────────────────────────────

        echo -n (set_color cyan)(basename $git_root)(set_color normal)

        # path relative to repo root, capped at 4 segments to keep it short
        set -l cwd (pwd)
        if test "$cwd" != "$git_root"
            set -l parts (string split --no-empty '/' (string replace -- "$git_root/" '' $cwd))
            test (count $parts) -gt 4; and set parts $parts[-4..-1]
            echo -n ' at '(set_color yellow)(string join '/' $parts)(set_color normal)
        end

        # header line looks like "# branch.head main"; --groups-only returns only the captured group
        set -l git_branch (string match -r --groups-only '^# branch\.head (.+)' $gs)
        if test "$git_branch" = '(detached)'
            # not on a branch — use a 7-char short hash from branch.oid instead
            set -l short_hash (string sub -l 7 (string match -r --groups-only '^# branch\.oid (.+)' $gs))
            echo -n ' on '(set_color bryellow)"detached@$short_hash"(set_color normal)
        else
            echo -n ' on '(set_color magenta)$git_branch(set_color normal)
        end

        # ── Status symbols ───────────────────────────────────────────

        # each element is a fully colored string; joined with spaces into [...] at the end
        set -l syms

        # all header lines start with '#'; -v inverts the match to keep only file-status lines
        # porcelain v2 file lines look like "1 XY ..." where X = staged, Y = unstaged, '.' = no change
        set -l fl (string match -v -r '^#' $gs)

        # in porcelain v2, the char right after "1 " is the staged status — '.' means no staged change
        test (count (string match -r '^[12] [^.]' $fl)) -gt 0
        and set -a syms (set_color green)'✚'(set_color normal)

        # the char after that is the unstaged status — same idea, '.' means no unstaged change
        test (count (string match -r '^[12] .[^.]' $fl)) -gt 0
        and set -a syms (set_color yellow)'!'(set_color normal)

        # untracked files get their own line type starting with '?'
        test (count (string match -r '^\?' $fl)) -gt 0
        and set -a syms (set_color red)'?'(set_color normal)

        # unmerged/conflicted files start with 'u' in porcelain v2
        test (count (string match -r '^u' $fl)) -gt 0
        and set -a syms (set_color brred)'✖'(set_color normal)

        # stash line looks like "# stash 2"; absent entirely when stash is empty, so default to 0
        set -l stash_count (string match -r --groups-only '^# stash (\d+)' $gs)
        test -z "$stash_count"; and set stash_count 0
        test "$stash_count" -gt 0
        and set -a syms (set_color blue)"⚑$stash_count"(set_color normal)

        # branch.ab line looks like "# branch.ab +3 -1"; absent entirely when no upstream is set
        set -l ab (string match -r --groups-only '^# branch\.ab \+(\d+) -(\d+)' $gs)
        if test (count $ab) -ge 2 # guards against the no-upstream case
            test $ab[1] -gt 0; and set -a syms (set_color cyan)"↑$ab[1]"(set_color normal)
            test $ab[2] -gt 0; and set -a syms (set_color cyan)"↓$ab[2]"(set_color normal)
        end

        if test (count $syms) -gt 0
            echo -n ' ['(string join ' ' $syms)']'
        end

    else
        # not in a repo — show current path, ~ substituted for home, last 4 segments max
        set -l cwd (string replace -- $HOME '~' (pwd))
        set -l parts (string split --no-empty '/' $cwd)
        test (count $parts) -gt 4; and set parts $parts[-4..-1]
        echo -n (set_color yellow)(string join '/' $parts)(set_color normal)
    end

    # red dot if the last command failed (non-zero exit code)
    if test $last_status -ne 0
        echo -n ' '(set_color red)'●'(set_color normal)
    end

    echo '' # end the info line
    echo -n '› ' # second line: the actual input prompt
end
