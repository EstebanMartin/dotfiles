# Replacement cd completion (paired with completions/cd.fish, which turns off
# fish's builtin file completion for cd). Stock fish merges CDPATH matches with
# the cwd's and the pager sorts them alphabetically, so local folders end up
# scattered among CDPATH ones. Here CDPATH matches appear only when nothing in
# the current directory matches.
function __fish_complete_cd --description 'Completions for the cd command'
    set -l token (commandline -ct)

    # local (or absolute/explicit/~) matches win
    set -l dirs (__fish_complete_directories $token)
    if set -q dirs[1]
        printf '%s\n' $dirs
        return 0
    end

    # no CDPATH, or a path that can't be CDPATH-relative: nothing more to offer
    set -q CDPATH[1]
    or return 0
    string match -qr '^(\.{0,2}/|~)' -- $token
    and return 0

    # `.` and the cwd are covered by the local completion above
    set -l cdpath (string match -v '.' -- $CDPATH)
    set -l cdpath (string match -v -- $PWD $cdpath)
    set -q cdpath[1]
    or return 0

    for cdpath in $cdpath
        set -l desc (string replace -r -- "^$HOME" "~" "$cdpath")
        for d in $cdpath/$token*/
            test -x $d
            and printf "%s\tCDPATH %s\n" (string replace -r "^$cdpath/" "" -- $d) $desc
        end
    end
end
