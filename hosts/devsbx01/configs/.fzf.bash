# Setup fzf — ~/.fzf/bin/fzf (0.71) must win over /usr/bin/fzf (0.44, Debian)
# Strip any existing entry and always prepend, so the newer binary is always first.
_fzf_bin="$HOME/.fzf/bin"
PATH="${PATH#$_fzf_bin:}"       # remove if it's the first entry
PATH="${PATH//:$_fzf_bin/}"     # remove if it's anywhere else
export PATH="$_fzf_bin:$PATH"
unset _fzf_bin

# Key bindings (Ctrl-R history, Ctrl-T files, Alt-C dirs) and completions
[[ -f ~/.fzf/shell/key-bindings.bash ]] && source ~/.fzf/shell/key-bindings.bash
[[ -f ~/.fzf/shell/completion.bash   ]] && source ~/.fzf/shell/completion.bash
