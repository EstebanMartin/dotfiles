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
if type -q nvim; and not set -q EDITOR
    set -gx EDITOR nvim
end

if type -q nvim; and not set -q VISUAL
    set -gx VISUAL nvim
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
if test -f ~/.config/fish/config.local.fish
    source ~/.config/fish/config.local.fish
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
alias ffg='fg (jobs | tail -n +1 | awk -F\'\t\' \'{print $2 "\t" $4}\' | fzf --height=~10 --accept-nth 1)'

# =============================================================================
# Prompt theme
# =============================================================================
# plain Unicode only (no Nerd Font glyphs); ANSI named colors so it follows the
# terminal palette. git status letters follow `git status -s`: green = staged
# (X column), red = unstaged (Y column), `?` untracked, `U` unmerged; `$` is
# the stash count (not part of short status).
set -g fish_transient_prompt 1

function fish_prompt
    set -l last_pipestatus $pipestatus # must be first — overwritten by every command

    # transient rendering (fish re-runs us with --final-rendering on accept):
    # collapse to just the glyph so scrollback stays clean
    if contains -- --final-rendering $argv
        echo -n (set_color brblack)'❯ '(set_color normal)
        return
    end

    # find the repo root ourselves (fork-free walk) instead of `git rev-parse
    # --show-toplevel`; the status call below is the only git subprocess
    set -l git_root
    set -l dir (pwd)
    while test "$dir" != /
        if test -e "$dir/.git"
            set git_root $dir
            break
        end
        set dir (path dirname $dir)
    end

    # over SSH, lead with the host so it's obvious this isn't the local shell
    set -q SSH_CONNECTION; and echo -n (set_color bryellow)(prompt_hostname)(set_color normal)' '

    if test -n "$git_root"
        # --porcelain=v2 for stable machine-readable output, --branch adds
        # branch/upstream/ahead-behind headers, --show-stash adds the stash count;
        # --no-optional-locks so the index refresh never races other git commands
        set -l gs (git --no-optional-locks status --porcelain=v2 --branch --show-stash 2>/dev/null)

        # ── In-progress operation (merge/rebase/cherry-pick/bisect) ────
        # pure filesystem checks — no extra git fork
        set -l git_dir "$git_root/.git"
        if test -f "$git_dir"
            # worktree/submodule: .git is a file pointing at the real gitdir
            set -l line
            read -l line <"$git_dir"
            set git_dir (string replace -r '^gitdir: ' '' $line)
            string match -q '/*' -- $git_dir; or set git_dir "$git_root/$git_dir"
        end

        set -l state_str
        if test -d "$git_dir/rebase-merge"
            set -l step
            set -l total
            read -l step <"$git_dir/rebase-merge/msgnum"
            read -l total <"$git_dir/rebase-merge/end"
            set state_str (set_color bryellow)"REBASE $step/$total"(set_color normal)
        else if test -d "$git_dir/rebase-apply"
            set -l step
            set -l total
            read -l step <"$git_dir/rebase-apply/next"
            read -l total <"$git_dir/rebase-apply/last"
            set -l label REBASE
            test -f "$git_dir/rebase-apply/applying"; and set label AM
            set state_str (set_color bryellow)"$label $step/$total"(set_color normal)
        else if test -f "$git_dir/MERGE_HEAD"
            set state_str (set_color bryellow)"MERGING"(set_color normal)
        else if test -f "$git_dir/CHERRY_PICK_HEAD"
            set state_str (set_color bryellow)"CHERRY-PICK"(set_color normal)
        else if test -f "$git_dir/BISECT_LOG"
            set state_str (set_color bryellow)"BISECTING"(set_color normal)
        end

        # ── Repo and path ────────────────────────────────────────────
        # in a linked worktree git_root is the worktree dir (named after the
        # branch), so recover the main repo's name from the gitdir path
        # <common>/worktrees/<name> to keep the repo context
        set -l repo_name (path basename $git_root)
        set -l worktree # linked worktree dir: relative to the project dir in a bare layout (may contain '/')
        if string match -q '*/worktrees/*' -- $git_dir
            # common dir is <main>/.git (normal) or <container>/.bare (bare layout)
            set -l common (path dirname (path dirname $git_dir))
            if contains -- (path basename $common) .git .bare
                set repo_name (path basename (path dirname $common))
                test (path basename $common) = .bare
                and set worktree (string replace -- (path dirname $common)/ '' $git_root)
            else
                set repo_name (string replace -r '\.git$' '' (path basename $common))
            end
            test -n "$worktree"; or set worktree (path basename $git_root)
        end
        # printed last ("repo branch [status] subpath"): path inside the repo/worktree,
        # capped at 3 segments; a leading '…/' marks dropped segments so truncation
        # is never silent
        set -l path_str
        set -l cwd (pwd)
        if test "$cwd" != "$git_root"
            set -l parts (string split --no-empty '/' (string replace -- "$git_root/" '' $cwd))
            set -l ellipsis
            if test (count $parts) -gt 3
                set parts $parts[-3..-1]
                set ellipsis '…/'
            end
            set path_str "$ellipsis"(string join '/' $parts)
        end

        # ── Branch ───────────────────────────────────────────────────
        # header line looks like "# branch.head main"
        set -l git_branch (string match -r --groups-only '^# branch\.head (.+)' $gs)
        set -l branch_str
        if test "$git_branch" = '(detached)'
            set -l short_hash (string sub -l 7 (string match -r --groups-only '^# branch\.oid (.+)' $gs))
            set branch_str (set_color bryellow)"detached@$short_hash"(set_color normal)
        else
            set branch_str (set_color magenta)$git_branch(set_color normal)
        end

        # ── Status symbols (git status -s style) ─────────────────────
        set -l syms

        # all header lines start with '#'; -v keeps only file-status lines
        # porcelain v2: "1 XY ..." / "2 XY ..." (rename/copy), X = staged, Y = unstaged, '.' = none
        set -l fl (string match -v -r '^#' $gs)

        # unmerged files start with 'u'
        set -l n (count (string match -r '^u' $fl))
        test $n -gt 0; and set -a syms (set_color brred)"U$n"(set_color normal)

        # staged column (green), then unstaged column (red), same letters as `git status -s`
        for letter in M T A D R C
            set n (count (string match -r "^[12] $letter" $fl))
            test $n -gt 0; and set -a syms (set_color green)"$letter$n"(set_color normal)
        end
        for letter in M T D
            set n (count (string match -r "^[12] .$letter" $fl))
            test $n -gt 0; and set -a syms (set_color red)"$letter$n"(set_color normal)
        end

        set n (count (string match -r '^\?' $fl))
        test $n -gt 0; and set -a syms (set_color red)"?$n"(set_color normal)

        # "# stash 2"; absent when the stash is empty
        set -l stash (string match -r --groups-only '^# stash (\d+)' $gs)
        test -n "$stash" -a "$stash" -gt 0 2>/dev/null
        and set -a syms (set_color blue)'$'"$stash"(set_color normal)

        # "# branch.ab +3 -1"; absent when no upstream is set
        set -l ab (string match -r --groups-only '^# branch\.ab \+(\d+) -(\d+)' $gs)
        if test (count $ab) -ge 2
            set -l arrows
            test $ab[1] -gt 0; and set arrows "⇡$ab[1]"
            test $ab[2] -gt 0; and set arrows "$arrows⇣$ab[2]"
            test -n "$arrows"; and set -a syms (set_color cyan)$arrows(set_color normal)
        end

        # "repo[/[worktree]] [branch REBASE 2/5 M2 ?1] subpath" — a trailing '/' marks a
        # linked worktree; the dir name follows only when it differs from the branch
        # (renamed branch, detached HEAD), since it is named after its branch otherwise
        set -l inner $branch_str
        test -n "$state_str"; and set inner "$inner $state_str"
        test (count $syms) -gt 0; and set inner "$inner "(string join ' ' $syms)
        echo -n (set_color cyan)$repo_name(set_color normal)
        if test -n "$worktree"
            set -l wt_name
            test "$git_branch" != "$worktree"; and set wt_name $worktree
            echo -n (set_color cyan)"/$wt_name"(set_color normal)
        end
        echo -n ' '(set_color brblack)'['(set_color normal)$inner(set_color brblack)']'(set_color normal)
        test -n "$path_str"; and echo -n ' '(set_color cyan)$path_str(set_color normal)
    else
        # not in a repo — current path, ~ for home, last 4 segments max
        set -l cwd (string replace -- $HOME '~' (pwd))
        set -l parts (string split --no-empty '/' $cwd)
        test (count $parts) -gt 4; and set parts $parts[-4..-1]
        echo -n (set_color cyan)(string join '/' $parts)(set_color normal)
    end

    # background/suspended jobs, only when there are any
    set -l njobs (count (jobs -p))
    test $njobs -gt 0; and echo -n ' '(set_color yellow)"✦$njobs"(set_color normal)

    echo '' # end the info line

    # second line: the glyph carries both exit status and vi mode
    # (fish_mode_prompt below suppresses the default [I]/[N]/[V] segment)
    # red if any stage of the last pipeline failed, not just the final one
    set -l glyph_color green
    string match -qv 0 -- $last_pipestatus; and set glyph_color red
    switch $fish_bind_mode
        case default
            echo -n (set_color blue)'❮ '(set_color normal)
        case visual
            echo -n (set_color magenta)'❮ '(set_color normal)
        case replace_one replace
            echo -n (set_color red)'❮ '(set_color normal)
        case '*'
            echo -n (set_color $glyph_color)'❯ '(set_color normal)
    end
end

# footer under the output of any command that took >=1s, so the time stays in
# scrollback attached to the command it describes (fish_postexec only fires
# when a command actually ran, so an empty Enter never repeats a stale time)
# (skipped for interactive programs, where it would only measure time spent in them)
function __prompt_duration_footer --on-event fish_postexec
    test $CMD_DURATION -ge 1000; or return
    set -l cmd (string split -f1 ' ' -- (string trim -- $argv[1]))
    contains -- $cmd nvim vim vi less more man ssh mosh top htop btop tmux; and return
    set -l secs (math --scale=0 $CMD_DURATION / 1000)
    set -l fmt {$secs}s
    test $secs -ge 60; and set fmt (math --scale=0 $secs / 60)m(math $secs % 60)s
    echo (set_color brblack)"took $fmt"(set_color normal)
end

# right side of the input line: exit code of the previous command, dim and
# live-only (blank on the transient --final-rendering redraw so it never
# lingers in scrollback next to a command it doesn't describe)
# (a pipeline shows every stage, e.g. `✘ 1|0`)
function fish_right_prompt
    set -l last_pipestatus $pipestatus
    contains -- --final-rendering $argv; and return
    string match -qv 0 -- $last_pipestatus
    and echo -n (set_color brblack)"✘ "(string join '|' $last_pipestatus)(set_color normal)
end

# suppresses the default "[I]"/"[N]"/"[V]" mode segment — the glyph shows mode
function fish_mode_prompt
end
