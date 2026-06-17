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
3. **Restore the SSH key** — the project `ansible.cfg` uses `~/.ssh/ansible_k8s_ed25519`
   (`remote_user = vollmin`) to reach the k8s nodes. Restore it from 1Password to
   `~/.ssh/ansible_k8s_ed25519`, then `chmod 600`. **Never commit this key.**
   <!-- TODO: save the key to 1Password (Homelab vault) and record the item name here. -->
4. **Reinstall any extra Galaxy content** — only needed if `galaxy-collections.txt` shows
   collections outside the apt bundle (none currently). `ansible-galaxy role list` reports no
   standalone roles installed.
5. **Verify** — from `~/ansible-playbooks`, run `ansible all -m ping`.

## TODO — to finish this doc

- [ ] Save the `ansible_k8s_ed25519` key to 1Password (Homelab vault) and record the item name in step 3. The private key is present on the host (`~/.ssh/ansible_k8s_ed25519`, `0600`) — confirm it is backed up before relying on this DR path.
- [ ] Add ansible01 to the VM inventory table in `docs/infrastructure.md` (vCPU / RAM / disk / IP — from a vSphere re-export).
