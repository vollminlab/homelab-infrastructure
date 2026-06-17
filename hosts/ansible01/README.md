# ansible01

Ansible control node. Runs the playbooks from the `ansible-playbooks` repo against
the homelab — primarily rolling Kubernetes / OS upgrades on the k8s nodes.

> **Why this directory is sparse:** the inventory, `host_vars`, project `ansible.cfg`,
> and all playbooks live in the **`ansible-playbooks` repo** — their single source of
> truth — so they are deliberately **not** collected here. This directory holds only
> host-specific runtime state that exists nowhere else.

## Collected automatically

`scripts/collect-host-configs.sh ansible01` pulls:

| File | What |
| --- | --- |
| `ansible-version.txt` | `ansible --version` — exact Ansible + Python version and active config path. DR-critical for a faithful rebuild. |
| `galaxy-collections.txt` | `ansible-galaxy collection list` — the only record of installed collections (the repo has no `requirements.yml`). |
| `galaxy-roles.txt` | `ansible-galaxy role list` — the only record of installed roles. |
| `configs/ansible/ansible.cfg` | System-wide `/etc/ansible/ansible.cfg`, only if one exists. |
| `fstab`, `systemd/`, `scripts/`, `crontab-*` | Standard host set — catches scheduled playbook runs (systemd timers / cron) and wrapper scripts. |

No secrets are collected. The control node reaches managed hosts with a dedicated
SSH key (see below) that is never committed.

There is **no system-wide `/etc/ansible/ansible.cfg`** on this host — `ansible --version`
run from `$HOME` reports `config file = None`. The active config is the project
`ansible.cfg`, which lives in the `ansible-playbooks` repo and is only picked up when
Ansible runs from inside that checkout. `galaxy-collections.txt` is the collection
bundle shipped with the apt `ansible` package, installed at
`/usr/lib/python3/dist-packages/ansible_collections`.

## Bootstrap / DR

To rebuild ansible01:

1. **Install Ansible via apt** — `sudo apt install ansible` (the full `ansible` package,
   not `ansible-core`; it bundles the collections in `galaxy-collections.txt`). Match the
   version in `ansible-version.txt` — currently `core 2.16.3`, executable `/usr/bin/ansible`,
   Python 3.12.
2. **Clone the playbooks repo** — `git clone https://github.com/vollminlab/ansible-playbooks.git ~/ansible-playbooks`.
   Run all `ansible`/`ansible-playbook` commands from inside `~/ansible-playbooks` so the
   project `ansible.cfg` (and its `inventory/hosts.ini`) is picked up.
3. **Restore the outbound SSH key** — ansible authenticates to the k8s nodes with the
   **on-disk** key `~/.ssh/ansible_k8s_ed25519`. The project `ansible.cfg` pins it via
   `private_key_file` + `IdentitiesOnly=yes` (`remote_user = vollmin`), so this key — **not**
   the 1Password SSH agent — is what the control node uses outbound. (The 1Password agent
   only brokers *operator→host* logins; it is not in the ansible→k8s path. Verified by
   connecting to a node with the agent disabled.) The matching public key is already in
   `authorized_keys` on all 9 nodes, so only the private key needs restoring:

   ```bash
   op read "op://Homelab/ansible_k8s_ed25519/private key" > ~/.ssh/ansible_k8s_ed25519
   chmod 600 ~/.ssh/ansible_k8s_ed25519
   ```

   The key is backed up in 1Password (Homelab vault, item **`ansible_k8s_ed25519`**, field
   `private key`). It is stored as a concealed-field Secure Note rather than a native
   SSH-Key item because the `op` CLI cannot import an existing key into the SSH-Key category
   (it can only generate). **Never commit this key.**
4. **Reinstall any extra Galaxy content** — only needed if `galaxy-collections.txt` shows
   collections outside the apt bundle (none currently). `ansible-galaxy role list` reports no
   standalone roles installed.
5. **Verify** — from `~/ansible-playbooks`, run `ansible all -m ping`.

## TODO — to finish this doc

- [ ] Add ansible01 to the VM inventory table in `docs/infrastructure.md` (vCPU / RAM / disk / IP — from a vSphere re-export).
