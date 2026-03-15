# SSH Setup for Vollminlab

SSH access to all homelab hosts is managed through **1Password SSH agent**.
Keys are stored in 1Password; the agent exposes them locally via a socket/pipe.
No private key files on disk.

## Prerequisites

1. Install [1Password](https://1password.com/downloads/) and enable the SSH agent:
   **Settings → Developer → Use the SSH agent**
2. Add each host's SSH key to 1Password (or generate new ones there).
3. Copy the SSH config for your OS (see below) to `~/.ssh/config`.
4. Copy the public key files referenced in the config to `~/.ssh/`.
   These are in `hosts/windows/ssh/` in this repo (safe to commit — public keys only).

---

## SSH Config — OS-specific `IdentityAgent` line

The host entries are identical across platforms. Only the `IdentityAgent` line
in the global `Host *` block differs.

### Windows

Uses the OpenSSH named pipe. **Must use System32 OpenSSH**, not Git Bash's
bundled ssh — Git Bash cannot reach the named pipe.

```
Host *
  IdentityAgent \\.\pipe\openssh-ssh-agent
  IdentitiesOnly no
```

To use System32 OpenSSH from Git Bash (e.g. in scripts):
```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"
```

### macOS

```
Host *
  IdentityAgent ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock
  IdentitiesOnly no
```

### Linux

```
Host *
  IdentityAgent ~/.1password/agent.sock
  IdentitiesOnly no
```

---

## Full config

See [`hosts/windows/ssh/config`](../hosts/windows/ssh/config) for the complete
host list. Replace the `IdentityAgent` line for your OS as shown above.

Copy to `~/.ssh/config`:

```bash
# macOS / Linux
cp hosts/windows/ssh/config ~/.ssh/config
# then edit the IdentityAgent line for your OS
```

---

## Notes

- `IdentityFile` entries point to `.pub` files — this tells the agent *which*
  key to use. The private key stays in 1Password, never on disk.
- Each host has a dedicated key. Add new hosts to 1Password first, export the
  public key to `~/.ssh/`, then add a `Host` block to the config.
- The `collect-host-configs.sh` script requires System32 OpenSSH on Windows;
  it prepends the correct path automatically.
