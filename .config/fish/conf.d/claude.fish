# Claude Code mods kept in the dotfiles: every `claude` started from this shell loads them.
# Each mod is a folder in ~/.config/claude/mods holding .claude-plugin/plugin.json; the variable
# takes one path per mod, joined with ":".
set -l mods (path dirname (path dirname $HOME/.config/claude/mods/*/.claude-plugin/plugin.json))
if set -q mods[1]
    set -gx CLAUDE_CODE_PLUGIN_DIRS (string join : $mods)
end
