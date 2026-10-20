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
fish_add_path -g "$HOME/.local/bin" "$HOME/scripts/sh"

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
end

if type -q podman-compose; and not type -q docker-compose
    mkdir -p ~/.local/bin
    ln -sf (which podman-compose) ~/.local/bin/docker-compose
end

# the dir may have just been created above, after the PATH entry in the Path section
contains ~/.local/bin $PATH; or fish_add_path -g ~/.local/bin

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
# FZF
# =============================================================================
if type -q fzf
    fzf --fish | source
end

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
