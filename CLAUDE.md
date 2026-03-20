# CLAUDE.md — Vollminlab Homelab Infrastructure

Config snapshots, runbooks, and DR documentation for all non-Kubernetes homelab infrastructure. All data is collected from live hosts via `scripts/collect-all.sh`.

**Full infrastructure reference:** `docs/infrastructure.md`

## Essential reading before working

- `.claude/rules/ssh.md` — SSH host aliases, 1Password agent, Windows Git Bash caveat

## What lives here

| Directory | Contents |
|-----------|----------|
| `docs/` | Runbooks and reference docs (infrastructure, etcd, pihole-tls, ssh-setup) |
| `hosts/` | Collected configs from live hosts (pihole1, vsphere, windows/ssh) |
| `scripts/` | Collection and utility scripts |
| `bootstrap/` | Manual bootstrap procedures |

## Key facts

- DNS: Pi-hole HA pair at `192.168.100.2/3`, VIP `192.168.100.4`; DNS records managed via pihole-flask-api (`c:/git/pihole-flask-api`)
- Internal HAProxy VIP: `192.168.152.7` — all `*.vollminlab.com` app CNAMEs point here
- Kubernetes API endpoint: `192.168.152.7:6443`
- Configs in `hosts/` are snapshots; the live host is authoritative
- Secrets are **redacted** in collected configs; retrieve from 1Password (Homelab vault)

## Pi-hole DNS records

App subdomains are CNAMEs → `haproxyvip.vollminlab.com`. Only infrastructure IPs get A records. Managed via the pihole-flask-api (port 5001, Bearer token from 1Password item `recordimporter-api-token`).

## DR notes

Restore procedures for each component are documented in `docs/infrastructure.md` under "DR Notes". etcd backup/restore is in `docs/etcd.md`.
