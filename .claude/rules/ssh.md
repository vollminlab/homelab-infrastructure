---
description: SSH host aliases, 1Password agent setup, and Windows Git Bash caveat for homelab hosts
---

# SSH Rules

## Windows Git Bash caveat (critical)

Git Bash ships its own `ssh` binary that **cannot** reach the 1Password Windows named pipe (`\\.\pipe\openssh-ssh-agent`). Always prepend System32 OpenSSH before any SSH command from Claude Code:

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"
ssh pihole1  # now uses the correct ssh binary
```

Without this, you will get `Permission denied (publickey)` even though the user's interactive terminal works fine.

## SSH config

Config file: `hosts/windows/ssh/config` (copy to `~/.ssh/config` on the Windows machine).

All hosts use `IdentitiesOnly yes`. Private keys stay in 1Password; only `.pub` files are on disk as identity hints.

## Host aliases

| Alias | Hostname / IP | User | Notes |
|-------|--------------|------|-------|
| `pihole1` | 192.168.100.2 | vollmin | Primary Pi-hole |
| `pihole2` | 192.168.100.3 | vollmin | Secondary Pi-hole |
| `haproxy01` | haproxy01.vollminlab.com | vollmin | Internal LB MASTER |
| `haproxy02` | haproxy02.vollminlab.com | vollmin | Internal LB BACKUP |
| `haproxydmz01` | haproxydmz01.vollminlab.com | vollmin | DMZ LB MASTER |
| `haproxydmz02` | haproxydmz02.vollminlab.com | vollmin | DMZ LB BACKUP |
| `k8scp01` | k8scp01.vollminlab.com | vollmin | K8s control plane |
| `k8scp02` | k8scp02.vollminlab.com | vollmin | K8s control plane |
| `k8scp03` | k8scp03.vollminlab.com | vollmin | K8s control plane |
| `k8sworker01`–`k8sworker06` | k8sworker0N.vollminlab.com | vollmin | K8s workers |
| `esxi01`–`esxi03` | esxi0N.vollminlab.com | root | ESXi hosts |
| `truenas` | truenas.vollminlab.com | vollmin | TrueNAS |
| `udm` | 192.168.1.1 | root | UniFi Dream Machine |
| `nginx01` | nginx01.vollminlab.com | vollmin | Nginx Proxy Manager |
| `groupme01` | groupme01.vollminlab.com | vollmin | GroupMe bridge |

## Running commands on remote hosts

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"

# Single command
ssh pihole1 "sudo systemctl restart pihole-flask-api"

# With sudo and piped input
ssh k8scp01 "kubectl get nodes"
```

## 1Password CLI for secrets

Use `op read` for clean values (no extra formatting):

```bash
op read "op://Homelab/<item>/<field>"

# Example — pihole-flask-api token
op read "op://Homelab/recordimporter-api-token/password"
```

Avoid `op item get --field password` — it may return extra formatting characters.
