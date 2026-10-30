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

# --- Tools used by ftplugin/json.lua, lua/bruno/ and lua/opencollection/ ---
brew_install jq
brew_install bruno-cli
brew_install node
npm_install fixjson

# --- 1Password CLI (`op`): resolves Bruno secrets in lua/bruno/ and lua/opencollection/ ---
# Turn on Settings > Developer > "Integrate with 1Password CLI" in the app to sign in with it
brew_cask_install 1password-cli

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

# --- Nvim.app: opens files from Finder in nvim inside Ghostty (source in scripts/applescript/nvim-app.applescript) ---
# Rebuilt only when the source or nvim's path changes; the hash of both is stored in the app's Info.plist
NVIM_APP="$HOME/Applications/Nvim.app"
NVIM_APP_SRC="$HOME/.config/scripts/applescript/nvim-app.applescript"
NVIM_PATH="$(command -v nvim)"
NVIM_APP_HASH="$({ cat "$NVIM_APP_SRC"; echo "$NVIM_PATH"; } | shasum | cut -d' ' -f1)"
if [ "$(/usr/libexec/PlistBuddy -c "Print :NvimAppHash" "$NVIM_APP/Contents/Info.plist" 2>/dev/null || true)" != "$NVIM_APP_HASH" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$NVIM_APP"
  sed "s|@NVIM@|$NVIM_PATH|" "$NVIM_APP_SRC" | osacompile -o "$NVIM_APP"

  # Register as an editor for any file, so it shows up in Finder's "Open With"
  plist="$NVIM_APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleIdentifier string com.eramirezq.nvim" \
    -c "Set :CFBundleDocumentTypes:0:CFBundleTypeRole Editor" \
    -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" \
    -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:0 string public.text" \
    -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes:1 string public.data" "$plist"

  # Icon: the logo Homebrew's neovim ships (only 128px), replacing the default droplet icon
  icon_src="$(brew --prefix)/share/icons/hicolor/128x128/apps/nvim.png"
  iconset="$(mktemp -d)/nvim.iconset"
  mkdir "$iconset"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$icon_src" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" "$icon_src" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$NVIM_APP/Contents/Resources/nvim.icns"
  rm -rf "$(dirname "$iconset")"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile nvim" "$plist"
  rm -f "$NVIM_APP/Contents/Resources/Assets.car" "$NVIM_APP/Contents/Resources/droplet.icns"

  # Written last, so a build that fails partway is retried on the next run
  /usr/libexec/PlistBuddy -c "Add :NvimAppHash string $NVIM_APP_HASH" "$plist"

  # Editing Info.plist breaks the signature, so re-sign ad hoc; then tell Launch Services about the app
  codesign --force --sign - "$NVIM_APP" 2>/dev/null
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$NVIM_APP"
  echo "Built $NVIM_APP"
fi

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

# --- TypeScript: `tsc -p <mod folder>` type-checks the mods in ~/.config/claude/mods ---
brew_install typescript
