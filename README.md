# homelab-infrastructure

Source-of-truth for Vollminlab infrastructure configuration. Scripts collect configs from live hosts into this repo for drift detection, disaster recovery, and reference.

## Structure

```
hosts/          Collected configs, one subdirectory per host/system
  pihole1/      Pi-hole primary (DNS, keepalived, nebula-sync)
  pihole2/      Pi-hole secondary
  haproxy01/    HAProxy + keepalived (internal VIP)
  haproxy02/    HAProxy + keepalived (internal VIP)
  haproxydmz01/ HAProxy + keepalived (DMZ VIP)
  haproxydmz02/ HAProxy + keepalived (DMZ VIP)
  nginx01/      Nginx Proxy Manager (docker-compose + NPM proxy configs)
  groupme01/    GroupMe bridge service
  truenas/      TrueNAS SCALE (pools, datasets, shares, services)
  udm/          UniFi Dream Machine SE (network config, redacted)
  k8s/          Kubernetes cluster (kubeadm config, kubelet config, nodes)
  vsphere/      vSphere/vCenter (VMs, hosts, networking, storage, permissions)
  windows/      Windows admin workstation (SSH config)

scripts/        Collection scripts
docs/           Runbooks and setup notes
```

## Collecting configs

Run from a terminal with your 1Password SSH agent active:

```bash
bash scripts/collect-all.sh
```

This runs all collectors in sequence: SSH hosts → NPM → TrueNAS → Kubernetes → vSphere.

Individual collectors can be run independently:

```bash
bash scripts/collect-host-configs.sh           # all SSH hosts
bash scripts/collect-host-configs.sh pihole1   # specific host
bash scripts/collect-npm-configs.sh
bash scripts/collect-truenas-configs.sh
bash scripts/collect-k8s-configs.sh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/Export-VSphereConfigs.ps1
```

After collecting, review and commit:

```bash
git diff --stat
git diff
git add -p
git commit
```

## Credentials

All credentials are retrieved from 1Password via the `op` CLI. No secrets are stored in this repo — sensitive fields are either redacted in collected configs or excluded entirely.

## Docs

- [Infrastructure reference](docs/infrastructure.md) — Full host inventory, network layout, and DR notes for every system
- [SSH setup](docs/ssh-setup.md) — 1Password SSH agent configuration and host aliases
- [Pi-hole TLS](docs/pihole-tls.md) — Self-signed cert generation for Pi-hole web UI
- [Pi-hole hardware](docs/pihole-hardware.md) — Physical hardware and OS setup for the Pi-hole nodes
- [etcd](docs/etcd.md) — etcd backup and restore procedures for the Kubernetes cluster
- [Credential rotation](docs/credential-rotation.md) — Procedures for rotating secrets and API keys
- [Maintenance day](docs/maintenance-day.md) — Routine maintenance checklist and procedures
- [Syncthing](docs/syncthing.md) — Syncthing configuration for vault and file sync
