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
- HAProxy VIP `192.168.152.7` — k8s **API** endpoint only (port 6443); not used for app HTTP/HTTPS traffic
- Kubernetes API endpoint: `192.168.152.7:6443`
- Configs in `hosts/` are snapshots; the live host is authoritative
- Secrets are **redacted** in collected configs; retrieve from 1Password (Homelab vault)

## Pi-hole DNS records

All records are A records. Three categories:

| Category | Type | Target | Examples |
|----------|------|--------|---------|
| Machine hostnames | A | Own IP | pihole1/2, esxi01-03, k8sworker01-06, haproxy01/02 |
| Cluster app subdomains | A | `192.168.152.244` (ingress-nginx) | homepage, radarr, shlink, go, vl |
| NPM-proxied infra | A | `192.168.152.2` (Nginx Proxy Manager) | pihole, plex, truenas, udm, vcenter, haproxy (stats) |
| Externally-accessible DMZ | CNAME | `dynamic.vollminlab.com` → public WAN IP | bluemap |

Managed via pihole-flask-api (port 5001, Bearer token from 1Password item `recordimporter-api-token`). Full record list in `hosts/pihole1/configs/pihole/pihole.toml`.

## DR notes

Restore procedures for each component are documented in `docs/infrastructure.md` under "DR Notes". etcd backup/restore is in `docs/etcd.md`.
