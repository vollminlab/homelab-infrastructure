# etcd Operations

Reference and runbook for the etcd cluster backing `vollminlab-cluster`. etcd is managed by kubeadm as a stacked deployment — one etcd member per control plane node, running as a static pod.

---

## Architecture

| Property | Value |
|---|---|
| Topology | Stacked (etcd co-located with control plane) |
| Members | 3 (quorum requires 2) |
| Data directory | `/var/lib/etcd` |
| Static pod manifest | `/etc/kubernetes/manifests/etcd.yaml` |
| PKI | `/etc/kubernetes/pki/etcd/` |
| Encryption at rest | Enabled — `/etc/kubernetes/enc/enc.yaml` |
| Config source | `hosts/k8s/kubeadm-config.yaml` |

### Members

| Node | IP | ESXi Host |
|---|---|---|
| k8scp01 | 192.168.152.8 | esxi01 (DRS separated) |
| k8scp02 | 192.168.152.9 | esxi02 (DRS separated) |
| k8scp03 | 192.168.152.10 | esxi03 (DRS separated) |

Control plane VMs are DRS-separated — one per ESXi host. An ESXi host failure loses one etcd member but quorum is maintained.

---

## Health Checking

Run from any control plane node. etcdctl is available inside the etcd static pod container.

```bash
# Quick health check — all members
kubectl -n kube-system exec etcd-k8scp01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health \
  --cluster

# Member list
kubectl -n kube-system exec etcd-k8scp01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

# Status (includes leader, db size, raft index)
kubectl -n kube-system exec etcd-k8scp01 -- etcdctl \
  --endpoints=https://192.168.152.8:2379,https://192.168.152.9:2379,https://192.168.152.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
```

---

## Backup

Snapshots should be taken from the **leader** node to ensure consistency, but any healthy member works. The snapshot captures all cluster state.

```bash
# SSH to a control plane node (e.g., k8scp01)
ssh k8scp01.vollminlab.com

# Take snapshot — run inside the etcd pod
ETCDCTL_API=3 kubectl -n kube-system exec etcd-k8scp01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot.db

# Copy snapshot off the node
scp k8scp01.vollminlab.com:/var/lib/etcd/snapshot.db ./etcd-snapshot-$(date +%Y%m%d).db

# Verify the snapshot
ETCDCTL_API=3 etcdctl snapshot status ./etcd-snapshot-$(date +%Y%m%d).db -w table
```

Store backups somewhere durable (TrueNAS, 1Password attachment for critical snapshots before upgrades).

---

## Restore (Disaster Recovery)

> **Warning:** Full etcd restore replaces all cluster state. Only do this when the cluster is unrecoverable — not for individual node failures (see [Replacing a Member](#replacing-a-failed-member) instead).

This procedure restores etcd to a known-good snapshot and rebuilds the cluster. Requires SSH access to all control plane nodes.

### 1. Stop all control plane components

On **each** control plane node, move static pod manifests out of the watched directory so the kubelet stops them:

```bash
# Repeat on k8scp01, k8scp02, k8scp03
ssh k8scp0X.vollminlab.com
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
```

### 2. Restore the snapshot on each node

Run on **each** control plane node, adjusting `--name` and `--initial-advertise-peer-urls` per node:

```bash
# On k8scp01
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /path/to/snapshot.db \
  --name k8scp01 \
  --initial-cluster k8scp01=https://192.168.152.8:2380,k8scp02=https://192.168.152.9:2380,k8scp03=https://192.168.152.10:2380 \
  --initial-cluster-token etcd-cluster-1 \
  --initial-advertise-peer-urls https://192.168.152.8:2380 \
  --data-dir /var/lib/etcd

# On k8scp02
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /path/to/snapshot.db \
  --name k8scp02 \
  --initial-cluster k8scp01=https://192.168.152.8:2380,k8scp02=https://192.168.152.9:2380,k8scp03=https://192.168.152.10:2380 \
  --initial-cluster-token etcd-cluster-1 \
  --initial-advertise-peer-urls https://192.168.152.9:2380 \
  --data-dir /var/lib/etcd

# On k8scp03
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /path/to/snapshot.db \
  --name k8scp03 \
  --initial-cluster k8scp01=https://192.168.152.8:2380,k8scp02=https://192.168.152.9:2380,k8scp03=https://192.168.152.10:2380 \
  --initial-cluster-token etcd-cluster-1 \
  --initial-advertise-peer-urls https://192.168.152.10:2380 \
  --data-dir /var/lib/etcd
```

### 3. Restore static pod manifests

On **each** control plane node, move the manifests back:

```bash
sudo mv /tmp/etcd.yaml /etc/kubernetes/manifests/
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
sudo mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
```

The kubelet will restart the static pods within ~30 seconds.

### 4. Verify

```bash
kubectl get nodes
kubectl -n kube-system get pods
# Check etcd member health (see Health Checking above)
```

---

## Replacing a Failed Member

Use this when a single control plane node is lost (VM failure, disk corruption) but the other two members are healthy — quorum is maintained throughout.

### 1. Remove the failed member

```bash
# Get member ID of the failed node
kubectl -n kube-system exec etcd-k8scp01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

# Remove failed member (replace <MEMBER_ID> with value from above)
kubectl -n kube-system exec etcd-k8scp01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member remove <MEMBER_ID>
```

### 2. Remove the failed control plane node from Kubernetes

```bash
kubectl delete node k8scp0X
```

### 3. Rebuild the VM

Provision a new VM (same specs — 4 vCPU, 8 GB RAM, 50 GB disk — see infrastructure.md). Join it to the cluster with kubeadm:

```bash
# Generate a new join command on a healthy control plane node
kubeadm token create --print-join-command

# On the new node — append --control-plane and the certificate key
kubeadm join 192.168.152.7:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key>
```

Generate a fresh certificate key if needed:
```bash
kubeadm init phase upload-certs --upload-certs
```

### 4. Verify

```bash
kubectl get nodes
# Check etcd member list — new member should appear
```

---

## Encryption at Rest

API server is configured with `--encryption-provider-config=/etc/kubernetes/enc/enc.yaml`. This encrypts Secrets in etcd at rest. The encryption config file lives on each control plane node at that path — it is **not** stored in this repo (contains the encryption key).

If rebuilding a control plane node, the `enc.yaml` must be restored from 1Password before the API server starts, or Secrets will be unreadable.

---

## See Also

- `hosts/k8s/kubeadm-config.yaml` — authoritative cluster configuration (etcd data dir, networking, API server args)
- `hosts/k8s/kubelet-config.yaml` — kubelet configuration on all nodes
- `docs/infrastructure.md` — Kubernetes section (version, endpoints, node IPs)
- `k8s-vollminlab-cluster` repo — Sealed Secrets sealing key backup, Flux workloads
