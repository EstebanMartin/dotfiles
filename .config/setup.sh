#!/usr/bin/env sh
set -e

# ==============================================================================
# Homebrew
# ==============================================================================

brew_install() {
    brew_install"$@"
}

case "$(uname)" in
    Darwin) BREW_PREFIX="/opt/homebrew" ;;
    Linux)  BREW_PREFIX="/home/linuxbrew/.linuxbrew" ;;
    *) echo "error: unsupported OS $(uname)" >&2; exit 1 ;;
esac

if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
    echo "Installing homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Loading homebrew"
    eval "$("$BREW_PREFIX/bin/brew" shellenv)"
fi
echo "Done. Brew $(brew --version | awk '{print $2}') is ready."

# ==============================================================================
# Git
# ==============================================================================

echo "Installing git and git-lfs"
brew_install git git-lfs
echo "Done. Git $(git --version | awk '{print $3}') is ready."

# ==============================================================================
# dotfiles repository
# ==============================================================================

DOTFILES_DIR="$HOME/.dotfiles"
if [ ! -d "$DOTFILES_DIR" ]; then
    echo "Setting up dotfiles bare repository..."
    git clone --bare "https://github.com/EstebanMartin/dotfiles.git" "$DOTFILES_DIR"
    git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" config status.showUntrackedFiles no
    git --git-dir="$DOTFILES_DIR" config branch.main.remote origin
    git --git-dir="$DOTFILES_DIR" config branch.main.merge refs/heads/main
    git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" checkout -f
fi

# ==============================================================================
# Fish
# ==============================================================================

echo "Installing fish and fish_lsp"
brew_install fish fish-lsp

fish_path="$(command -v fish)"

if ! grep -qxF "$fish_path" /etc/shells; then
    echo "Registering $fish_path as a valid login shell..."
    echo "$fish_path" | sudo tee -a /etc/shells
else
    echo "$fish_path is already registered in /etc/shells."
fi

if [ "$SHELL" = "$fish_path" ]; then
    echo "fish is already your default shell."
else
    echo "Setting fish as your default shell..."
    chsh -s "$fish_path"
    echo "Done. Open a new terminal or re-login for the change to take effect."
fi

echo "Done. Fish $(fish --version | awk '{print $3}') is ready."

# ==============================================================================
# Neovim
# ==============================================================================

echo "Installing neovim and dependencies"
brew_install neovim ripgrep jq yq

echo "Installing lsp servers"
brew_install lua-language-server yaml-language-server

echo "Done. Neovim $(nvim --version | head -1) is ready."
echo "Plugins will be installed automatically on first launch via vim.pack."

# ==============================================================================
# GitHub CLI
# ==============================================================================

echo "Installing gh"
brew_install gh

echo "Done. gh $(gh --version | head -1 | awk '{print $3}') is ready."
echo "Run 'gh auth login' to authenticate with GitHub."

# ==============================================================================
# Tmux
# ==============================================================================

echo "Installing tmux"
brew_install tmux

echo "Done. Tmux $(tmux -V | awk '{print $2}') is ready."

# ==============================================================================
# fzf
# ==============================================================================

echo "Installing fzf"
brew_install fzf

echo "Done. fzf $(fzf --version | awk '{print $1}') is ready."

# ==============================================================================
# Go
# ==============================================================================

echo "Installing go and gopls"
brew_install go gopls

echo "Done. Go $(go version | awk '{print $3}') is ready."




