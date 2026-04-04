# Maintenance Day — Infrastructure Flag Day

A planned maintenance window for upgrading all infrastructure components — out-of-cluster appliances, hypervisors, Linux VMs, and the Kubernetes cluster itself. These systems are interdependent and benefit from a single coordinated window rather than ad-hoc upgrades.

**Principle:** Upgrade in dependency order. TrueNAS backs the hypervisors, ESXi hosts the k8s VMs, PiHole provides DNS for everything. Take the whole stack down cleanly, upgrade from the bottom up, bring it back up in order.

---

## Scope

| Component | Notes |
|-----------|-------|
| TrueNAS SCALE | iSCSI-backed datastores — requires full k8s and VM shutdown first |
| Pi-hole units | HA pair — can do one at a time with VRRP failover, no DNS downtime |
| ESXi hosts | Persistent licenses, no depot site ID — see decision below |
| HAProxy nodes (internal) | VRRP HA pair — rolling upgrade, brief per-node downtime |
| HAProxy nodes (DMZ) | VRRP HA pair — rolling upgrade, brief per-node external downtime |
| Nginx Proxy Manager (nginx01) | Brief external HTTPS downtime during reboot |
| Other Linux VMs | groupme01, any other non-k8s VMs |
| Kubernetes node OS | Rolling per-node apt upgrade, hold k8s packages |
| Kubernetes version | kubeadm upgrade — do after node OS upgrades |
| UDM / UniFi gear | Self-updating, no manual action needed |

---

## Pre-maintenance prerequisites (do before the window)

These steps must be completed **before** the maintenance window starts, as they affect what can stay running during the TrueNAS upgrade.

### Migrate vCenter VMs to local datastore

The three vCenter appliance nodes (`vcenter`, `vcenter-Passive`, `vcenter-Witness`) normally run on shared iSCSI datastores. TrueNAS must be rebooted for its upgrade, so vCenter must be on a local datastore first — otherwise vCenter goes down with TrueNAS and you lose the management plane mid-window.

1. In vCenter, storage-vMotion all three vCenter VMs to a single `esxi0x-local` datastore (pick the host with most free space)
2. Verify all three VMs show the local datastore in vCenter → Edit Settings → VM Storage Policy
3. VCHA can remain intact — the VMs are still reachable, just on local storage

> **After the maintenance window:** optionally migrate the vCenter VMs back to vmstore1/vmstore2 to restore VCHA's datastore redundancy. Not required immediately.

---

## Pre-maintenance checklist

Before starting any work:

- [ ] vCenter VMs migrated to local datastore (see prerequisite above)
- [ ] Verify all k8s nodes are `Ready` and Flux kustomizations are healthy
- [ ] Take etcd snapshot and copy to local machine (see [etcd.md](etcd.md))
- [ ] Take full ZFS snapshots of all TrueNAS pools
- [ ] Confirm 1Password SSH agent is active and SSH to all hosts works
- [ ] Notify affected users of planned downtime window
- [ ] Have homelab-infrastructure repo open for reference

---

## Upgrade order and procedures

### 1. TrueNAS SCALE

TrueNAS hosts the iSCSI datastores (vmstore1, vmstore2) that back all ESXi VMs. vCenter remains up throughout (it's on local storage per the prerequisite). All other VMs on shared datastores must be shut down cleanly before rebooting TrueNAS.

1. Take etcd snapshot while cluster is still running:
   ```powershell
   kubectl -n kube-system exec etcd-k8scp01 -- etcdctl `
     --endpoints=https://127.0.0.1:2379 `
     --cacert=/etc/kubernetes/pki/etcd/ca.crt `
     --cert=/etc/kubernetes/pki/etcd/server.crt `
     --key=/etc/kubernetes/pki/etcd/server.key `
     snapshot save /var/lib/etcd/snapshot.db
   ```
   ```bash
   export PATH="/c/Windows/System32/OpenSSH:$PATH"
   scp vollmin@k8scp01.vollminlab.com:/var/lib/etcd/snapshot.db $HOME/Desktop/etcd-snapshot-$(date +%Y%m%d).db
   ```
2. Drain and shut down all k8s worker nodes:
   ```bash
   kubectl drain k8sworker01 --ignore-daemonsets --delete-emptydir-data
   # repeat for k8sworker02–06
   ```
3. Shut down k8s control plane nodes (k8scp01–03) via vCenter
4. Shut down all remaining VMs on TrueNAS-backed datastores via vCenter:
   - haproxy01, haproxy02
   - haproxydmz01, haproxydmz02
   - nginx01
   - groupme01
5. Take ZFS snapshots from TrueNAS shell (System → Shell):
   ```bash
   sudo zfs snapshot -r pool_0@pre-update-YYYYMMDD
   sudo zfs snapshot -r pool_1@pre-update-YYYYMMDD
   zfs list -t snapshot | grep pre-update
   ```
6. Apply TrueNAS update: System → Update → Apply (~5 min reboot)
7. Verify datastores in vCenter: Storage → Datastores → confirm vmstore1 and vmstore2 show **Connected**
8. Power on VMs in order via vCenter:
   - haproxy01, haproxy02 (internal LB — brings up k8s API VIP)
   - haproxydmz01, haproxydmz02 (DMZ LB — restores external traffic)
   - nginx01 (NPM — restores internal HTTPS proxying)
   - k8scp01, k8scp02, k8scp03 (control plane — wait for all three to show Ready)
   - k8sworker01–06 (workers)
   - groupme01 (non-critical, last)
9. Uncordon k8s workers:
   ```bash
   kubectl uncordon k8sworker01
   # repeat for each worker
   kubectl get nodes
   ```

---

### 2. ESXi Hosts

Three Minisforum MS-01 hosts. Persistent licenses, no active depot site ID for VMware Update Manager.

**Decision options:**

| Option | Notes |
|--------|-------|
| **A — Manual offline bundle** | Download from Broadcom portal, `esxcli software profile update`, one host at a time with DRS maintenance mode |
| **B — Migrate to Proxmox VE** | Significant effort, disrupts all VMs; not urgent |
| **C — Defer** | Not a critical security gap for a homelab; revisit when Broadcom licensing clarifies |

**Current decision: Defer (Option C).** Document current ESXi versions in vCenter and revisit.

**If proceeding with Option A:**
1. Put host into maintenance mode in vCenter (DRS migrates VMs)
2. Download offline bundle from Broadcom portal
3. Upload to datastore or serve via HTTP
4. `esxcli software profile update -p <profile> -d <bundle-url>`
5. Reboot, verify, exit maintenance mode
6. Repeat for remaining hosts one at a time

---

### 3. Pi-hole Units

Two Pi-hole instances in HA via keepalived VRRP. VIP: `192.168.100.4`. Upgrade one at a time — no DNS downtime.

> **Note:** pihole1 may have an SD card health issue. Run the diagnostics in [pihole-hardware.md](pihole-hardware.md) before or after this upgrade to assess whether hardware replacement is needed.

1. Trigger failover away from pihole1 if it's primary:
   ```bash
   export PATH="/c/Windows/System32/OpenSSH:$PATH"
   ssh pihole1 "sudo systemctl stop keepalived"
   ```
2. Verify VIP has moved to pihole2:
   ```bash
   ping 192.168.100.4  # should still respond
   ssh pihole2 "ip addr show | grep 192.168.100.4"  # should show VIP on pihole2
   ```
3. Upgrade pihole1:
   ```bash
   ssh pihole1
   sudo apt update && sudo apt upgrade -y
   pihole -up
   sudo reboot
   ```
4. After pihole1 reboots, verify services:
   ```bash
   ssh pihole1
   sudo systemctl status keepalived        # must be active (running)
   sudo systemctl status pihole-flask-api  # must be active (running)
   docker ps | grep nebula-sync            # must be Up
   ```
   If keepalived is not running: `sudo systemctl start keepalived`
5. Verify TLS cert is still valid after upgrade — see [pihole-tls.md](pihole-tls.md)
6. Repeat steps 1–5 for pihole2 (stop keepalived on pihole2 to fail back to pihole1 first if desired)

---

### 4. HAProxy Nodes

#### Internal (haproxy01 / haproxy02)

Two HAProxy VMs in VRRP HA. VIP: `192.168.152.7` (k8s API, VRRP ID 51). Upgrade one at a time.

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"
ssh haproxy01
sudo apt update && sudo apt upgrade -y
sudo reboot
```

Verify VIP is held by haproxy02 during haproxy01 reboot (`ip addr show | grep 192.168.152.7` on haproxy02), then repeat for haproxy02.

#### DMZ (haproxydmz01 / haproxydmz02)

Two HAProxy VMs in VRRP HA. VIP: `192.168.160.4` (external traffic, VRRP ID 60). Upgrade one at a time — brief external HTTPS/Minecraft downtime per node if the VIP doesn't fail over cleanly.

```bash
ssh haproxydmz01
sudo apt update && sudo apt upgrade -y
sudo reboot
```

Verify VIP is held by haproxydmz02 during haproxydmz01 reboot (`ip addr show | grep 192.168.160.4` on haproxydmz02), then repeat for haproxydmz02.

The Let's Encrypt cert (`sync-haproxy-cert.sh`) survives reboot — no cert action needed unless there's an expiry issue.

---

### 5. Other Linux VMs

nginx01, groupme01, and any other non-k8s VMs:

```bash
sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y
sudo reboot
```

**nginx01 (Nginx Proxy Manager):** Brief external HTTPS downtime during reboot. Coordinate timing.

---

### 6. Kubernetes Node OS Upgrade

Rolling per-node upgrade. Workers first, then control plane. Hold k8s packages at current version — do not mix with Kubernetes version upgrade.

**Longhorn note:** Draining a node evicts Longhorn replica pods. Longhorn will rebuild replicas on remaining nodes — wait for all volumes to return to `Healthy` before draining the next node. Check: Longhorn UI → Volumes, or:
```bash
kubectl -n longhorn-system get volumes
```

```bash
# Drain
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# SSH to node
ssh <node>
sudo apt-mark hold kubeadm kubelet kubectl
sudo apt update && sudo apt upgrade -y
sudo reboot

# After reboot — wait for Ready, then check Longhorn before next node
kubectl get nodes
kubectl -n longhorn-system get volumes  # all must be Healthy before continuing

kubectl uncordon <node>
```

Control plane nodes: drain each, upgrade OS, reboot, verify `kubectl get nodes` and etcd health before moving to next:
```bash
kubectl -n kube-system exec etcd-k8scp01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster
```

---

### 7. Kubernetes Version Upgrade

After all node OS upgrades are complete. Requires `kubeadm upgrade plan` — do not mix with OS maintenance above.

Tracked in [k8s-vollminlab-cluster roadmap](../../k8s-vollminlab-cluster/docs/roadmap.md) as Phase 1.4.

**High-level steps:**
1. `kubeadm upgrade plan` — review available versions
2. Upgrade control plane one node at a time (kubeadm → kubelet → kubectl)
3. Upgrade workers one at a time with drain/uncordon cycle
4. Full procedure: see Kubernetes official upgrade docs for target version

---

## Post-maintenance checklist

- [ ] All k8s nodes `Ready`, Flux kustomizations healthy
- [ ] TrueNAS datastores Connected in vCenter
- [ ] Pi-hole VRRP healthy, DNS resolving: `dig @192.168.100.4 vollminlab.com`
- [ ] nebula-sync running on pihole1: `ssh pihole1 "docker ps | grep nebula-sync"`
- [ ] Internal HAProxy VIP responding: `curl -k https://192.168.152.7:6443`
- [ ] DMZ HAProxy VIP responding: `curl -sk https://192.168.160.4 -o /dev/null -w "%{http_code}"`
- [ ] nginx01 proxying internal traffic correctly
- [ ] Homepage dashboard showing all services healthy
- [ ] Clean up ZFS snapshots after 7 days if no issues

---

## Deferred items

| Item | Reason |
|------|--------|
| ESXi host upgrades | No depot site ID; persistent license; evaluating Proxmox migration |
| Proxmox migration | Significant effort; not urgent; revisit when ESXi decision is made |
| Backblaze B2 for TrueNAS | Planned — add Cloud Sync tasks for irreplaceable data (photos, configs, PVC backups) |
| pihole1 storage hardware | SD card may be degraded — see [pihole-hardware.md](pihole-hardware.md) for diagnostics and replacement options |
