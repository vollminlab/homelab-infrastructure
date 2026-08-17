# SSH Setup for Vollminlab

SSH access to all homelab hosts is managed through **1Password SSH agent**.
Keys are stored in 1Password; the agent exposes them locally via a socket/pipe.
No private key files on disk.

## Prerequisites

1. Follow the official 1Password SSH agent setup guide for your OS:
   **https://developer.1password.com/docs/ssh/agent/**
   This covers enabling the agent, OS-specific service configuration, and biometric unlock.

2. If any of your keys live outside the default Personal/Private vault, configure
   `~/.config/1Password/ssh/agent.toml` to include the additional vaults.
   See: https://developer.1password.com/docs/ssh/agent/advanced/

3. Copy the SSH config for your OS (see below) to `~/.ssh/config`.

4. Copy the public key files from `hosts/windows/ssh/*.pub` to `~/.ssh/`.
   (Safe to commit — public keys only. Private keys stay in 1Password.)

   **Two are missing from that directory**: the config's `devsbx01` and `ansible01` blocks
   reference `~/.ssh/devsbx01_id_ed25519.pub` and `~/.ssh/ansible01_id_ed25519.pub`, neither of
   which is committed. Export them from 1Password before using those two host aliases.

---

## SSH Config — the global `Host *` block

The host entries are identical across platforms. What differs is how the client reaches the
1Password agent.

**What is actually in [`hosts/windows/ssh/config`](../hosts/windows/ssh/config):**

```
Host *
  IdentitiesOnly yes
  ForwardAgent yes
```

There is **no `IdentityAgent` line** — on Windows the OpenSSH client finds the named pipe on its
own, so the line is unnecessary there. macOS and Linux must **add** one; there is nothing to
replace.

### Windows

Nothing to add. **Must use System32 OpenSSH**, not Git Bash's bundled ssh — Git Bash cannot reach
the named pipe.

To use System32 OpenSSH from Git Bash (e.g. in scripts):
```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"
```

### macOS

Add to the `Host *` block:

```
  IdentityAgent ~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock
```

### Linux (with 1Password desktop app)

Add to the `Host *` block:

```
  IdentityAgent ~/.1password/agent.sock
```

### Linux (CLI only / headless — no 1Password desktop app)

The 1Password SSH agent socket requires the desktop app. On headless or dev VMs,
use the `op` CLI to pull keys from 1Password and load them into a local ssh-agent.

Run this at the start of each session (keys don't persist across reboots):

```bash
eval $(op signin)
eval $(ssh-agent -s)

for item in haproxydmz01_id_ed25519 haproxydmz02_id_ed25519; do
  op item get "$item" --fields private_key --reveal --format json \
    | python3 -c "
import json,sys
from cryptography.hazmat.primitives.serialization import load_pem_private_key, Encoding, PrivateFormat, NoEncryption
key = load_pem_private_key(json.load(sys.stdin)['value'].encode(), None)
sys.stdout.buffer.write(key.private_bytes(Encoding.PEM, PrivateFormat.OpenSSH, NoEncryption()))
" > /tmp/sshkey && chmod 600 /tmp/sshkey && ssh-add /tmp/sshkey && rm /tmp/sshkey
done
```

Then point `~/.ssh/config` at the agent socket printed by `ssh-agent -s`. The shipped config has no
`IdentityAgent` line, so this **inserts** one rather than replacing it — a `sed
"s|IdentityAgent.*|…|"` is a silent no-op against the committed file:

```bash
sed -i "/^Host \*/a\\  IdentityAgent $SSH_AUTH_SOCK" ~/.ssh/config
```

**Why the conversion step?** 1Password stores Ed25519 keys in PKCS#8 format
(`-----BEGIN PRIVATE KEY-----`). OpenSSH's `ssh-add` requires OpenSSH wire format
(`-----BEGIN OPENSSH PRIVATE KEY-----`). The Python `cryptography` library handles
the conversion in-memory without writing the raw key to disk.

**Populate known_hosts** (first time on a new machine):

```bash
ssh-keyscan haproxydmz01.vollminlab.com haproxydmz02.vollminlab.com >> ~/.ssh/known_hosts
```

---

## Full config

See [`hosts/windows/ssh/config`](../hosts/windows/ssh/config) for the complete
host list. Add the `IdentityAgent` line for your OS as shown above — the file ships without one.

Copy to `~/.ssh/config`:

```bash
# macOS / Linux
cp hosts/windows/ssh/config ~/.ssh/config
# then add the IdentityAgent line for your OS to the Host * block
```

---

## Notes

- `IdentityFile` entries point to `.pub` files — this tells the agent *which*
  key to use. The private key stays in 1Password, never on disk.
- Each host has a dedicated key. Add new hosts to 1Password first, export the
  public key to `~/.ssh/`, then add a `Host` block to the config.
- The `collect-host-configs.sh` script requires System32 OpenSSH on Windows;
  it prepends the correct path automatically.
