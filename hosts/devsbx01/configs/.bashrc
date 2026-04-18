# ~/.bashrc: executed by bash(1) for non-login shells.

# ble.sh must load before the interactive guard so it can hook readline early
[[ $- == *i* && -f ~/.local/share/blesh/ble.sh ]] && source ~/.local/share/blesh/ble.sh --noattach

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# --- History: shared, timestamped, effectively eternal ---
export HISTFILE="$HOME/.bash_eternal_history"
export HISTSIZE=
export HISTFILESIZE=
export HISTCONTROL=ignoreboth
export HISTTIMEFORMAT="%F %T "

shopt -s histappend

# Write immediately and sync across live sessions
export PROMPT_COMMAND='history -a; history -n'

shopt -s checkwinsize

# Make less more friendly for non-text input files
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# Set variable identifying the chroot you work in
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# Fancy prompt with color
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes ;;
esac

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >/dev/null 2>&1; then
        color_prompt=yes
    else
        color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

case "$TERM" in
    xterm*|rxvt*)
        PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
        ;;
esac

# --- ls / file tools ---
if command -v eza >/dev/null 2>&1; then
    alias ls='eza --icons'
    alias ll='eza -alF --icons --git'
    alias la='eza -a --icons'
    alias l='eza -F --icons'
    alias tree='eza --tree --icons'
else
    if [ -x /usr/bin/dircolors ]; then
        test -r "$HOME/.dircolors" && eval "$(dircolors -b "$HOME/.dircolors")" || eval "$(dircolors -b)"
        alias ls='ls --color=auto'
    fi
    alias ll='ls -alF'
    alias la='ls -A'
    alias l='ls -CF'
fi

alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# bat replaces cat (Debian ships it as batcat)
command -v batcat >/dev/null 2>&1 && alias cat='batcat'

# fd replaces find (Debian ships it as fdfind)
command -v fdfind >/dev/null 2>&1 && alias fd='fdfind'

# ccusage
alias ccusage='npx ccusage@latest'

# Load user aliases if present
[ -f "$HOME/.bash_aliases" ] && . "$HOME/.bash_aliases"

# --- Programmable completion ---
if ! shopt -oq posix; then
    if [ -f /usr/share/bash-completion/bash_completion ]; then
        . /usr/share/bash-completion/bash_completion
    elif [ -f /etc/bash_completion ]; then
        . /etc/bash_completion
    fi
fi

# --- git helpers ---

# Fetch all repos found in the given dir (default: current dir).
# Uses fetch-only — never merges, never creates conflicts.
gfetch() {
    local base="${1:-.}"
    local found=0
    for dir in "$base"/*/; do
        [[ -d "$dir/.git" ]] || continue
        found=1
        echo "→ $(basename "$dir")"
        git -C "$dir" fetch --all --prune 2>&1 | sed 's/^/  /'
    done
    (( found )) || echo "No git repos found in $base"
}

# --- tmux helpers ---
tnew() { tmux new -s "${1:-main}"; }
ta()   { tmux attach -t "${1:-main}"; }
tl()   { tmux list-sessions 2>/dev/null || echo "No tmux sessions"; }

# --- CLI completions (lazy-loaded — no startup cost) ---
# Each wrapper sources real completions on first Tab, then removes itself.
if command -v kubectl >/dev/null 2>&1; then
    _kubectl_lazy() { unset -f _kubectl_lazy; source <(kubectl completion bash) 2>/dev/null; return 124; }
    complete -F _kubectl_lazy kubectl
fi
if command -v flux >/dev/null 2>&1; then
    _flux_lazy() { unset -f _flux_lazy; source <(flux completion bash) 2>/dev/null; return 124; }
    complete -F _flux_lazy flux
fi
if command -v helm >/dev/null 2>&1; then
    _helm_lazy() { unset -f _helm_lazy; source <(helm completion bash) 2>/dev/null; return 124; }
    complete -F _helm_lazy helm
fi

# --- 1Password CLI sign-in helper ---
op-signin() {
    local token
    token=$(op signin --account scottvollmin --raw 2>/dev/null)
    if [[ -n "$token" ]]; then
        export OP_SESSION_scottvollmin="$token"
        echo "1Password: signed in"
    else
        echo "1Password: sign-in failed — run 'op signin' manually"
    fi
}

# --- SSH agent (Cursor forwarding) ---
# Re-attach to the live Cursor forwarded agent if the socket went stale.
# Only runs in SSH sessions to avoid unnecessary socket probing.
_refresh_ssh_auth_sock() {
    local sock
    for sock in /tmp/cursor-remote-ssh-auth-sock-*.sock; do
        [[ -S "$sock" ]] || continue
        SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1 || continue
        export SSH_AUTH_SOCK="$sock"
        return 0
    done
    return 1
}
[[ -n "$SSH_CONNECTION" ]] && _refresh_ssh_auth_sock

# --- fzf ---
[ -f "$HOME/.fzf.bash" ] && source "$HOME/.fzf.bash"

export FZF_CTRL_R_OPTS="--preview 'echo {}' --preview-window up:3:wrap"

# Search full shell history file with fzf (useful for dead-session history)
fh() {
    fzf --tac --no-sort --exact \
        --preview 'echo {}' \
        --preview-window up:3:wrap \
        < "$HISTFILE"
}

# --- zoxide (smart cd with frecency) ---
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"

# ble.sh attach — must be last, after fzf and all other readline customizations
[[ ${BLE_VERSION-} ]] && ble-attach
