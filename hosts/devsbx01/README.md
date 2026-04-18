# devsbx01

Personal dev sandbox VM. Single user (`vollmin`).

## Bootstrap

### 1. apt packages

```bash
sudo apt install -y ripgrep fd-find bat jq eza zoxide git-delta
```

### 2. fzf (from source — Debian package is too old)

```bash
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --no-bash --no-zsh --no-fish
```

### 3. ble.sh (fish-style inline history autosuggestions)

```bash
git clone --recursive https://github.com/akinomyoga/ble.sh.git ~/.local/src/ble.sh
make -C ~/.local/src/ble.sh install PREFIX=~/.local
```

### 4. Copy configs

```bash
cp configs/.bashrc ~/
cp configs/.fzf.bash ~/
cp configs/.tmux.conf ~/
cp configs/.gitconfig ~/
source ~/.bashrc
```

## Tools installed

| Tool | Purpose |
|------|---------|
| `fzf` | Fuzzy finder — Ctrl-R history, Ctrl-T files |
| `ble.sh` | Inline history autosuggestions as you type |
| `eza` | Modern `ls` with git status and icons (requires Nerd Font in terminal) |
| `bat` / `batcat` | Syntax-highlighted `cat` |
| `fd` / `fdfind` | Fast, intuitive `find` replacement |
| `ripgrep` | Fast `grep` replacement, respects `.gitignore` |
| `zoxide` | Frecency-based `cd` — use `z <partial-path>` |
| `jq` | JSON processor |
| `delta` | Syntax-highlighted git diffs |
| `k9s` | Kubernetes TUI |

## Terminal font

Icons in `eza` require a Nerd Font in the terminal client — this is a **client-side requirement only**, nothing to install on the VM.

**DR note:** if icons appear as boxes after restoring this VM, the client terminal needs a Nerd Font (e.g. CaskaydiaCove NF) installed and selected — the VM config is correct as-is.

## Key shell bindings

| Key | Action |
|-----|--------|
| `Ctrl-R` | fzf history search |
| `Ctrl-T` | fzf file picker |
| `→` / `End` | Accept ble.sh inline suggestion |
| `z <name>` | Jump to frecent directory |
| `zi` | Interactive zoxide picker |
