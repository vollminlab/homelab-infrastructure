# Vollminlab Infrastructure Reference

Source of truth for all infrastructure configuration. Configs are collected from live hosts via `scripts/collect-all.sh` and stored in this repo. All data in this document is derived directly from collected configs — no assumptions.

---

## Network (UniFi Dream Machine SE)

### VLANs / Networks

| VLAN | Name          | Subnet               | DHCP   | Notes                              |
|------|---------------|----------------------|--------|------------------------------------|
| 1    | Default       | 192.168.1.0/24       | Server |                                    |
| 100  | Management    | 192.168.100.0/24     | Server | Pi-hole, internal DNS              |
| 110  | Trusted-Wired | 192.168.110.0/24     | Server |                                    |
| 120  | Trusted-WLAN  | 192.168.120.0/24     | Server | SSID: 20-Gardner                   |
| 130  | IoT-WLAN      | 192.168.130.0/24     | Server | SSID: 20GIoT                       |
| 140  | Guest-WLAN    | 192.168.140.0/24     | Server | SSID: 20-Gardner-Guest, portal auth |
| 150  | Lab           | 192.168.150.0/24     | Server | TrueNAS, Plex                      |
| 151  | VMWMgmt       | 192.168.151.0/24     | Server | ESXi host management               |
| 152  | VMWGuestNet   | 192.168.152.0/24     | /180   | VM workloads, Kubernetes           |
| 153  | VMWvMotion    | 192.168.153.0/24     | Server | ESXi vMotion                       |
| 154  | VMWStorage    | 192.168.154.0/24     | Server | iSCSI storage                      |
| 155  | VMWVCHA       | 192.168.155.0/28     | /13    | vCenter HA heartbeat               |
| 160  | DMZ           | 192.168.160.0/24     | /101   | Internet-facing proxy VMs          |

### WiFi SSIDs

| SSID             | Network       | Bands         | Security |
|------------------|---------------|---------------|----------|
| 20-Gardner       | Trusted-WLAN  | 2.4 GHz, 5 GHz | WPA2    |
| 20GIoT           | IoT-WLAN      | 2.4 GHz        | WPA2    |
| 20-Gardner-Guest | Guest-WLAN    | 2.4 GHz, 5 GHz | WPA2    |

### Port Forwards (WAN → Internal)

| Name                  | Proto | External Port | Internal Destination    |
|-----------------------|-------|---------------|-------------------------|
| haproxydmz-VIP-HTTP   | TCP   | 80            | 192.168.160.4:80        |
| haproxydmz-VIP-HTTPS  | TCP   | 443           | 192.168.160.4:443       |
| Minecraft External    | TCP   | 25565         | 192.168.160.4:25565     |

### Firewall Policy Summary

Traffic between zones follows a default-deny model. Custom rules are documented below; all other inter-zone traffic is either isolated or blocked by the catch-all rules at the end of each chain.

**WAN → Zones**

| Chain    | Policy                                                               |
|----------|----------------------------------------------------------------------|
| WAN_LAN  | Allow return traffic only; block invalid; block all                  |
| WAN_DMZ  | Allow port forwards (HTTP/80, HTTPS/443, Minecraft/25565); allow return; block invalid; block all |
| WAN_GUEST| Allow return traffic only; block invalid; block all                  |
| WAN_VPN  | Allow return traffic only; block invalid; block all                  |
| WAN_LOCAL| Allow return traffic; block invalid; allow WireGuard; block all      |

**LAN → Zones**

| Chain     | Custom Rules                                                                |
|-----------|-----------------------------------------------------------------------------|
| LAN_WAN   | Allow Pihole → Internet (DNS); reject all other internal → external DNS; allow all |
| LAN_LAN   | Allow IoT-WLAN → Pihole (DNS); allow Admin Devices → Management; allow IoT return; allow Plex ↔ IoT-WLAN; isolated networks; allow all |
| LAN_DMZ   | Allow DMZ → Pihole DNS (return); allow haproxydmz → k8sworker05 Minecraft (return); allow haproxydmz → k8sworker05 Bluemap (return); isolated networks; allow all |
| LAN_GUEST | Allow Pihole ↔ Hotspot (DNS); isolated networks; allow all                  |
| LAN_VPN   | Allow VPN → Pihole DNS (return); allow all                                  |

**DMZ → Zones**

| Chain    | Custom Rules                                                                |
|----------|-----------------------------------------------------------------------------|
| DMZ_LAN  | Allow DMZ → Pihole (DNS); allow haproxydmz → k8sworker05 (Minecraft); allow haproxydmz → k8sworker05 (Bluemap); allow return; block all |
| DMZ_WAN  | Reject DMZ → external DNS; block invalid; allow all                         |
| DMZ_DMZ  | Block all                                                                   |
| DMZ_VPN  | Allow return; block all                                                     |
| DMZ_LOCAL| Allow DNS, ICMP, DHCP, return; block all                                    |

**Guest → Zones**

| Chain      | Custom Rules                                                              |
|------------|---------------------------------------------------------------------------|
| GUEST_LAN  | Allow Hotspot → Pihole (DNS); allow public DNS; post-auth restrictions; allow return; block all |
| GUEST_WAN  | Reject Hotspot → external DNS; allow public DNS; allow hotspot portal; post-auth restrictions; block unauthorized; block invalid; allow all |
| GUEST_GUEST| Allow public DNS; post-auth restrictions; block all                       |
| GUEST_LOCAL| Allow mDNS, DNS, ICMP, DHCP, return; block all                            |

**VPN → Zones**

| Chain    | Custom Rules                                              |
|----------|-----------------------------------------------------------|
| VPN_LAN  | Allow VPN → Pihole (DNS); allow all                       |
| VPN_WAN  | Reject VPN → external DNS; block invalid; allow all       |
| VPN_DMZ  | Allow all                                                 |

---

## DNS (Pi-hole)

| Host    | IP              | Role                                    |
|---------|-----------------|-----------------------------------------|
| pihole1 | 192.168.100.2   | Primary — keepalived MASTER (priority 10) |
| pihole2 | 192.168.100.3   | Secondary — keepalived BACKUP (priority 9) |
| VIP     | 192.168.100.4   | VRRP virtual IP (VLAN 100, /24)         |

- VRRP instance: `piholeHA`, virtual router ID 1, unicast peering
- Upstream resolver: `127.0.0.1#5335` (Unbound, local on each host)
- CNAME deep inspection: enabled
- ESNI blocking: enabled
- Web UI: HTTPS, self-signed EC P-256 cert at `/etc/pihole/tls.pem` — see [pihole-tls.md](pihole-tls.md)
- Config sync: nebula-sync (runs on pihole1, replicates to pihole2)

**Root crontab (both hosts):**

| Schedule            | Job                                          |
|---------------------|----------------------------------------------|
| 01:05 on 15th, */3mo | Refresh Unbound root hints                  |
| 01:10 on 15th, */3mo | Restart Unbound                             |
| Every 15 minutes    | `pihole-healthcheck.sh` (FTL status, disk, NTP) |

---

## Virtualization (vSphere)

### ESXi Hosts

| Host   | Management IP   | vMotion IP      | iSCSI-1 IP      | iSCSI-2 IP      | Version | Build    |
|--------|-----------------|-----------------|-----------------|-----------------|---------|----------|
| esxi01 | 192.168.151.2   | 192.168.153.2   | 192.168.154.2   | 192.168.154.5   | 8.0.3   | 24859861 |
| esxi02 | 192.168.151.3   | 192.168.153.3   | 192.168.154.3   | 192.168.154.6   | 8.0.3   | 24859861 |
| esxi03 | 192.168.151.4   | 192.168.153.4   | 192.168.154.4   | 192.168.154.7   | 8.0.3   | 24859861 |

Hardware: Minisforum MS-01. NTP: pool.ntp.org.
vSphere reports 6 CPUs (P-cores only) / 12 logical processors per host, 95.74 GB usable RAM (96 GB physical). E-cores not presented to the hypervisor.

### vCenter (VCHA)

Three-node vCenter HA cluster — active, passive, witness — one per ESXi host. Management NIC on VLAN 151, VCHA heartbeat NIC on VLAN 155.

| VM               | Role    | Network  |
|------------------|---------|----------|
| vcenter          | Active  | 151, 155 |
| vcenter-Passive  | Passive | 151, 155 |
| vcenter-Witness  | Witness | 151, 155 |

### Cluster

- Name: `vollminlab-ESXi-Cluster`
- HA: enabled, failover level 1, admission control enabled
- DRS: enabled, partially automated (level 1)
- EVC: not configured

### Distributed vSwitch

- Name: `DSwitch0`, MTU 9000 (jumbo frames), 2 uplinks, all 3 hosts connected

### Port Groups

| Port Group          | VLAN | Purpose              |
|---------------------|------|----------------------|
| 151-DPG-Management  | 151  | ESXi / vCenter mgmt  |
| 152-DPG-GuestNet    | 152  | VM workloads         |
| 153-DPG-vMotion     | 153  | vMotion              |
| 154-DPG-iSCSI-1     | 154  | iSCSI path 1         |
| 154-DPG-iSCSI-2     | 154  | iSCSI path 2         |
| 155-DPG-VCHA        | 155  | vCenter HA           |
| 160-DPG-DMZ         | 160  | DMZ VMs              |

### Datastores

| Name         | Type | Capacity    | Free       | Notes              |
|--------------|------|-------------|------------|--------------------|
| vmstore1     | VMFS | 1433.5 GB   | ~716 GB    | Shared iSCSI       |
| vmstore2     | VMFS | 1433.5 GB   | ~826 GB    | Shared iSCSI       |
| esxi01-local | VMFS | 825.75 GB   | —          | Local to esxi01    |
| esxi02-local | VMFS | 825.75 GB   | —          | Local to esxi02    |
| esxi03-local | VMFS | 825.75 GB   | —          | Local to esxi03    |

iSCSI target: `iscsi.vollminlab.com` / `192.168.150.2:3260`, software initiator (vmhba64), dual-path on all ESXi hosts.

### VM Inventory

VM host placement is not tracked here — DRS manages placement dynamically.

#### Kubernetes

| VM          | vCPU | RAM   | Disk   | Datastore | Network    | IP (from nodes.yaml)  |
|-------------|------|-------|--------|-----------|------------|-----------------------|
| k8scp01     | 4    | 8 GB  | 50 GB  | vmstore1  | GuestNet   | 192.168.152.8         |
| k8scp02     | 4    | 8 GB  | 50 GB  | vmstore1  | GuestNet   | 192.168.152.9         |
| k8scp03     | 4    | 8 GB  | 50 GB  | vmstore2  | GuestNet   | 192.168.152.10        |
| k8sworker01 | 4    | 8 GB  | 50 GB  | vmstore2  | GuestNet   | 192.168.152.11        |
| k8sworker02 | 4    | 8 GB  | 50 GB  | vmstore1  | GuestNet   | 192.168.152.12        |
| k8sworker03 | 4    | 8 GB  | 50 GB  | vmstore2  | GuestNet   | 192.168.152.13        |
| k8sworker04 | 4    | 8 GB  | 50 GB  | vmstore1  | GuestNet   | 192.168.152.14        |
| k8sworker05 | 8    | 32 GB | 100 GB | vmstore2  | GuestNet   | 192.168.152.15        |
| k8sworker06 | 8    | 32 GB | 100 GB | vmstore2  | GuestNet   | 192.168.152.16        |

#### Infrastructure VMs

> IPs sourced from `hosts/vsphere/vms.json` guest data. Run `scripts/Export-VSphereConfigs.ps1` to refresh.

| VM           | vCPU | RAM  | Disk   | Datastore | Network  | IP              |
|--------------|------|------|--------|-----------|----------|-----------------|
| haproxy01    | 2    | 2 GB | 20 GB  | vmstore1  | GuestNet | 192.168.152.5   |
| haproxy02    | 2    | 2 GB | 20 GB  | vmstore2  | GuestNet | 192.168.152.6   |
| haproxydmz01 | 2    | 2 GB | 50 GB  | vmstore2  | DMZ      | 192.168.160.2   |
| haproxydmz02 | 2    | 2 GB | 50 GB  | vmstore2  | DMZ      | 192.168.160.3   |
| nginx01      | 1    | 2 GB | 50 GB  | vmstore1  | GuestNet | 192.168.152.2   |
| groupme01    | 1    | 2 GB | 50 GB  | vmstore1  | GuestNet | see vms.json    |

---

## Kubernetes

- Version: 1.32.3
- Control plane endpoint: `192.168.152.7:6443` (HAProxy VIP)
- Pod subnet: `172.18.0.0/16`
- Service subnet: `10.96.0.0/12`
- etcd: local at `/var/lib/etcd`
- API server encryption: enabled
- CNI: Calico v3.29.1
- GitOps: Flux (repo: `k8s-vollminlab-cluster`)
- Storage: Longhorn v1.8.1

Node pod CIDRs are assigned sequentially from 172.18.0.0/16 (e.g., k8scp01 = 172.18.0.0/24).

---

## Load Balancing

### Internal HAProxy (haproxy01 / haproxy02)

| Item          | Value                                   |
|---------------|-----------------------------------------|
| VIP           | 192.168.152.7/24 (VRRP ID 51)          |
| haproxy01     | 192.168.152.5 — MASTER (priority 110)  |
| haproxy02     | 192.168.152.6 — BACKUP (priority 100)  |
| Health check  | `pidof haproxy`, weight -5              |
| Notify master | `/usr/local/bin/haproxy-start.sh`       |
| Notify backup | `/usr/local/bin/haproxy-stop.sh`        |

**Backends:**

| Frontend     | Backend                                     | Mode |
|--------------|---------------------------------------------|------|
| `*:6443`     | k8scp01/02/03 at .8/.9/.10:6443            | TCP  |
| `*:8404`     | Stats page (authenticated)                  | HTTP |

### DMZ HAProxy (haproxydmz01 / haproxydmz02)

| Item          | Value                                    |
|---------------|------------------------------------------|
| VIP           | 192.168.160.4/24 (VRRP ID 60)           |
| haproxydmz01  | 192.168.160.2 — MASTER (priority 200)   |
| haproxydmz02  | 192.168.160.3 — BACKUP (priority 180)   |
| Health check  | `pgrep -x haproxy`, fall 2, rise 2       |

**Backends:**

| Frontend           | Backend / Action                             |
|--------------------|----------------------------------------------|
| `*:80`             | Redirect to HTTPS                            |
| `*:443` (default)  | 404                                          |
| `bluemap.vollminlab.com:443` | NodePort 32566              |
| `*:25565`          | NodePort 32565 (Minecraft)                   |

Rate limit: 100 connections/sec. Connection limit: 200 per backend server.

**Certificate sync:** `sync-haproxy-cert.sh` on haproxydmz01 — merges Let's Encrypt fullchain + key, deploys to both DMZ proxies via SSH, reloads HAProxy.

---

## Reverse Proxy (Nginx Proxy Manager)

- Host: nginx01 (192.168.152.2)
- Docker Compose on Debian, MariaDB backend
- Admin: `https://npm.vollminlab.com` (port 81, self-proxied)
- Wildcard cert: `*.vollminlab.com` via Let's Encrypt (expires 2026-06-10)

| Domain                 | Backend                    |
|------------------------|----------------------------|
| haproxy.vollminlab.com | 192.168.152.7:8404         |
| npm.vollminlab.com     | 192.168.152.2:81           |
| pihole.vollminlab.com  | 192.168.100.4:80           |
| plex.vollminlab.com    | 192.168.150.2:32400        |
| truenas.vollminlab.com | 192.168.150.2:80           |
| udm.vollminlab.com     | 192.168.1.1:443 (HTTPS)    |

---

## Storage (TrueNAS SCALE)

- Host: `truenas.vollminlab.com`, IP: 192.168.150.2
- Gateway: 192.168.150.1
- DNS: 192.168.100.4 (primary), 192.168.100.2, 192.168.100.3

### Pools

| Pool   | Layout | Raw    | Allocated | Free    | Disks              |
|--------|--------|--------|-----------|---------|--------------------|
| pool_0 | RaidZ2 | 40 TB  | ~13.8 TB  | ~26 TB  | 5× (sda2–sde2)     |
| pool_1 | Mirror | 4 TB   | ~761 GB   | ~3.3 TB | 2× (sdf1, sdg1)    |

### SMB Shares

| Share                | Path                                  |
|----------------------|---------------------------------------|
| movies               | /mnt/pool_0/movies                    |
| tv                   | /mnt/pool_0/tv                        |
| completed-downloads  | /mnt/pool_0/completed-downloads       |
| incomplete-downloads | /mnt/pool_0/incomplete-downloads      |
| smb-generic          | /mnt/pool_0/smb-generic              |

### NFS Shares

| Path                         | Allowed Network     | Purpose               |
|------------------------------|---------------------|-----------------------|
| /mnt/pool_0/vcenter_backups  | 192.168.151.0/24    | vCenter backup target |

### Services

| Service | Enabled |
|---------|---------|
| CIFS    | Yes     |
| iSCSI   | Yes     |
| NFS     | Yes     |
| SSH     | Yes     |
| SMART   | Yes     |
| FTP     | No      |
| SNMP    | No      |

---

## Application Services

### GroupMe Bridge (groupme01)

- VM on GuestNet (192.168.152.x — see vms.json)
- Systemd service: `groupme-daemon.service` (Python, 30s poll interval)
- Hardened: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`
- Auto-restarts on failure

---

## Credentials

All secrets stored in **1Password** (Homelab vault), retrieved at runtime via `op` CLI. Sensitive fields in collected configs are tagged `REDACTED`.

| Service  | 1Password Item        |
|----------|-----------------------|
| vCenter  | vCenter local user SSO (`vollmin@vsphere.local`) |
| NPM      | (Homelab vault)       |
| TrueNAS  | truenas_api (API key) |
| SSH keys | SSH agent items       |

---

## DR Notes

- **Pi-hole:** Configs replicated live by nebula-sync. Rebuild: reinstall, restore `pihole.toml`, restart FTL. TLS cert must be regenerated — see [pihole-tls.md](pihole-tls.md).
- **HAProxy:** Stateless — restore from `haproxy.cfg` + `keepalived.conf` in this repo.
- **NPM:** Restore via docker-compose + import proxy config from `hosts/nginx01/npm/`.
- **TrueNAS:** Pool layout and share config in this repo. Pools depend on physical disk layout.
- **Kubernetes:** Flux repo re-bootstraps all workloads. Sealed Secrets sealing key backup documented in `k8s-vollminlab-cluster` bootstrap dir.
- **vSphere:** Full config snapshot in `hosts/vsphere/`. vCSA file-based backup target: `/mnt/pool_0/vcenter_backups` on TrueNAS (NFS, accessible from 192.168.151.0/24).
