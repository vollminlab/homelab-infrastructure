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

## Bootstrap / DR

To rebuild ansible01:

1. **Install Ansible** — match the version recorded in `ansible-version.txt`.
   <!-- TODO: confirm install method on the host (apt / pipx / venv) and pin it here. -->
2. **Clone the playbooks repo** — `git clone <ansible-playbooks remote> <path>`.
   <!-- TODO: confirm the clone path on the host, e.g. ~/repos/ansible-playbooks. -->
3. **Restore the SSH key** — the project `ansible.cfg` uses `~/.ssh/ansible_k8s_ed25519`
   (`remote_user = vollmin`) to reach the k8s nodes. Restore it from 1Password to
   `~/.ssh/ansible_k8s_ed25519`, then `chmod 600`. **Never commit this key.**
   <!-- TODO: save the key to 1Password (Homelab vault) and record the item name here. -->
4. **Reinstall Galaxy content** — `ansible-galaxy collection install` / `role install`
   to match `galaxy-collections.txt` and `galaxy-roles.txt`.
5. **Verify** — `ansible all -m ping` against the inventory.

## TODO — to finish this doc

- [ ] Confirm the Ansible install method and pin it in step 1 (fill from `ansible-version.txt` after the first collection run).
- [ ] Confirm the `ansible-playbooks` clone path on the host (step 2).
- [ ] Save the `ansible_k8s_ed25519` key to 1Password (Homelab vault) and record the item name in step 3.
- [ ] Add ansible01 to the VM inventory table in `docs/infrastructure.md` (vCPU / RAM / disk / IP — from a vSphere re-export).
