# Vollminlab Infrastructure Reference

Source of truth for all infrastructure configuration. Configs are collected from live hosts via `scripts/collect-all.sh` and stored in this repo.

---

## Network Overview

### VLAN Table

| VLAN | Subnet              | Name          | Purpose                          |
|------|---------------------|---------------|----------------------------------|
| 1    | 192.168.1.0/24      | Default/LAN   | Physical LAN, UDM management     |
| 100  | 192.168.100.0/24    | DNS           | Pi-hole DNS servers              |
| 150  | 192.168.150.0/24    | Storage       | TrueNAS, Plex                    |
| 151  | 192.168.151.0/24    | Management    | ESXi host management             |
| 152  | 192.168.152.0/24    | GuestNet      | VMs, Kubernetes nodes            |
| 153  | 192.168.153.0/24    | vMotion       | ESXi vMotion traffic             |
| 154  | 192.168.154.0/24    | iSCSI         | iSCSI storage traffic (2 paths)  |
| 155  | 192.168.155.0/24    | VCHA          | vCenter HA heartbeat             |
| 160  | 192.168.160.0/24    | DMZ           | Internet-facing proxy VMs        |

### DNS / Domain

- Domain: `vollminlab.com`
- Internal DNS: 192.168.100.4 (VIP), 192.168.100.2 (pihole1), 192.168.100.3 (pihole2)
- Wildcard cert: `*.vollminlab.com` (Let's Encrypt, managed by NPM, expires 2026-06-10)

---

## Host Inventory

### Physical / Router

| Host    | IP            | Role                          |
|---------|---------------|-------------------------------|
| udm     | 192.168.1.1   | UniFi Dream Machine SE — router, switch, firewall, WiFi |

### DNS (Pi-hole)

| Host    | IP              | Role                  |
|---------|-----------------|-----------------------|
| pihole1 | 192.168.100.2   | Pi-hole primary, Unbound, keepalived MASTER |
| pihole2 | 192.168.100.3   | Pi-hole secondary, Unbound, keepalived BACKUP |
| —       | 192.168.100.4   | Keepalived VIP (DNS entry point) |

**Keepalived:** VRRP instance `piholeHA`, virtual router ID 1, unicast peering. pihole1 priority 10, pihole2 priority 9.

**Pi-hole config:**
- Upstream: `127.0.0.1#5335` (local Unbound on each host)
- CNAME deep inspection: enabled
- ESNI blocking: enabled
- Web UI: HTTPS on self-signed EC P-256 cert at `/etc/pihole/tls.pem` (see [pihole-tls.md](pihole-tls.md))
- Config synced between units via [nebula-sync](https://github.com/lovelaze/nebula-sync) (runs on pihole1)

**Unbound maintenance (root crontab on both piholes):**
- 1st of every 3rd month at 01:05 — refresh root hints
- 01:10 — restart Unbound
- Every 15 min — `pihole-healthcheck.sh` (FTL status check, /var/log usage, NTP sync check)

### Virtualization (vSphere)

**vCenter:**

| Host            | IP               | VLAN | Role                        |
|-----------------|------------------|------|-----------------------------|
| vcenter         | 192.168.151.x    | 151  | Active vCSA                 |
| vcenter-Passive | 192.168.151.x    | 151  | VCHA passive node           |
| vcenter-Witness | 192.168.151.x    | 151  | VCHA witness node           |

- vCenter HA (VCHA) enabled — active/passive/witness across all 3 ESXi hosts
- Management and VCHA NICs on each vCSA appliance

**ESXi Hosts:**

| Host   | Mgmt (vmk0)     | vMotion (vmk1)  | iSCSI-1 (vmk2)  | iSCSI-2 (vmk3)  | CPU | RAM    | Build    |
|--------|-----------------|-----------------|-----------------|-----------------|-----|--------|----------|
| esxi01 | 192.168.151.2   | 192.168.153.2   | 192.168.154.2   | 192.168.154.5   | 6   | 95.7GB | 24859861 |
| esxi02 | 192.168.151.3   | 192.168.153.3   | 192.168.154.3   | 192.168.154.6   | 6   | 95.7GB | 24859861 |
| esxi03 | 192.168.151.4   | 192.168.153.4   | 192.168.154.4   | 192.168.154.7   | 6   | 95.7GB | 24859861 |

- ESXi version: 8.0.3
- NTP: pool.ntp.org

**Cluster:** `vollminlab-ESXi-Cluster`
- HA: enabled, 1 failover host level, admission control enabled
- DRS: enabled, automation level 1 (partially automated)
- EVC: not configured

**Distributed vSwitch:** `DSwitch0`
- MTU: 9000 (jumbo frames)
- 2 uplink ports, all 3 ESXi hosts connected

**Port Groups:**

| Port Group         | VLAN | Purpose             |
|--------------------|------|---------------------|
| 151-DPG-Management | 151  | ESXi / vCenter mgmt |
| 152-DPG-GuestNet   | 152  | VM workloads        |
| 153-DPG-vMotion    | 153  | vMotion             |
| 154-DPG-iSCSI-1    | 154  | iSCSI path 1        |
| 154-DPG-iSCSI-2    | 154  | iSCSI path 2        |
| 155-DPG-VCHA       | 155  | vCenter HA          |
| 160-DPG-DMZ        | 160  | DMZ VMs             |

**Datastores:**

| Name          | Type  | Capacity  | Free    | Notes              |
|---------------|-------|-----------|---------|--------------------|
| vmstore1      | VMFS  | 1433.5 GB | ~716 GB | Shared iSCSI       |
| vmstore2      | VMFS  | 1433.5 GB | ~826 GB | Shared iSCSI       |
| esxi01-local  | VMFS  | 825.75 GB | —       | Local to esxi01    |
| esxi02-local  | VMFS  | 825.75 GB | —       | Local to esxi02    |
| esxi03-local  | VMFS  | 825.75 GB | —       | Local to esxi03    |

iSCSI target: `iscsi.vollminlab.com` / `192.168.150.2:3260`, software initiator (vmhba64) on all hosts.

### VM Inventory

#### Kubernetes

| VM        | vCPU | RAM  | Disk  | Datastore | ESXi Host | IP (GuestNet) |
|-----------|------|------|-------|-----------|-----------|---------------|
| k8scp01   | 4    | 8 GB | 50 GB | vmstore1  | esxi01    | 192.168.152.8 |
| k8scp02   | 4    | 8 GB | 50 GB | vmstore1  | esxi02    | 192.168.152.9 |
| k8scp03   | 4    | 8 GB | 50 GB | vmstore2  | esxi03    | 192.168.152.10 |
| k8sworker01 | 4  | 8 GB | 50 GB | vmstore2  | esxi03    | 192.168.152.x |
| k8sworker02 | 4  | 8 GB | 50 GB | vmstore1  | esxi03    | 192.168.152.x |
| k8sworker03 | 4  | 8 GB | 50 GB | vmstore2  | esxi02    | 192.168.152.x |
| k8sworker04 | 4  | 8 GB | 50 GB | vmstore1  | esxi03    | 192.168.152.x |
| k8sworker05 | 8  | 32 GB | 100 GB | vmstore2 | esxi02   | 192.168.152.x |
| k8sworker06 | 8  | 32 GB | 100 GB | vmstore2 | esxi01   | 192.168.152.x |

#### Infrastructure VMs

| VM            | vCPU | RAM  | Disk  | Datastore | ESXi Host | IP              | Network  |
|---------------|------|------|-------|-----------|-----------|-----------------|----------|
| haproxy01     | 2    | 2 GB | 20 GB | vmstore1  | esxi02    | 192.168.152.5   | GuestNet |
| haproxy02     | 2    | 2 GB | 20 GB | vmstore2  | esxi01    | 192.168.152.6   | GuestNet |
| haproxydmz01  | 2    | 2 GB | 50 GB | vmstore2  | esxi01    | 192.168.160.2   | DMZ      |
| haproxydmz02  | 2    | 2 GB | 50 GB | vmstore2  | esxi02    | 192.168.160.3   | DMZ      |
| nginx01       | 1    | 2 GB | 50 GB | vmstore1  | esxi02    | 192.168.152.2   | GuestNet |
| groupme01     | 1    | 2 GB | 50 GB | vmstore1  | esxi01    | 192.168.152.x   | GuestNet |

---

## Kubernetes

- Version: 1.32.3
- Control plane endpoint: `192.168.152.7:6443` (HAProxy VIP)
- Pod subnet: `172.18.0.0/16`
- Service subnet: `10.96.0.0/12`
- etcd: local at `/var/lib/etcd`
- API server encryption: enabled
- CNI: Calico (not managed by Flux; state stored in `k8s-vollminlab-cluster` repo)
- GitOps: Flux (repo: `k8s-vollminlab-cluster`)

Node distribution: 3 control plane nodes across all 3 ESXi hosts (one per host). Workers spread across esxi01–03.

---

## Load Balancing

### Internal HAProxy (haproxy01 / haproxy02)

| Item           | Value                              |
|----------------|------------------------------------|
| VIP            | 192.168.152.7/24                   |
| VRRP instance  | VI_1, virtual router ID 51         |
| haproxy01      | 192.168.152.5, MASTER (priority 110) |
| haproxy02      | 192.168.152.6, BACKUP (priority 100) |
| Failover       | HAProxy pidof health check, weight -5 |

**Backends:**
- Kubernetes API (`*:6443`) → k8scp01/02/03 at 192.168.152.8–10:6443 (TCP mode)
- Stats page: `:8404` (authenticated)

### DMZ HAProxy (haproxydmz01 / haproxydmz02)

| Item           | Value                              |
|----------------|------------------------------------|
| VIP            | 192.168.160.4/24                   |
| VRRP instance  | VI_60, virtual router ID 60        |
| haproxydmz01   | 192.168.160.2, MASTER (priority 200) |
| haproxydmz02   | 192.168.160.3, BACKUP (priority 180) |

**Backends:**
- HTTP → redirect to HTTPS
- HTTPS → SNI-based routing, SSL termination
  - `bluemap.vollminlab.com` → NodePort 32566
  - Minecraft → NodePort 32565 (port 25565)
- Rate limiting: 100 connections/sec max
- Connection limit: 200 concurrent per backend server

**Certificate sync:** `sync-haproxy-cert.sh` on haproxydmz01 — copies Let's Encrypt cert (fullchain + key combined) to both DMZ proxies and reloads HAProxy.

---

## Reverse Proxy (Nginx Proxy Manager)

- Host: nginx01 (192.168.152.2)
- Admin UI: `http://npm.vollminlab.com` (port 81, proxied via NPM itself)
- Docker Compose: MariaDB backend, ports 80/81/443
- Config collected via REST API to `hosts/nginx01/npm/`

**Proxy Hosts:**

| Domain                      | Backend                      | Notes                  |
|-----------------------------|------------------------------|------------------------|
| haproxy.vollminlab.com      | 192.168.152.7:8404           | HAProxy stats          |
| npm.vollminlab.com          | 192.168.152.2:81             | NPM admin UI           |
| pihole.vollminlab.com       | 192.168.100.4:80             | Pi-hole web UI via VIP |
| plex.vollminlab.com         | 192.168.150.2:32400          | Plex Media Server      |
| truenas.vollminlab.com      | 192.168.150.2:80             | TrueNAS web UI         |
| udm.vollminlab.com          | 192.168.1.1:443 (HTTPS)      | UniFi controller       |

All proxy hosts use the wildcard `*.vollminlab.com` Let's Encrypt certificate.

---

## Storage (TrueNAS SCALE)

- Host: truenas.vollminlab.com (192.168.150.2)
- Gateway: 192.168.150.1
- DNS: 192.168.100.4 (primary), .2, .3

### Storage Pools

| Pool   | Layout | Raw Capacity | Allocated | Free   | Disks        |
|--------|--------|-------------|-----------|--------|--------------|
| pool_0 | RaidZ2 | 40 TB       | ~13.8 TB  | ~26 TB | 5× sda2–sde2 |
| pool_1 | Mirror | 4 TB        | ~761 GB   | ~3.3 TB| 2× sdf1,sdg1 |

### SMB Shares

| Share                | Path                          | Notes                        |
|----------------------|-------------------------------|------------------------------|
| movies               | /mnt/pool_0/movies            | Media                        |
| tv                   | /mnt/pool_0/tv                | Media                        |
| completed-downloads  | /mnt/pool_0/completed-downloads | SABnzbd output             |
| incomplete-downloads | /mnt/pool_0/incomplete-downloads | SABnzbd in-progress       |
| smb-generic          | /mnt/pool_0/smb-generic       | General purpose share        |

All SMB shares: ACL enabled, shadow copy enabled, AFP-compatible streams.

### NFS Shares

| Path                        | Allowed Network       | Notes              |
|-----------------------------|-----------------------|--------------------|
| /mnt/pool_0/vcenter_backups | 192.168.151.0/24      | vCenter backup target |

### Services

| Service | State   |
|---------|---------|
| CIFS    | Enabled |
| iSCSI   | Enabled |
| NFS     | Enabled |
| SSH     | Enabled |
| SMART   | Enabled |
| FTP     | Disabled |
| SNMP    | Disabled |

iSCSI target available at `iscsi.vollminlab.com` / `192.168.150.2:3260` — consumed by all 3 ESXi hosts via dual-path software initiators.

---

## Application Services

### GroupMe Bridge (groupme01)

- VM: groupme01 (192.168.152.x, GuestNet)
- Service: Python daemon managed by systemd (`groupme-daemon.service`)
- Poll interval: 30 seconds
- Hardened: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`
- Auto-restarts on failure

---

## Credentials & Secrets

All secrets are stored in **1Password** (Homelab vault) and retrieved at runtime via the `op` CLI. Nothing is stored in plaintext in this repo. Sensitive fields in collected configs are redacted (tagged `REDACTED`).

| Service     | 1Password Item                | Notes                              |
|-------------|-------------------------------|------------------------------------|
| vCenter     | vCenter local user SSO        | `vollmin@vsphere.local`            |
| NPM         | (Homelab vault)               | Admin email + password             |
| TrueNAS     | truenas_api                   | API key (Bearer token)             |
| SSH keys    | SSH agent items               | Ed25519 keys, per-host hints       |

---

## Key Repositories

| Repo                        | Purpose                                           |
|-----------------------------|---------------------------------------------------|
| `homelab-infrastructure`    | This repo — config snapshots, DR reference        |
| `k8s-vollminlab-cluster`    | Flux GitOps repo — all Kubernetes workloads       |

---

## DR Notes

- **Pi-hole:** Configs synced live via nebula-sync. Rebuild: reinstall Pi-hole, restore `pihole.toml`, restart FTL. TLS cert must be regenerated (see [pihole-tls.md](pihole-tls.md)).
- **HAProxy:** Stateless — restore from `haproxy.cfg` + `keepalived.conf` in this repo.
- **NPM:** Restore docker-compose, import proxy host config from `hosts/nginx01/npm/`.
- **TrueNAS:** Pool config and share config in this repo. Datasets and disks are the DR risk — document pool layout above.
- **Kubernetes:** Flux repo re-bootstraps all workloads. Node configs (kubeadm, kubelet) in `hosts/k8s/`. Sealed Secrets sealing key backup documented in `k8s-vollminlab-cluster` bootstrap dir.
- **vSphere:** Full config snapshot in `hosts/vsphere/`. vCSA backup target: `/mnt/pool_0/vcenter_backups` on TrueNAS via NFS.
