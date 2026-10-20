# Lazy loader for the wt (git worktree helper) shell wrapper. Autoloaded on the
# first `wt` call: `wt init fish` redefines wt as the real wrapper (cd support
# + completions), then the original call is replayed. Keeps the ~20ms of
# spawning `wt init fish` out of shell startup.
function wt --description 'Git worktree helper'
    command wt init fish | source
    wt $argv
end
