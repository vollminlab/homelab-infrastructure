# UPS startup orchestration — plan

**Status:** proposal, for review
**Counterpart:** [ups-graceful-shutdown.md](ups-graceful-shutdown.md), which is complete and verified

The shutdown path brings 22 guests, 3 hosts and the NAS down cleanly when the
battery runs out. Nothing brings them back. Today recovery is entirely manual:
power each host by hand, then power on guests in whatever order occurs to you.

## The one design decision that matters

**Hosts power themselves on from firmware; the NAS owns only the guests.**

The instinct is to have the NAS wake the hosts once storage is ready, so nothing
ever boots into a world without datastores. That is the wrong trade, because it
makes host power-on depend on a chain of things that can each fail silently —
switches up, AMT provisioned and its credential valid, NAS booted, script correct
— and the failure mode when any link breaks is **hosts stay off**: a total outage
needing hands. BIOS AC-recovery depends on nothing, and its failure mode is a host
sitting idle with no datastores, which costs nothing because per-host autostart is
disabled by vSphere for HA-cluster hosts and HA does not restart guests that were
cleanly powered off.

| Layer | Owner | Why |
| --- | --- | --- |
| Host power-on | **BIOS "restore on AC power loss"** | zero dependencies; benign failure mode |
| Guest power-on, ordering, gating | **NAS startup orchestrator** | only the NAS knows when storage is actually serving |
| A host that did not come back | **Intel AMT**, manual or as a fallback | out-of-band, no BMC on the MS-01s |

Rejected, with reasons, so they are not re-proposed:

- **AMT-driven host power-on as the primary path** — see above. Viable as a
  *fallback* after a timeout, at the cost of putting AMT credentials on the NAS.
- **ESXi per-host autostart** — vSphere disables it for hosts in an HA cluster.
- **Doing nothing and recovering by hand** — the status quo; acceptable only
  because outages have been rare, and it scales badly at 2am.

## What the inventory forces

Measured 2026-09-16.

- **All three control planes are on host-local NVMe** (`esxi0N-local`). Each can
  only ever run on its own host — but equally, each can start **without the NAS**.
  etcd quorum can therefore form before storage is serving.
- Everything else lives on `vmstore1`/`vmstore2` (TrueNAS iSCSI); `k8sworker01`
  also touches `vm-lt-metrics` (NFS).
- **Pi-hole is not a VM here**, so DNS does not depend on this sequence at all.
- `vCLS-*` are vCenter-managed and must **not** be powered on by hand.
  `ubuntu-template` is a template and is never powered on.

### Proposed tiers

| Tier | Guests | Gate before starting |
| --- | --- | --- |
| 0 | `k8scp01/02/03` | their own host is up — **no storage dependency** |
| 1 | `vcenter` | storage serving |
| 2 | `haproxy01/02`, `nginx01` | tier 1 settled (k8s API VIP + reverse proxy) |
| 3 | `k8sworker01`-`04` | tier 2 settled |
| 4 | `k8sworker05/06` (DMZ) | tier 3 settled |
| 5 | `ansible01`, `groupme01`, `devsbx01`, `haproxydmz01/02`, `vcenter-Passive`, `vcenter-Witness` | tier 4 settled |

Tiers are **staggered deliberately**. Powering 22 guests onto two shared VMDK
datastores at once is precisely the I/O storm that drove PSI full-stall to 26-48 %
during backups and took three nodes `NotReady` on 2026-08-25. Wait for VMware Tools
to report in on a tier before starting the next, with a per-tier timeout so one
stuck guest cannot stall the sequence.

## Gates — the parts that prevent this from making things worse

1. **Storage is genuinely serving**: pools `ONLINE`, 3260 listening locally, the
   NFS export present. Not "the NAS booted".
2. **Power is genuinely back**: `ups.status` is `OL` **and** `battery.charge` is
   above a threshold (proposed 50 %). Without this, a flapping utility gives a
   boot/shutdown loop — the mirror image of the problem the shutdown path solves,
   and worse, because each cycle is a hard stop for anything mid-boot.
3. **The host answers on 443** before any guest is aimed at it, with a timeout.
4. **Idempotent throughout**: skip guests already powered on, single lockfile,
   safe to re-run by hand at any point. It must be usable as a recovery tool, not
   only as an automation.

## What to gate on — and what not to

A real observation from the 2026-09-16 rehearsal, worth designing against.
When `k8scp03` rebooted, `metallb-speaker` crash-looped with:

```
dial tcp 10.96.0.1:443: i/o timeout
```

It had started before kube-proxy and Calico finished programming the service
network. It recovered on its own within a minute. The tempting conclusion is that
the orchestrator should wait for Kubernetes to be *ready* before proceeding.

**It should not, and could not.** That race is **intra-node**: kubelet starts every
DaemonSet pod on a node at roughly the same moment, and metallb-speaker lost a
footrace against two peers started by the same kubelet on the same machine. No
ordering of *virtual machines* can affect it. CrashLoopBackOff is the mechanism
working — retry with backoff until the dependency exists.

Gating on Kubernetes object state would also invert the dependency graph. The NAS
would need a kubeconfig, a token and a route to the API — and the API VIP is
`haproxy01/02`, **virtual machines this orchestrator is responsible for starting**.
It would be waiting on something it has not started yet. Worse, it couples the
power layer to the application layer, so a Kubernetes problem stalls VM power-on,
turning a self-healing annoyance into a stuck recovery. That is the same trade
rejected for AMT-driven host power-on, for the same reason.

**The rule: gate on reachability of what the next tier needs, never on the health
of what the last tier runs.** Every gate must be answerable with no credentials and
no cluster knowledge.

| Before | Wait for | Mechanism |
| --- | --- | --- |
| any tier | previous tier's guests actually booted | VMware Tools heartbeat via `govc` |
| tier 3 (workers) | the k8s API answering | `nc -z 192.168.152.7 6443` (HAProxy VIP) |
| tier 1 | storage serving | pools ONLINE, 3260 listening, NFS exported |

If application-level ordering is ever genuinely needed, its home is **in-cluster** —
startup probes, init containers, or a post-boot Job. Kubernetes has those
primitives; the NAS does not and should not.

## Two privileges the `ups-shutdown` role does not have

The role was built for shutting down. Starting up needs:

- **`VirtualMachine.Interact.PowerOn`** — mandatory; the role holds only `PowerOff`.
- **`Host.Config.Storage`** — only if the orchestrator forces
  `govc host.storage.rescan` so datastores appear promptly rather than waiting for
  ESXi's own retry. Worth deciding: the rescan removes a several-minute wait, at
  the cost of one more privilege.

Either extend the existing role or create a second `ups-startup` role. **Extending
is simpler and the blast radius is identical** — anything that can power a guest
off can power it on.

## The dirty-outage case, which is the interesting one

Everything above describes recovery from a *clean* orchestrated shutdown. After a
**dirty** outage — orchestration failed, or the UPS died first — hosts boot with
AC-recovery and **HA restarts every guest that was running at the moment of host
failure**, unordered, all at once, possibly before the NAS is serving.

That is self-healing but stormy, and it bypasses the tiering entirely.

**Proposal: set vSphere HA restart priorities to mirror the tiers.** HA supports
five priority levels plus "start next priority when: resources allocated / powered
on / guest heartbeat detected". Configuring them costs nothing, changes nothing in
the clean path, and gives the dirty path the same ordering for free. This is the
cheapest robustness win available here and it should probably land before the
orchestrator itself.

Note the three CPs already have `restartPriority: disabled`, correctly — their
storage is local, so HA could never restart them elsewhere.

## Testing, mirroring what the shutdown path now has

1. **`VERIFY=1`** — probe every action without performing it: hosts reachable,
   credential valid, `PowerOn` privilege held, each guest resolvable, gates
   evaluable. Exit status is the verdict.
2. **Stubbed test suite in CI** — gate logic, tier ordering, idempotency,
   timeout handling. No cluster required.
3. **A real rehearsal is cheap here, unlike shutdown**: power off one expendable
   guest and let the orchestrator bring it back. There is no equivalent of
   "you must down a host to test it".
4. **Extend `ups-preflight.sh`** to cover the startup path's own drift.

## Open questions for review

1. **Threshold for gate 2** — 50 % charge, or time-based (`battery.runtime` above
   the full sequence's worst case)?
2. **AMT fallback** — power a host on after N minutes, or page instead? It means
   AMT credentials on the NAS.
3. **`host.storage.rescan`** — worth the extra privilege to skip the wait?
4. **HA restart priorities** — land these first, independently of the orchestrator?
5. **Does `devsbx01` belong in tier 5?** It is where Claude sessions run, so
   bringing it up earlier may be convenient during a recovery.

*(A sixth — whether to gate on DaemonSet/pod readiness — is answered above: no.
Recorded rather than dropped, so it is not re-proposed.)*

## Work breakdown

| PR | Contents |
| --- | --- |
| 1 | HA restart priorities mirroring the tiers (independent, useful alone) |
| 2 | Role extension: `VirtualMachine.Interact.PowerOn` (+ `Host.Config.Storage`?) |
| 3 | `ups-graceful-startup.sh` + `VERIFY=1` + stubbed tests + systemd unit |
| 4 | Preflight extension, docs, one live rehearsal with a single guest |
