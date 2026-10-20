# -f: no builtin file completion for cd (it merges in CDPATH on its own);
# __fish_complete_cd (functions/) provides local dirs first, CDPATH as fallback.
complete -c cd -f -a '(__fish_complete_cd)'
