# Vollminlab Infrastructure Reference

Source of truth for all infrastructure configuration. Configs are collected from live hosts via `scripts/collect-all.sh` and stored in this repo. All data in this document is derived directly from collected configs — no assumptions.

**This doc can only be as fresh as the snapshot underneath it.** Collection is manual and per-area,
so the directories under `hosts/` age at different rates. Before trusting a section, check when its
source was last collected:

```bash
git log --format='%ad %h' --date=short -1 -- hosts/<area>
```

Numbers that move on their own — software versions, free space, certificate expiry dates — are
deliberately **not** written into this document. They are named with the command or file that
yields the live value instead, because a number recorded here goes stale silently and reads as
authoritative while it does so.

---

## Network (UniFi Dream Machine SE)

### VLANs / Networks

Every VLAN's gateway is `.1` of its own subnet, every DHCP server is enabled, and every lease is
86400s (24h).

| VLAN | Name          | Subnet               | DHCP pool             | Notes                              |
|------|---------------|----------------------|-----------------------|------------------------------------|
| 1    | Default       | 192.168.1.0/24       | .6 – .254             |                                    |
| 100  | Management    | 192.168.100.0/24     | .6 – .254             | Pi-hole, internal DNS              |
| 110  | Trusted-Wired | 192.168.110.0/24     | .6 – .254             |                                    |
| 120  | Trusted-WLAN  | 192.168.120.0/24     | .6 – .254             | SSID: 20-Gardner                   |
| 130  | IoT-WLAN      | 192.168.130.0/24     | .6 – .254             | SSID: 20GIoT                       |
| 140  | Guest-WLAN    | 192.168.140.0/24     | .6 – .254             | SSID: 20-Gardner-Guest, portal auth |
| 150  | Lab           | 192.168.150.0/24     | .6 – .254             | TrueNAS, Plex                      |
| 151  | VMWMgmt       | 192.168.151.0/24     | .6 – .254             | ESXi host management               |
| 152  | VMWGuestNet   | 192.168.152.0/24     | **.20 – .199**        | VM workloads, Kubernetes           |
| 153  | VMWvMotion    | 192.168.153.0/24     | .6 – .254             | ESXi vMotion                       |
| 154  | VMWStorage    | 192.168.154.0/24     | .6 – .254             | iSCSI storage                      |
| 155  | VMWVCHA       | 192.168.155.0/28     | .2 – .14              | vCenter HA heartbeat               |
| 160  | DMZ           | 192.168.160.0/24     | **.100 – .200**       | Internet-facing proxy VMs          |
| —    | WireGuard VPN | 192.168.200.0/24     | —                     | Tunnel-only, not a UDM VLAN        |

VLAN 152's pool is the one to check before assigning an address: it runs `.20`–`.199` only, so the
statically assigned infrastructure VMs at `.2`–`.17` and the MetalLB VIPs at `.244` / `.245` both
sit outside it.

**DHCP hands out `192.168.100.4` (the Pi-hole VIP) as the DNS server on every network except the
DMZ**, where `br160` hands out `192.168.160.1` — the UDM itself. DMZ hosts do not get Pi-hole by
default; the `DMZ_LAN` "Allow DMZ → Pihole (DNS)" rule exists for the ones configured to use it
explicitly.

### WiFi SSIDs

| SSID             | Network       | Bands         | Security |
|------------------|---------------|---------------|----------|
| 20-Gardner       | Trusted-WLAN  | 2.4 GHz, 5 GHz | WPA2    |
| 20GIoT           | IoT-WLAN      | 2.4 GHz        | WPA2    |
| 20-Gardner-Guest | Guest-WLAN    | 2.4 GHz, 5 GHz | WPA2    |

The collector only pulls `/data/udapi-config/udapi-net-cfg.json`, whose `unifi` key is empty — so
**SSID names, radio bands, and security modes are the one table here with no backing file in this
repo.** They come from the UniFi controller UI. The VLAN each WLAN maps to *is* verifiable, from the
DHCP server names (`net_Trusted_WLAN_br120`, `net_IoT_WLAN_br130`, `net_Guest_WLAN_br140`).

### Port Forwards (WAN → Internal)

| Name                  | Proto | External Port | Internal Destination    |
|-----------------------|-------|---------------|-------------------------|
| haproxydmz-VIP-HTTP   | TCP   | 80            | 192.168.160.4:80        |
| haproxydmz-VIP-HTTPS  | TCP   | 443           | 192.168.160.4:443       |
| Minecraft External    | TCP   | 25565         | 192.168.160.4:25565     |

### WireGuard VPN

- Server name: `vpn.vollminlab.com`, port `51821/UDP`
- Tunnel subnet: `192.168.200.0/24` (UDM server: `.200.1`)
- MSS clamping to PMTU: enabled

| Peer name  | Tunnel IP       |
|------------|-----------------|
| vollminxps | 192.168.200.2   |
| SViphone   | 192.168.200.3   |

Firewall: VPN peers get full LAN access (`VPN_LAN: Allow All`), DNS forced through Pihole (external DNS rejected via `VPN_WAN`).

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
| LAN_LAN   | Allow IoT-WLAN → Pihole (DNS); allow Admin Devices → Management; allow IoT return; allow Plex ↔ IoT-WLAN; allow IoT-WLAN → MetalLB Ingress VIP:443 (Jellyfin + all ingress-nginx services); isolated networks; allow all |
| LAN_DMZ   | Allow DMZ → Pihole DNS (return); allow haproxydmz → k8sworker05/06 Minecraft (return); allow haproxydmz → k8sworker05/06 Bluemap (return); allow haproxydmz → k8sworker05/06 Masters League (return); isolated networks; allow all |
| LAN_GUEST | Allow Pihole ↔ Hotspot (DNS); isolated networks; allow all                  |
| LAN_VPN   | Allow VPN → Pihole DNS (return); allow all                                  |

> The IoT-WLAN → MetalLB Ingress VIP:443 rule is **not present** in the collected
> `hosts/udm/udapi-net-cfg.json`, which was last pulled 2026-04-12 — before the rule was added.
> It is left listed here as the intended state; re-run `collect-host-configs.sh udm` to confirm it
> against the live UDM.

**DMZ → Zones**

| Chain    | Custom Rules                                                                |
|----------|-----------------------------------------------------------------------------|
| DMZ_LAN  | Allow DMZ → Pihole (DNS); allow haproxydmz → k8sworker05/06 (Minecraft); allow haproxydmz → k8sworker05/06 (Bluemap); allow haproxydmz → k8sworker05/06 (Masters League); allow return; block all |
| DMZ_WAN  | Reject DMZ → external DNS; block invalid; allow all                         |
| DMZ_DMZ  | Block all                                                                   |
| DMZ_VPN  | Allow return; block all                                                     |
| DMZ_LOCAL| Allow DNS, ICMP, DHCP (v4 and v6), return; block all                        |

The three haproxydmz → k8s rules are **mirror pairs** — one in `DMZ_LAN` (forward) and one in
`LAN_DMZ` (return) — and every one of them resolves the same two address objects, so a change to
either side must be made twice:

| Address object            | Entries                              |
|---------------------------|--------------------------------------|
| `HAProxy DMZ Hosts`       | 192.168.160.2, 192.168.160.3         |
| `k8s DMZ Hosts`           | 192.168.152.15, 192.168.152.16       |
| `Minecraft Nodeport`      | 32565                                |
| `Bluemap Nodeport`        | 32566                                |
| `Masters League Nodeport` | 32567                                |

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
- Reverse server: `192.168.1.0/24` → `192.168.1.1` (the UDM) for the `vollminlab.com` domain
- DNS listening mode: `SINGLE`, port 53
- Web UI: **HTTP only** — `webserver.port` is `"80o,[::]:80o"`, i.e. the stock `443os` HTTPS
  listeners have been removed. External access is through NPM
  (`pihole.vollminlab.com` → `http://192.168.100.4:80`), which terminates TLS with the wildcard
  cert. The self-signed EC P-256 cert at `/etc/pihole/tls.pem` is still documented in
  [pihole-tls.md](pihole-tls.md) and is needed only if the HTTPS listener is re-enabled.
- Config sync: nebula-sync (runs on pihole1, replicates to pihole2)
- DNS record management API: pihole-flask-api (port 5001, Bearer token from 1Password `Recordimporter` — `op read "op://Homelab/Recordimporter/credential"`) — deployed on **both** pihole1 and pihole2

**Root crontab (both hosts):**

| Schedule            | Job                                          |
|---------------------|----------------------------------------------|
| 01:05 on 15th, */3mo | Refresh Unbound root hints                  |
| 01:10 on 15th, */3mo | Restart Unbound                             |
| Every 15 minutes    | `pihole-healthcheck.sh` (FTL status, disk, NTP) |

### Local DNS records

Managed on pihole1 (`pihole.toml` `dns.hosts`), synced to pihole2 by nebula-sync. **The complete,
authoritative list is `hosts/pihole1/configs/pihole/pihole.toml`** — every new cluster Ingress adds
a record, so an inline copy of it here is stale within a week. What follows is the addressing
*model* plus the records that do not churn.

**Targets, and what each one means:**

| Target            | Meaning                        | Records pointed at it                                |
|-------------------|--------------------------------|------------------------------------------------------|
| own IP            | Machine hostname               | esxi0*, k8scp0*, k8sworker0*, haproxy0*, haproxydmz0*, groupme01, devsbx01, ansible01 |
| `192.168.152.244` | ingress-nginx VIP (MetalLB)    | every cluster app subdomain — and `vollm.in`, `go`, `shlink`, `plex` |
| `192.168.152.245` | Harbor VIP (MetalLB)           | `harbor`                                             |
| `192.168.152.2`   | nginx01 / Nginx Proxy Manager  | `pihole`, `npm`, `nginx01`, `udm`, `truenas`, `haproxy`, `haproxydmz` |
| `192.168.150.2`   | TrueNAS, addressed directly    | `iscsi`, `smb`, `nfs`                                |
| `192.168.100.x`   | `*.mgmt.vollminlab.com` — out-of-band management namespace | `pihole.mgmt` .4, `pihole1.mgmt` .2, `pihole2.mgmt` .3, `truenas.mgmt` .5, `esxi01–03.mgmt` .6–.8 |

**Stable infrastructure records:**

| Hostname                        | IP                          |
|---------------------------------|-----------------------------|
| esxi01–03.vollminlab.com        | 192.168.151.2–4             |
| vcenter.vollminlab.com          | 192.168.151.5               |
| vcenter-passive.vollminlab.com  | 192.168.155.3               |
| vcenter-witness.vollminlab.com  | 192.168.155.4               |
| nginx01.vollminlab.com          | 192.168.152.2               |
| devsbx01.vollminlab.com         | 192.168.152.3               |
| ansible01.vollminlab.com        | 192.168.152.4               |
| haproxy01/02.vollminlab.com     | 192.168.152.5/6             |
| haproxyvip.vollminlab.com       | 192.168.152.7               |
| k8sapi.vollminlab.com           | 192.168.152.7 (HAProxy VIP) |
| k8scp01–03.vollminlab.com       | 192.168.152.8–10            |
| k8sworker01–06.vollminlab.com   | 192.168.152.11–16           |
| groupme01.vollminlab.com        | 192.168.152.17              |
| haproxydmz01/02.vollminlab.com  | 192.168.160.2/3             |
| haproxydmzvip.vollminlab.com    | 192.168.160.4               |
| vpn.vollminlab.com              | 192.168.200.1               |
| glados.vollminlab.com           | 192.168.110.173             |

**Two CNAMEs** (`dns.cnameRecords`), the only non-A records configured:
`pihole1.vollminlab.com` → `pihole1.mgmt.vollminlab.com`, and the same for `pihole2`. The Pi-holes
therefore have **no** direct `pihole1/2.vollminlab.com` A record — the `.mgmt.` name is the A record.

**Traps in this table:**

- `truenas.vollminlab.com` resolves to **192.168.152.2 (NPM)**, not to the NAS. Only
  `iscsi` / `smb` / `nfs.vollminlab.com` address 192.168.150.2 directly.
- `plex.vollminlab.com` resolves to **192.168.152.244 (ingress-nginx)**, not to the NAS.
- `vollm.in` **is** a Pi-hole record (`192.168.152.244`) — a split-horizon override so LAN clients
  reach the Shlink Ingress directly instead of leaving the network. It is also an externally
  registered domain resolving via public DNS, which is what off-LAN clients get.
- There is **no `vl.vollminlab.com` record.** Shlink short links are `vollm.in/<slug>` and
  `go.vollminlab.com/<slug>`.
- `bluemap` and `mastersleague` are **not** Pi-hole records. They are public-DNS only and are
  reached through the DMZ HAProxy — see [Load Balancing](#dmz-haproxy-haproxydmz01--haproxydmz02).

---

## Virtualization (vSphere)

### ESXi Hosts

| Host   | Management IP   | vMotion IP      | iSCSI-1 IP      | iSCSI-2 IP      | Version | Build    |
|--------|-----------------|-----------------|-----------------|-----------------|---------|----------|
| esxi01 | 192.168.151.2   | 192.168.153.2   | 192.168.154.2   | 192.168.154.5   | 8.0.3   | 24859861 |
| esxi02 | 192.168.151.3   | 192.168.153.3   | 192.168.154.3   | 192.168.154.6   | 8.0.3   | 24859861 |
| esxi03 | 192.168.151.4   | 192.168.153.4   | 192.168.154.4   | 192.168.154.7   | 8.0.3   | 24859861 |

Hardware: Minisforum MS-01 (vSphere reports manufacturer `Micro Computer (HK) Tech Limited`, model
`Venus Series`). NTP: `pool.ntp.org`, service running, policy `on`. Host DNS: `192.168.100.4`,
`192.168.100.3`; search domain `vollminlab.com`.
vSphere reports 6 CPUs (P-cores only) / 12 logical processors per host, 95.74 GB usable RAM (96 GB physical). E-cores not presented to the hypervisor.

### vCenter (VCHA)

Three-node vCenter HA cluster — active, passive, witness — one per ESXi host. Management NIC on VLAN 151, VCHA heartbeat NIC on VLAN 155.

`vcenter.vollminlab.com` = `192.168.151.5` — floating management IP held by whichever node is currently active. Gateway: `192.168.151.1`. DNS: `192.168.100.4, 192.168.100.3`.

Indexed by **VM name**, not by role — the role floats on failover, the VM name does not:

| VM                | VCHA IP (fixed) | VCHA NIC MAC        |
|-------------------|-----------------|---------------------|
| `vcenter`         | 192.168.155.2   | `00:50:56:98:f0:f7` |
| `vcenter-Passive` | 192.168.155.3   | `00:50:56:98:57:03` |
| `vcenter-Witness` | 192.168.155.4   | `00:50:56:98:dd:09` |

Each `.155.x` address is a UDM static DHCP lease bound to that MAC, so they are stable across
rebuilds. Whichever of `vcenter` / `vcenter-Passive` is currently **active** additionally holds the
floating `192.168.151.5`.

> **Never infer the VCHA role from the VM name.** The names are deployment-time labels and do
> not track the roles — a failover swaps which VM is active and leaves the names behind. As of
> 2026-08-17 the VM named `vcenter` was PASSIVE and `vcenter-Passive` was ACTIVE, but that is
> expected to change and this document deliberately does not pin it.
>
> Ask the API instead:
>
> ```bash
> TOK=$(curl -sk -u "$USER:$PASS" -X POST https://vcenter.vollminlab.com/api/session | tr -d '"')
> curl -sk -H "vmware-api-session-id: $TOK" -X POST \
>   'https://vcenter.vollminlab.com/rest/vcenter/vcha/cluster?action=get' \
>   -H 'Content-Type: application/json' -d '{"vcha_cluster":{}}' \
>   | jq '.value | {n1:{vm:.node1.runtime.placement.vm_name, role:.node1.runtime.role},
>                   n2:{vm:.node2.runtime.placement.vm_name, role:.node2.runtime.role},
>                   health:.health_state, mode:.mode}'
> ```
>
> Quicker sanity check: the active node is whichever additionally holds `192.168.151.5`.

> **Two vCLS VMs on three hosts is correct, not a fault.** vSphere 8.0 Update 3 replaced the old
> vCLS with [Embedded vCLS](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere/8-0/vsphere-resource-management/vsphere-cluster-services-vcls/embedded-vcls.html),
> which reduced the count from up to three to **two** for any cluster with two or more hosts, and
> moved the agents into host memory. They have **no storage footprint** — their `vmPathName` is
> `[] /var/run/crx/infra/…` with an empty datastore, which is expected and not a placement failure.
> They are `vCLS-<uuid>` VMs and must not be managed by hand.

### Cluster

- Name: `vollminlab-ESXi-Cluster`
- HA: enabled, failover level 1, admission control enabled
- DRS: enabled, **fully automated**, vMotion rate 3
  <br>Verify: `govc object.collect -json <cluster> configuration` → `drsConfig.defaultVmBehavior`.
  The `DrsAutomationLevel: 1` in `hosts/vsphere/cluster.json` is not the DRS behaviour enum and
  should not be read as "partially automated" — the live cluster reports `fullyAutomated`.
- EVC: not configured

**DRS Separation Rules** (must-run-on-separate-hosts):

| Rule                  | VMs                                    |
|-----------------------|----------------------------------------|
| vCenter HA nodes      | vcenter, vcenter-Passive, vcenter-Witness |
| HAProxy internal pair | haproxy01, haproxy02                   |
| K8s control plane     | k8scp01, k8scp02, k8scp03             |

### Distributed vSwitch

- Name: `DSwitch0`, version 8.0.3, MTU 9000 (jumbo frames), 2 uplinks (`Uplink 1` / `Uplink 2`),
  all 3 hosts connected

### Port Groups

| Port Group           | VLAN            | Purpose              |
|----------------------|-----------------|----------------------|
| 151-DPG-Management   | 151             | ESXi / vCenter mgmt  |
| 152-DPG-GuestNet     | 152             | VM workloads         |
| 153-DPG-vMotion      | 153             | vMotion              |
| 154-DPG-iSCSI-1      | 154             | iSCSI path 1         |
| 154-DPG-iSCSI-2      | 154             | iSCSI path 2         |
| 155-DPG-VCHA         | 155             | vCenter HA           |
| 160-DPG-DMZ          | 160             | DMZ VMs              |
| DSwitch0-DVUplinks   | trunk 0–4094    | Uplink port group    |

### Datastores

| Name         | Type | Capacity  | Backing                                       |
|--------------|------|-----------|-----------------------------------------------|
| vmstore1     | VMFS | 1433.5 GB | Shared iSCSI — zvol `pool_1/vmstorage/vmstore1` |
| vmstore2     | VMFS | 1433.5 GB | Shared iSCSI — zvol `pool_1/vmstorage/vmstore2` |
| esxi01-local | VMFS | 825.75 GB | Local to esxi01                               |
| esxi02-local | VMFS | 825.75 GB | Local to esxi02                               |
| esxi03-local | VMFS | 825.75 GB | Local to esxi03                               |

All five are VMFS 6.82. Free space is not recorded here — it changes with every VM operation; read
`FreeSpaceGB` from `hosts/vsphere/datastores.json` after a fresh `Export-VSphereConfigs.ps1` run.
There are no datastore clusters (`hosts/vsphere/datastore-clusters.json` is empty).

iSCSI target: `iscsi.vollminlab.com` / `192.168.150.2:3260`, software initiator (vmhba64), dual-path on all ESXi hosts.

### VM Inventory

Specs (vCPU / RAM / disk / network / IP) are generated from the collected vSphere export
(`hosts/vsphere/vms.json`) — **do not hand-edit the tables below.** Refresh the export with
`scripts/Export-VSphereConfigs.ps1`, then regenerate with `scripts/generate-vm-inventory.py`.

Placement (ESXi host **and** datastore) is intentionally not tracked here: DRS moves hosts
dynamically and datastores move on manual storage migration, so pinning either in a doc only
guarantees drift. vCenter appliance VMs (VCHA) are managed out-of-band and omitted.

<!-- BEGIN GENERATED: vm-inventory (scripts/generate-vm-inventory.py) -->
<!-- Generated from hosts/vsphere/vms.json — do not hand-edit. Regenerate with scripts/generate-vm-inventory.py. -->

#### Kubernetes

| VM          | vCPU | RAM   | Disk   | Network  | IP             |
|-------------|------|-------|--------|----------|----------------|
| k8scp01     | 4    | 8 GB  | 50 GB  | GuestNet | 192.168.152.8  |
| k8scp02     | 4    | 8 GB  | 50 GB  | GuestNet | 192.168.152.9  |
| k8scp03     | 4    | 8 GB  | 50 GB  | GuestNet | 192.168.152.10 |
| k8sworker01 | 4    | 8 GB  | 100 GB | GuestNet | 192.168.152.11 |
| k8sworker02 | 4    | 8 GB  | 100 GB | GuestNet | 192.168.152.12 |
| k8sworker03 | 4    | 8 GB  | 100 GB | GuestNet | 192.168.152.13 |
| k8sworker04 | 4    | 8 GB  | 100 GB | GuestNet | 192.168.152.14 |
| k8sworker05 | 8    | 32 GB | 100 GB | GuestNet | 192.168.152.15 |
| k8sworker06 | 8    | 32 GB | 100 GB | GuestNet | 192.168.152.16 |

#### Infrastructure VMs

| VM           | vCPU | RAM   | Disk  | Network  | IP             |
|--------------|------|-------|-------|----------|----------------|
| ansible01    | 2    | 2 GB  | 50 GB | GuestNet | 192.168.152.4  |
| devsbx01     | 4    | 16 GB | 60 GB | GuestNet | 192.168.152.3  |
| groupme01    | 1    | 2 GB  | 50 GB | GuestNet | 192.168.152.17 |
| haproxy01    | 2    | 2 GB  | 20 GB | GuestNet | 192.168.152.5  |
| haproxy02    | 2    | 2 GB  | 20 GB | GuestNet | 192.168.152.6  |
| haproxydmz01 | 2    | 2 GB  | 50 GB | DMZ      | 192.168.160.2  |
| haproxydmz02 | 2    | 2 GB  | 50 GB | DMZ      | 192.168.160.3  |
| nginx01      | 1    | 2 GB  | 50 GB | GuestNet | 192.168.152.2  |

<!-- END GENERATED: vm-inventory -->

---

## Kubernetes

- Topology: 3 control plane (k8scp01–03) + 6 workers (k8sworker01–06), kubeadm-installed
- Control plane endpoint: `192.168.152.7:6443` (HAProxy VIP)
- Pod subnet: `172.18.0.0/16`
- Service subnet: `10.96.0.0/12`
- etcd: stacked, 3 members (k8scp01–03), local at `/var/lib/etcd` — see [etcd.md](etcd.md)
- API server encryption: enabled (`--encryption-provider-config /etc/kubernetes/enc/enc.yaml`)
- CNI: Calico, installed via the Tigera operator (**not** Flux-managed)
- GitOps: Flux (repo: `k8s-vollminlab-cluster`)
- Storage: Longhorn (Flux-managed HelmRelease)

Node pod CIDRs are assigned sequentially from 172.18.0.0/16 (e.g., k8scp01 = 172.18.0.0/24).

**No version numbers are recorded here, deliberately.** Kubernetes, Calico, and Longhorn all move
on their own schedules, and a number written into this file is wrong the moment the next upgrade
lands — this section claimed 1.32.3 and Longhorn v1.8.1 for months after both had moved on. Read
them from a source that maintains itself instead:

| Component     | Where the live version comes from                                          |
|---------------|----------------------------------------------------------------------------|
| Kubernetes    | `kubectl get nodes` — or `hosts/k8s/kubeadm-config.yaml` after a fresh collection |
| Calico        | `k8s-vollminlab-cluster` → `bootstrap/calico/README.md` (pinned there, not Flux-managed) |
| Longhorn      | `k8s-vollminlab-cluster` → the Longhorn HelmRelease `spec.chart.spec.version` |
| Flux          | `flux version`                                                              |

> **`hosts/k8s/` is the stalest snapshot in this repo.** It has not been re-collected since the
> initial commit (2026-04-10), so `kubeadm-config.yaml` and `nodes.yaml` still show the cluster as
> it was then. Run `scripts/collect-k8s-configs.sh` before trusting anything in that directory.

---

## Load Balancing

### Internal HAProxy (haproxy01 / haproxy02)

| Item          | Value                                   |
|---------------|-----------------------------------------|
| VIP           | 192.168.152.7/24 (VRRP ID 51)          |
| haproxy01     | 192.168.152.5 — MASTER (priority 110)  |
| haproxy02     | 192.168.152.6 — BACKUP (priority 100)  |
| Health check  | `pidof haproxy` — interval 2, weight -5, fall 2, rise 1 |
| Notify master | `/usr/local/bin/haproxy-start.sh`       |
| Notify backup | `/usr/local/bin/haproxy-stop.sh`        |
| Notify fault  | `/usr/local/bin/haproxy-stop.sh`        |

**Backends:**

| Frontend             | Backend                          | Mode |
|----------------------|----------------------------------|------|
| `192.168.152.7:6443` | k8scp01/02/03 at .8/.9/.10:6443  | TCP  |
| `*:8404`             | Stats page (authenticated)       | HTTP |

The `kube-apiserver` frontend binds the **VIP only** (`bind 192.168.152.7:6443`), not `*:6443`.
This pairs with the keepalived notify hooks — `haproxy-start.sh` and `haproxy-stop.sh` are plain
`systemctl start/stop haproxy` — so HAProxy runs on exactly the node currently holding the VIP.
Backend defaults: `inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256`.

### DMZ HAProxy (haproxydmz01 / haproxydmz02)

| Item          | Value                                    |
|---------------|------------------------------------------|
| VIP           | 192.168.160.4/24 (VRRP ID 60)           |
| haproxydmz01  | 192.168.160.2 — MASTER (priority 200)   |
| haproxydmz02  | 192.168.160.3 — BACKUP (priority 180)   |
| Health check  | `/usr/bin/pgrep -x haproxy` — interval 2, fall 2, rise 2 (no weight, no notify hooks) |

**Frontends and backends:**

| Frontend                            | Backend       | Targets                                    | Mode |
|-------------------------------------|---------------|--------------------------------------------|------|
| `ft_http` — `*:80`                  | —             | 301 redirect to HTTPS                      | HTTP |
| `ft_https` — `bluemap.vollminlab.com` | `bk_bluemap`  | k8sworker05 **and** 06 — `.15/.16:32566`   | HTTP |
| `ft_https` — `mastersleague.vollminlab.com` | `bk_masters` | k8sworker05 **and** 06 — `.15/.16:32567` | HTTP |
| `ft_https` — any other host         | `bk_404`      | returns `404 Not found`                    | HTTP |
| `ft_minecraft` — `*:25565`          | `bk_minecraft`| k8sworker05 **and** 06 — `.15/.16:32565`   | TCP  |
| `listen stats` — `*:8404`           | —             | stats page (authenticated)                 | HTTP |

**Every backend is a two-server round-robin across k8sworker05 (192.168.152.15) and k8sworker06
(192.168.152.16)** — not a single node. Health checks are `inter 3000 fall 3 rise 2` on all three,
with `option httpchk GET /` (bluemap), `GET /api/health` (masters), and `option tcp-check`
(minecraft). `haproxydmz01` and `haproxydmz02` carry byte-identical configs apart from whitespace.

**Rate limiting** applies to the Minecraft frontend only: a stick table keyed on source IP stores
`conn_rate(10s)`, and a source exceeding **100 connections per 10s window** is rejected at connect
time. There is no `maxconn` anywhere in the DMZ config — the internal HAProxy's `maxconn 250` is a
separate thing and does not apply here.

TLS: `ft_https` binds `*:443 ssl crt /etc/haproxy/certs/`, TLS 1.2 minimum, Mozilla intermediate
cipher suite, `no-tls-tickets`. It sets `X-Forwarded-Proto: https` and `option forwardfor`.

**Certificate sync:** `sync-haproxy-cert.sh` on haproxydmz01 — merges Let's Encrypt fullchain + key, deploys to both DMZ proxies via SSH, reloads HAProxy.

---

## Reverse Proxy (Nginx Proxy Manager)

- Host: nginx01 (192.168.152.2)
- Docker Compose on Debian, MariaDB backend
- Admin: `https://npm.vollminlab.com` (port 81, self-proxied)
- Wildcard cert: `*.vollminlab.com` via Let's Encrypt, auto-renewed by NPM. The expiry date is not
  recorded here — it moves every ~60 days; read `expires_on` from
  `hosts/nginx01/npm/certificates.json` after a fresh `collect-npm-configs.sh` run.
- All six proxy hosts use that one certificate and have `ssl_forced` enabled.
- No redirection hosts and no streams are configured.

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

| Pool   | Layout | Raw    | Disks           | Holds                                          |
|--------|--------|--------|-----------------|------------------------------------------------|
| pool_0 | RaidZ2 | 40 TB  | 5× (sda2–sde2)  | `plex-media`, `smb-generic`, `vcenter_backups` |
| pool_1 | Mirror | 4 TB   | 2× (sdf1, sdg1) | `vmstorage` — the `vmstore1` / `vmstore2` zvols |

Used/free figures are deliberately omitted; they move daily. Read them from
`hosts/truenas/pools.json` after a fresh `collect-truenas-configs.sh` run.

**`pool_1` is the iSCSI datastore pool.** `pool_1/vmstorage/vmstore1` and `.../vmstore2` are ZFS
**volumes** (zvols), exported over iSCSI, and formatted VMFS by ESXi as the `vmstore1` / `vmstore2`
shared datastores in the [Datastores](#datastores) table. Shared VM storage for the whole homelab
therefore rests on this one 2-disk mirror; the three `esxi0*-local` datastores were essentially
empty at the last export.

### SMB Shares

Everything media-related is nested under `pool_0/plex-media`, **not** at the pool root:

| Share                | Path                                              |
|----------------------|---------------------------------------------------|
| movies               | /mnt/pool_0/plex-media/movies                     |
| tv                   | /mnt/pool_0/plex-media/tv                         |
| completed-downloads  | /mnt/pool_0/plex-media/SABnzbd/completed-downloads |
| incomplete-downloads | /mnt/pool_0/plex-media/SABnzbd/incomplete-downloads |
| smb-generic          | /mnt/pool_0/smb-generic                           |

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

- VM on GuestNet (192.168.152.17)
- Systemd service: `groupme-daemon.service` — `/opt/groupme/venv/bin/python groupme_ingest.py
  --daemon --interval 30 --head-pages 6 --reconcile-head 6 --verbose`
- Hardened: `NoNewPrivileges=true`, `ProtectSystem=full`, `ProtectHome=true`, `PrivateTmp=true`
- Auto-restarts on failure (`Restart=always`, `RestartSec=5`)
- Config from `/etc/groupme.env` — see `hosts/groupme01/configs/groupme.env.example`

### Ansible control node (ansible01)

- VM on GuestNet (192.168.152.4). Collected state: `ansible --version` and the Galaxy collection
  inventory only — playbooks and inventory live in the `ansible-playbooks` repo.
- Bootstrap and DR procedure, including the on-disk outbound SSH key, is in
  `hosts/ansible01/README.md`.

### Dev sandbox (devsbx01)

- VM on GuestNet (192.168.152.3). Collected state: shell configs (`.bashrc`, `.tmux.conf`,
  `.gitconfig`, `.blerc`, `.fzf.bash`).
- Bootstrap steps in `hosts/devsbx01/README.md`. Also runs Syncthing for the Obsidian vault —
  see [syncthing.md](syncthing.md).

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
- **Kubernetes:** Flux repo re-bootstraps all workloads. Secrets are **no longer** SealedSecrets — that controller was removed 2026-05-31 and `k8s-vollminlab-cluster/bootstrap/sealed-secrets/` is historical reference only. The DR-critical root secret is now the `onepassword-connect` Secret (`1password-credentials.json` + `token`) in the `1password` namespace, which is not Flux-managed and must be applied **before** Flux bootstrap so External Secrets Operator can materialize every other Secret from the 1Password Homelab vault. etcd backup/restore and member replacement procedures in [etcd.md](etcd.md). API server encryption key (`enc.yaml`) must be restored from 1Password before API server starts on a rebuilt control plane node.
- **vSphere:** Full config snapshot in `hosts/vsphere/`. vCSA file-based backup target: `/mnt/pool_0/vcenter_backups` on TrueNAS (NFS, accessible from 192.168.151.0/24).
