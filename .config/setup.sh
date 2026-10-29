#!/bin/sh
# Idempotent: every step checks the current state first and only acts when it
# differs, so rerunning after changing a setting applies just that change.
set -eu

# Install a Homebrew formula only if it isn't already installed
brew_install() {
  brew list --formula "$1" >/dev/null 2>&1 || brew install "$1"
}

# Install a global npm package only if it isn't already installed
npm_install() {
  npm list -g "$1" >/dev/null 2>&1 || npm install -g "$1"
}

# Install a Homebrew cask only if it isn't already installed
brew_cask_install() {
  brew list --cask "$1" >/dev/null 2>&1 || brew install --cask "$1"
}

# Write a macOS default only if it differs from the current value; sets
# defaults_changed=1 so the caller knows to restart the affected app.
# Usage: set_default <domain> <key> <-bool|-int|-float|-string> <value>
set_default() {
  current="$(defaults read "$1" "$2" 2>/dev/null || true)"
  case "$3" in
    -bool) if [ "$4" = true ]; then want=1; else want=0; fi ;;
    *) want="$4" ;;
  esac
  if [ "$current" != "$want" ]; then
    defaults write "$1" "$2" "$3" "$4"
    echo "Set $1 $2 = $4"
    defaults_changed=1
  fi
}

# =============================================================================
# macOS
# =============================================================================

# --- Dock: auto-hide, on the left, no delay/animation ---
defaults_changed=0
set_default com.apple.dock autohide -bool true
set_default com.apple.dock orientation -string left
set_default com.apple.dock autohide-delay -float 0
set_default com.apple.dock autohide-time-modifier -float 0
set_default com.apple.dock show-recents -bool false  # no "recent apps" in the Dock
set_default com.apple.dock mru-spaces -bool false    # don't reorder Spaces by recent use
if [ "$defaults_changed" = 1 ]; then killall Dock; fi

# --- Appearance: switch between light and dark automatically (applies after logout) ---
if [ "$(defaults read -g AppleInterfaceStyleSwitchesAutomatically 2>/dev/null || true)" != "1" ]; then
  defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool true
  defaults delete -g AppleInterfaceStyle 2>/dev/null || true
  echo "Set appearance to switch automatically"
fi

# --- Keyboard: fast key repeat, no accent popup (applies after logout) ---
set_default -g ApplePressAndHoldEnabled -bool false
set_default -g KeyRepeat -int 2
set_default -g InitialKeyRepeat -int 15

# --- Text input: no autocorrect, smart quotes or smart dashes ---
set_default -g NSAutomaticSpellingCorrectionEnabled -bool false
set_default -g NSAutomaticQuoteSubstitutionEnabled -bool false
set_default -g NSAutomaticDashSubstitutionEnabled -bool false

# --- Finder: show hidden files, extensions and path bar; no .DS_Store on network/USB ---
defaults_changed=0
set_default com.apple.finder AppleShowAllFiles -bool true
set_default -g AppleShowAllExtensions -bool true
set_default com.apple.finder ShowPathbar -bool true
set_default com.apple.desktopservices DSDontWriteNetworkStores -bool true
set_default com.apple.desktopservices DSDontWriteUSBStores -bool true
if [ "$defaults_changed" = 1 ]; then killall Finder; fi

# =============================================================================
# Homebrew
# =============================================================================

# --- Install ---
if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
  echo "Installing Homebrew..."
  # Non-interactive mode can't ask for a password, so cache sudo credentials first
  sudo -v
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# --- Configure: make brew available in this session (Apple Silicon or Intel) ---
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# =============================================================================
# Dotfiles (bare repo with $HOME as the work tree)
# =============================================================================

DOTFILES_DIR="$HOME/.dotfiles"
DOTFILES_BACKUP="$HOME/.dotfiles-backup"

# --- Install: Homebrew's git is newer than the one bundled with macOS ---
brew_install git
brew_install git-lfs

dot() {
  git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" "$@"
}

# --- Install: clone over HTTPS (works before SSH keys exist), push over SSH ---
# Only on first run; after that, syncing is `dot pull` (alias in config.fish)
if [ ! -d "$DOTFILES_DIR" ]; then
  git clone --bare https://github.com/EstebanMartin/dotfiles.git "$DOTFILES_DIR"
  dot remote set-url --push origin git@github.com:EstebanMartin/dotfiles.git

  # A bare clone doesn't track remote branches, so `pull` wouldn't know what to pull
  dot config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
  dot fetch origin
  DOTFILES_BRANCH="$(dot symbolic-ref --short HEAD)"
  dot branch --set-upstream-to="origin/$DOTFILES_BRANCH" "$DOTFILES_BRANCH"

  # Move aside any existing files the checkout would overwrite
  dot ls-tree -r --name-only HEAD | while IFS= read -r f; do
    if [ -e "$HOME/$f" ] || [ -L "$HOME/$f" ]; then
      mkdir -p "$DOTFILES_BACKUP/$(dirname "$f")"
      mv "$HOME/$f" "$DOTFILES_BACKUP/$f"
      echo "Backed up ~/$f to $DOTFILES_BACKUP/$f"
    fi
  done
  dot checkout
fi

# --- Configure: hide the rest of $HOME from `dot status` ---
if [ "$(dot config --get status.showUntrackedFiles || true)" != "no" ]; then
  dot config status.showUntrackedFiles no
fi

# =============================================================================
# Fish (shell config itself lives in the dotfiles: ~/.config/fish/config.fish)
# =============================================================================

# --- Install ---
brew_install fish

# --- Configure: set as default shell ---
FISH_PATH="$(brew --prefix)/bin/fish"
if ! grep -qx "$FISH_PATH" /etc/shells; then
  echo "$FISH_PATH" | sudo tee -a /etc/shells >/dev/null
fi
# Compare against the account's login shell, not $SHELL: $SHELL is inherited
# from whatever launched this script and can be stale or different
LOGIN_SHELL="$(dscl . -read "/Users/$(id -un)" UserShell | awk '{print $2}')"
if [ "$LOGIN_SHELL" != "$FISH_PATH" ]; then
  chsh -s "$FISH_PATH"
fi

# --- Configure: no "Last login" message ---
[ -e "$HOME/.hushlogin" ] || touch "$HOME/.hushlogin"

# =============================================================================
# Neovim
# =============================================================================

# --- Install ---
brew_install neovim

# --- ripgrep: used by fzf-lua's live_grep_native (<leader>fg) ---
brew_install ripgrep

# --- Tree-sitter: CLI that nvim-treesitter builds parsers with ---
brew_install tree-sitter-cli

# --- Language servers (vim.lsp.enable in plugin/nvim-lspconfig.lua) ---
brew_install efm-langserver
brew_install fish-lsp
brew_install lua-language-server
brew_install yaml-language-server

# --- Tools used by ftplugin/json.lua and lua/bruno/ ---
brew_install jq
brew_install bruno-cli
brew_install node
npm_install fixjson

# =============================================================================
# Go
# =============================================================================

# --- Install: toolchain, plus gopls (the language server nvim's gopls config uses) ---
brew_install go
brew_install gopls

# --- Install: debugger for nvim-dap-go, linter that efm runs ---
brew_install delve
brew_install golangci-lint

# =============================================================================
# fzf
# =============================================================================

# --- Install ---
brew_install fzf

# =============================================================================
# tmux (config in ~/.config/tmux)
# =============================================================================

# --- Install ---
brew_install tmux

# =============================================================================
# GitHub CLI (config in ~/.config/gh; run `gh auth login` once to authenticate)
# =============================================================================

# --- Install ---
brew_install gh

# =============================================================================
# mycli (MySQL client; config in ~/.myclirc)
# =============================================================================

# --- Install ---
brew_install mycli

# =============================================================================
# Ghostty
# =============================================================================

# --- Install ---
brew_cask_install ghostty

# --- Font: JetBrainsMono Nerd Font (used in ~/.config/ghostty/config) ---
brew_cask_install font-jetbrains-mono-nerd-font

# =============================================================================
# Amethyst (tiling window manager; config in ~/.config/amethyst)
# =============================================================================

# --- Install ---
brew_cask_install amethyst

# =============================================================================
# Claude Code
# =============================================================================

# --- Install: native installer (auto-updates in the background) ---
[ -x "$HOME/.local/bin/claude" ] || /bin/bash -c "$(curl -fsSL https://claude.ai/install.sh)"
