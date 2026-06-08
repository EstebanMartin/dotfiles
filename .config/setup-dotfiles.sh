#!/usr/bin/env sh
set -e

if [ "$(uname)" != "Darwin" ]; then
    echo "error: script only supports MacOS" >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

for tool in git fish neovim tmux fzf jq; do
    echo "Installing $tool..."
    brew install --quiet "$tool"
done

DOTFILES_DIR="$HOME/.dotfiles"

if [ -d "$DOTFILES_DIR" ]; then
    echo "Dotfiles repo already exists at $DOTFILES_DIR"
    echo "Done."
    exit 0
fi

echo "Cloning dotfiles..."
git clone --bare "https://github.com/EstebanMartin/dotfiles.git" "$DOTFILES_DIR"
git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" config status.showUntrackedFiles no

# Back up any files that would be overwritten by checkout
conflicts=$(git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" checkout 2>&1 | grep -E "^\s+\." | awk '{print $1}' || true)
if [ -n "$conflicts" ]; then
    echo "Backing up conflicting files to ~/.dotfiles-backup/"
    mkdir -p "$HOME/.dotfiles-backup"
    for f in $conflicts; do
        mkdir -p "$HOME/.dotfiles-backup/$(dirname "$f")"
        mv "$HOME/$f" "$HOME/.dotfiles-backup/$f"
    done
    git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" checkout
fi

echo "Done. Dotfiles checked out to $HOME"
