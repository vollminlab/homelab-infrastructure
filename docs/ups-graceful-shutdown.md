# UPS graceful shutdown

Status: **built and dry-run verified, NOT armed.** The UPS service still has its
stock settings, so a power event today behaves exactly as it did before. Arming
is a deliberate, separate step — see "Arming it" below.

Date: 2026-08-17

## The problem

One CyberPower CP1500EPFCLCD feeds the three ESXi hosts and the TrueNAS box. It
has no network management card, and its only signalling path is USB-HID to the
NAS, which runs NUT in master mode.

18 of the 22 running VMs — including vCenter itself — live on TrueNAS storage:

| Datastore | Backing | VMs |
|---|---|---|
| `vmstore1` / `vmstore2` | TrueNAS iSCSI, zvols `pool_1/vmstorage/vmstore{1,2}` | 17, incl. `vcenter` and workers 02–06 |
| `vm-lt-metrics` | TrueNAS NFS, `/mnt/pool_0/vm-lt-metrics` | second disk on `k8sworker01` |
| `esxi0N-local` | local NVMe | `k8scp01/02/03` only |

The stock UPS config is `shutdown=LOWBATT`, `shutdowntimer=30`, `powerdown=true`.
So on a long outage the NAS reaches low battery, shuts *itself* down first, and
then tells the UPS to cut the outlets feeding the still-running hosts. Storage
disappears from underneath 18 live guests, and moments later they are hard-killed.

That is an all-paths-down event on mounted filesystems followed by a power cut —
a manufactured version of the ext4 damage that cost ~200 Audiobookshelf covers in
July, which Longhorn reported as `healthy` the entire time because every replica
held an identical copy of the corruption.

**Runtime is not the constraint.** Measured over an hour: 1300–1450 s (22–24 min)
at ~30 % load, charge 100 %. A full graceful sequence needs well under ten
minutes. This is a solvable ordering problem, not a reason to buy hardware.

> The UPS service's `description` field says "CyberPower 3000VA". That is wrong —
> the driver string resolves to `CP1500EPFCLCD`, i.e. 1500 VA / ~900 W. Anyone
> sizing a timer from the description would plan against roughly double the real
> budget.

## What was ruled out

- **ESXi VM Startup/Shutdown ordering** — unavailable. `dasConfig.enabled=true`;
  vSphere deactivates per-host autostart for hosts in an HA cluster by design.
- **NutClient-ESXi VIB** (rgc2000) — the author states plainly: *"You should not
  use it for ESXi nodes in an HA cluster, otherwise the virtual machines will be
  abruptly stopped."* It is also an unsigned community VIB.
- **NUT slaves on the guests** — native and elegant, and `hostsync` would make the
  master wait for them. But it covers only Linux guests: the vCenter and VCHA
  appliances cannot run it, and the ESXi hosts still need a separate poweroff
  step. It also means an agent on ~13 hosts, only 9 of which are in the Ansible
  inventory.

## The design

TrueNAS is the NUT master, holds the UPS, and must be the last thing to power
off — so it is the orchestrator. Its `shutdowncmd` field replaces NUT's default
`/sbin/shutdown -p now`, which makes it the correct hook.

Control flows to **each ESXi host's own API**, not to vCenter:

```
TrueNAS  (NUT master; UPS on battery)
  └─ shutdowncmd → ups-graceful-shutdown.sh
       ├─ esxi01 API ─ ShutdownGuest × 10 VMs ─ poll ─ force stragglers ─ poweroff host
       ├─ esxi02 API ─ ShutdownGuest ×  7 VMs ─ poll ─ force stragglers ─ poweroff host
       └─ esxi03 API ─ ShutdownGuest ×  5 VMs ─ poll ─ force stragglers ─ poweroff host
  └─ then, and only then, poweroff the NAS
```

The three hosts are driven in parallel. vCenter is deliberately absent from the
path for two reasons: it is itself a VM on the storage being torn down, and VCHA
is live (`vcenter` + `vcenter-Passive` + `vcenter-Witness`), so shutting the
active node mid-sequence would trigger a failover. Going host-direct means each
appliance is simply shut down by whichever host it happens to run on, and the
sequence still completes if vCenter is already dead.

Graceful guest shutdown is delivered by VMware Tools, and Tools coverage is
**22/22 powered-on VMs** — every guest, including the Photon-based vCenter and
VCHA appliances and the vCLS agents. No per-guest configuration is required.

Nothing drains Kubernetes. The whole cluster is going down, so cordoning or
draining would only migrate pods onto nodes that are about to die. A Tools
shutdown triggers a normal systemd shutdown inside each node, which stops kubelet
and unmounts volumes cleanly — which is the property that matters.

## Files

Mastered here, deployed to the NAS:

| Repo path | Deployed to |
|---|---|
| `scripts/ups-shutdown/ups-graceful-shutdown.sh` | `/mnt/pool_0/scripts/ups-shutdown/` |
| `scripts/ups-shutdown/ups-shutdown.env.example` | → `ups-shutdown.env` (0600, **not** in git) |
| — | `govc` static binary, same directory |

`pool_0/scripts` is a dataset created for this, so it survives TrueNAS upgrades —
the root filesystem does not.

`ups-shutdown.env` holds an ESXi root credential in cleartext. That is
unavoidable: the script runs unattended from NUT during a power event, so it
cannot prompt and 1Password is unreachable by then. File permissions are the
control. The value comes from 1Password item **ESXi Root** (Homelab vault).
Hardening follow-up: replace root with a dedicated ESXi local user holding only
the shutdown privileges.

## Safety properties

- **The NAS always powers off.** Every exit path, including a missing config file
  or an unusable `govc`, ends in `poweroff_nas()`. A bug must never leave the NAS
  running until the battery dies — that ends in exactly the uncontrolled power
  loss this exists to prevent.
- **A hard deadline** (`TOTAL_DEADLINE`, default 600 s) bounds the whole run. When
  it expires the NAS powers off regardless of what is still in flight.
- **Per-host guest timeout** (`GUEST_TIMEOUT`, default 240 s), after which
  stragglers are forced off so one stuck guest cannot block its host.
- **Host poweroff is confirmed**, not assumed — the script polls until the host
  stops answering on 443, so a silently-failed shutdown is visible in the log.
- **A guest without running Tools is powered off immediately** rather than waiting
  out the full timeout, since no graceful path exists for it.

## Verification so far

Dry run on the NAS, 2026-08-17. It enumerated all three hosts and 22 powered-on
VMs, resolved each HostSystem inventory path, and printed the full plan without
touching anything:

```
[esxi01] 10 powered-on VMs (10 via Tools)
[esxi02]  7 powered-on VMs (7 via Tools)
[esxi03]  5 powered-on VMs (5 via Tools)
```

The deadline path was exercised separately against a black-hole address
(`192.0.2.1`, TEST-NET-1) and fired correctly at 25 s, killing the outstanding
host job before powering off.

The dry run found two defects that would have been fatal in a real event:

1. **The completion wait returned instantly.** `wait` only accepts the calling
   shell's own children, so delegating it to a subshell made the script declare
   "all hosts finished" after 5 s and power the NAS off while every guest was
   still shutting down — reproducing the exact failure being fixed.
2. **Environment overrides were silently ignored.** Sourcing the env file
   overwrote them, so a test run with substituted hosts acted on the *real* hosts
   instead. Precedence is now environment > env file > defaults.

**What is still unmeasured:** how long a real graceful shutdown actually takes.
`GUEST_TIMEOUT=240` and `TOTAL_DEADLINE=600` are conservative bounds sized against
the 22-minute runtime, not observations. A real timed run — ideally a planned
maintenance-window power-down — is what would turn `shutdowntimer` into an
evidence-based number.

## Testing it

```bash
# Dry run — enumerates and prints the plan, changes nothing
ssh vollmin@192.168.150.2
sudo -i
cd /mnt/pool_0/scripts/ups-shutdown && DRY_RUN=1 ./ups-graceful-shutdown.sh

# Exercise the deadline without touching real hosts
DRY_RUN=1 ESXI_HOSTS="blackhole=192.0.2.1" TOTAL_DEADLINE=25 ./ups-graceful-shutdown.sh
```

Logs land in `/mnt/pool_0/scripts/ups-shutdown/logs/ups-shutdown.log`.

## Arming it (not yet done)

Three fields on the UPS service, none of which have been changed:

| Field | Now | Target | Why |
|---|---|---|---|
| `shutdowncmd` | `null` | `/mnt/pool_0/scripts/ups-shutdown/ups-graceful-shutdown.sh` | replaces the default bare poweroff |
| `shutdown` | `LOWBATT` | `BATT` | start the sequence with battery to spare, not at the cliff |
| `shutdowntimer` | `30` | measured, likely 180–300 | seconds on battery before triggering; rides out brownouts |

`powerdown=true` stays as it is — cutting the outlets after the NAS is down is
correct once the hosts are already off.

Before arming, be aware the trigger becomes a *duration on battery*, so any
outage longer than `shutdowntimer` powers the lab down. That is the intent, but
it does make brief flickers consequential if the timer is set too low.

## Access notes

- TrueNAS SSH works as **`vollmin@192.168.150.2`** with the `truenas_id_rsa` key
  from 1Password. Earlier attempts failed only because they used `root` /
  `truenas_admin`; root has no authorized key and is refused for password auth.
  `192.168.100.5` is the IPMI/BMC, not the NAS, and `192.168.152.2` is NPM.
- `sudo` for `vollmin` requires the password (1Password item **TrueNAS**).
- The UPS state is readable without SSH via the API — `POST /api/v2.0/reporting/netdata_get_data`
  with graphs `upsruntime`, `upsload`, `upscharge`. The wrapper key is `query`;
  `reporting_query` returns HTTP 400.
- `GET /api/v2.0/ups` returns `monpwd` in cleartext — never redirect it to a file.
