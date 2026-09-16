#!/usr/bin/env bash
# ups-graceful-startup.sh — bring the lab back up after a power event, in order.
#
# The mirror of ups-graceful-shutdown.sh, and deliberately NOT its inverse.
#
# Hosts are not started here. They power themselves on from BIOS "restore on AC
# power loss", which depends on nothing — no network, no NAS, no AMT, no
# credential that can expire — and whose failure mode is a host idling without
# datastores, which costs nothing because per-host autostart is disabled by
# vSphere for HA-cluster hosts. Having the NAS wake the hosts would make host
# power-on depend on switches, AMT provisioning and this script all being correct,
# and its failure mode would be hosts staying OFF: a total outage needing hands.
#
# So this script owns exactly one thing: powering GUESTS on, in tiers, once it has
# proven that the conditions for doing so actually hold.
#
# Usage:
#   ups-graceful-startup.sh             # real run (as invoked by systemd at boot)
#   VERIFY=1 ups-graceful-startup.sh    # probe every gate and action, change nothing
#   DRY_RUN=1 ups-graceful-startup.sh   # print the plan only
#
# Gates, and the rule behind them: gate on the REACHABILITY of what the next tier
# needs, never on the HEALTH of what the last tier runs. Every gate here is
# answerable with no credentials and no cluster knowledge. See
# docs/ups-startup-orchestration.md for why gating on Kubernetes readiness is
# wrong (short version: the races it would try to fix are intra-node, and the k8s
# API lives on VMs this script is responsible for starting).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/ups-shutdown.env}"   # same credential as shutdown
GOVC="${GOVC:-$SCRIPT_DIR/govc}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/ups-startup.log}"
PUSHOVER_ENV="${PUSHOVER_ENV:-$SCRIPT_DIR/pushover.env}"
LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/logs/.startup.lock}"

# ── Tiers ─────────────────────────────────────────────────────────────────────
#
# "tier:vm,vm,vm", in order. An explicit allowlist, not a glob: a powered-off VM
# that appears in no tier is reported and left alone. Starting something nobody
# listed is how a template or a deliberately-parked VM gets woken up.
#
# Tier 0 has no storage dependency — all three control planes live on their own
# host's local NVMe, so etcd quorum can form before the NAS is serving anything.
TIERS_DEFAULT="\
0:k8scp01,k8scp02,k8scp03 \
1:vcenter \
2:haproxy01,haproxy02,nginx01 \
3:k8sworker01,k8sworker02,k8sworker03,k8sworker04 \
4:k8sworker05,k8sworker06 \
5:ansible01,groupme01,devsbx01,haproxydmz01,haproxydmz02,vcenter-Passive,vcenter-Witness"

# Never touched, whatever a tier says: vCLS agents are recreated by vCenter and
# must not be hand-started; templates cannot be powered on at all.
NEVER_START_DEFAULT="vCLS- ubuntu-template"

# ── Tunables ──────────────────────────────────────────────────────────────────
UPS_MIN_CHARGE_DEFAULT=50      # % — below this, mains is back but the buffer is not
UPS_WAIT_DEFAULT=900           # s to wait for OL + charge before giving up
UPS_GATE_REQUIRED_DEFAULT=0    # 1 = refuse to start if the UPS cannot be read
STORAGE_WAIT_DEFAULT=900       # s to wait for pools + iSCSI + NFS
HOST_WAIT_DEFAULT=900          # s to wait for a host's API to answer
API_VIP_DEFAULT=192.168.152.7  # HAProxy VIP fronting the k8s API
API_PORT_DEFAULT=6443
API_WAIT_DEFAULT=600           # s to wait for the k8s API before starting workers
TIER_WAIT_DEFAULT=300          # s to wait for a tier's guests to report Tools
TIER_DELAY_DEFAULT=15          # s between tiers, to smooth the I/O burst
ISCSI_PORT_DEFAULT=3260
NFS_EXPORT_DEFAULT=/mnt/pool_0/vm-lt-metrics
ZPOOLS_DEFAULT="pool_0 pool_1"
RESCAN_STORAGE_DEFAULT=0       # 1 needs Host.Config.Storage on the role — off by default
AMT_FALLBACK_DEFAULT=0         # 1 would need AMT credentials on the NAS — off by default

# Seams, so the test suite can stub every external dependency.
UPSC="${UPSC:-upsc}"
ZPOOL="${ZPOOL:-zpool}"
NC="${NC:-nc}"
CURL="${CURL:-curl}"
SS="${SS:-ss}"
UPS_IDENT="${UPS_IDENT:-ups@localhost}"

DRY_RUN="${DRY_RUN:-0}"
VERIFY="${VERIFY:-0}"
(( VERIFY )) && DRY_RUN=1
ALERT="${ALERT:-1}"

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" 2>/dev/null
if [[ -n "${LOG_FILE:-}" ]] && ! { : >> "$LOG_FILE"; } 2>/dev/null; then
  echo "WARNING: $LOG_FILE is not writable — logging to stdout only" >&2
  LOG_FILE=""
fi
log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  [[ -n "${LOG_FILE:-}" ]] && echo "$msg" >> "$LOG_FILE" 2>/dev/null
  return 0
}

FAILURES=""
fail_note() { FAILURES="${FAILURES}- $1"$'\n'; log "FAIL  $1"; }
probe_ok()   { log "  PROBE PASS  $*"; }
probe_fail() { log "  PROBE FAIL  $*"; FAILURES="${FAILURES}- $*"$'\n'; return 0; }

# ── Config precedence: environment > env file > defaults ──────────────────────
# Sourcing the env file would otherwise clobber an override passed for a test run,
# which once made a test act on the real hosts (see the shutdown script's history).
OVERRIDABLE=(ESXI_USER ESXI_PASS ESXI_HOSTS TIERS NEVER_START UPS_MIN_CHARGE
             UPS_WAIT UPS_GATE_REQUIRED STORAGE_WAIT HOST_WAIT API_VIP API_PORT
             API_WAIT TIER_WAIT TIER_DELAY ISCSI_PORT NFS_EXPORT ZPOOLS
             RESCAN_STORAGE AMT_FALLBACK)
declare -A _ovr
for _v in "${OVERRIDABLE[@]}"; do [[ -n "${!_v:-}" ]] && _ovr["$_v"]="${!_v}"; done
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  log "WARNING: $ENV_FILE not found — falling back to environment only"
fi
for _v in "${OVERRIDABLE[@]}"; do
  [[ -n "${_ovr[$_v]:-}" ]] && printf -v "$_v" '%s' "${_ovr[$_v]}"
done
unset _v

TIERS="${TIERS:-$TIERS_DEFAULT}"
NEVER_START="${NEVER_START:-$NEVER_START_DEFAULT}"
UPS_MIN_CHARGE="${UPS_MIN_CHARGE:-$UPS_MIN_CHARGE_DEFAULT}"
UPS_WAIT="${UPS_WAIT:-$UPS_WAIT_DEFAULT}"
UPS_GATE_REQUIRED="${UPS_GATE_REQUIRED:-$UPS_GATE_REQUIRED_DEFAULT}"
STORAGE_WAIT="${STORAGE_WAIT:-$STORAGE_WAIT_DEFAULT}"
HOST_WAIT="${HOST_WAIT:-$HOST_WAIT_DEFAULT}"
API_VIP="${API_VIP:-$API_VIP_DEFAULT}"
API_PORT="${API_PORT:-$API_PORT_DEFAULT}"
API_WAIT="${API_WAIT:-$API_WAIT_DEFAULT}"
TIER_WAIT="${TIER_WAIT:-$TIER_WAIT_DEFAULT}"
TIER_DELAY="${TIER_DELAY:-$TIER_DELAY_DEFAULT}"
ISCSI_PORT="${ISCSI_PORT:-$ISCSI_PORT_DEFAULT}"
NFS_EXPORT="${NFS_EXPORT:-$NFS_EXPORT_DEFAULT}"
ZPOOLS="${ZPOOLS:-$ZPOOLS_DEFAULT}"
RESCAN_STORAGE="${RESCAN_STORAGE:-$RESCAN_STORAGE_DEFAULT}"
AMT_FALLBACK="${AMT_FALLBACK:-$AMT_FALLBACK_DEFAULT}"
ESXI_HOSTS="${ESXI_HOSTS:-esxi01=192.168.151.2 esxi02=192.168.151.3 esxi03=192.168.151.4}"

govc_host() {
  local addr=$1; shift
  GOVC_URL="https://${addr}/sdk" GOVC_USERNAME="$ESXI_USER" \
  GOVC_PASSWORD="$ESXI_PASS" GOVC_INSECURE=1 "$GOVC" "$@"
}

port_open() { timeout 5 "$NC" -z "$1" "$2" 2>/dev/null; }

# ── Gates ─────────────────────────────────────────────────────────────────────

# Is mains actually back, with a buffer? Without this, a flapping utility gives a
# boot/shutdown loop — the mirror image of the problem the shutdown path solves,
# and worse, because each cycle interrupts whatever was mid-boot.
gate_power() {
  local waited=0 status charge
  while :; do
    status=$("$UPSC" "$UPS_IDENT" ups.status 2>/dev/null)
    charge=$("$UPSC" "$UPS_IDENT" battery.charge 2>/dev/null)
    if [[ -z "$status" ]]; then
      # A broken NUT driver must not be able to prevent recovery: the NAS is
      # demonstrably running on mains to have booted at all. Warn and continue,
      # unless the operator has explicitly asked for fail-closed.
      if (( UPS_GATE_REQUIRED )); then
        fail_note "power gate: cannot read $UPS_IDENT and UPS_GATE_REQUIRED=1"
        return 1
      fi
      log "WARNING power gate: cannot read $UPS_IDENT — proceeding anyway (UPS_GATE_REQUIRED=0)"
      return 0
    fi
    if [[ "$status" == *OL* ]] && [[ -n "$charge" ]] && (( ${charge%%.*} >= UPS_MIN_CHARGE )); then
      log "power gate: OK (status='$status' charge=${charge}% >= ${UPS_MIN_CHARGE}%)"
      return 0
    fi
    if (( waited >= UPS_WAIT )); then
      fail_note "power gate: still not satisfied after ${UPS_WAIT}s (status='$status' charge='${charge}%')"
      return 1
    fi
    log "power gate: waiting (status='$status' charge='${charge}%')"
    sleep 15; waited=$((waited + 15))
  done
}

# Is storage actually SERVING — not merely "the NAS booted"? Every guest outside
# tier 0 lives on it.
gate_storage() {
  local waited=0 bad pool
  while :; do
    bad=""
    for pool in $ZPOOLS; do
      "$ZPOOL" list -H -o health "$pool" 2>/dev/null | grep -qx ONLINE || bad="$bad $pool"
    done
    "$SS" -lnt 2>/dev/null | grep -q ":${ISCSI_PORT}\b" || bad="$bad iscsi:${ISCSI_PORT}"
    [[ -d "$NFS_EXPORT" ]] || bad="$bad nfs:${NFS_EXPORT}"
    if [[ -z "$bad" ]]; then
      log "storage gate: OK (pools ONLINE, ${ISCSI_PORT} listening, ${NFS_EXPORT} present)"
      return 0
    fi
    if (( waited >= STORAGE_WAIT )); then
      fail_note "storage gate: not serving after ${STORAGE_WAIT}s —$bad"
      return 1
    fi
    log "storage gate: waiting —$bad"
    sleep 15; waited=$((waited + 15))
  done
}

gate_host() {
  local label=$1 addr=$2 waited=0
  while :; do
    port_open "$addr" 443 && { log "host gate: [$label] answering on 443 after ${waited}s"; return 0; }
    if (( waited >= HOST_WAIT )); then
      # Its guests simply cannot be started. Say so and carry on with the rest —
      # one dead host must not strand the hosts that did come back.
      fail_note "host gate: [$label] ($addr) never answered on 443 after ${HOST_WAIT}s"
      (( AMT_FALLBACK )) && log "  (AMT fallback is enabled but not implemented — see the plan doc)"
      return 1
    fi
    log "host gate: [$label] waiting for $addr:443"
    sleep 15; waited=$((waited + 15))
  done
}

# Workers want somewhere to register. This is a wait, not a hard gate: if the API
# never appears, starting the workers anyway is harmless and they will retry.
gate_api() {
  local waited=0
  while :; do
    port_open "$API_VIP" "$API_PORT" && { log "api gate: OK (${API_VIP}:${API_PORT} answering)"; return 0; }
    if (( waited >= API_WAIT )); then
      log "WARNING api gate: ${API_VIP}:${API_PORT} not answering after ${API_WAIT}s — continuing anyway"
      return 0
    fi
    log "api gate: waiting for ${API_VIP}:${API_PORT}"
    sleep 15; waited=$((waited + 15))
  done
}

# ── Inventory ─────────────────────────────────────────────────────────────────
#
# Build name -> "label addr powerState template" once. A powered-off guest is still
# registered to its home host, which is what makes a startup order expressible at
# all; and for the three control planes it is the ONLY host they can run on, since
# their disks are on that host's local datastore.

declare -A VM_HOST VM_ADDR VM_STATE VM_TEMPLATE
declare -A HOST_UP

build_inventory() {
  local entry label addr paths
  for entry in $ESXI_HOSTS; do
    label="${entry%%=*}"; addr="${entry##*=}"
    if ! port_open "$addr" 443; then
      log "inventory: [$label] ($addr) not answering on 443 — will gate later"
      HOST_UP[$label]=0
      continue
    fi
    HOST_UP[$label]=1
    paths=$(govc_host "$addr" ls /ha-datacenter/vm 2>/dev/null)
    [[ -z "$paths" ]] && { log "inventory: [$label] enumerated nothing"; continue; }
    # shellcheck disable=SC2046
    while IFS=$'\t' read -r name state tmpl; do
      [[ -z "$name" ]] && continue
      VM_HOST[$name]="$label"; VM_ADDR[$name]="$addr"
      VM_STATE[$name]="$state"; VM_TEMPLATE[$name]="$tmpl"
    done < <(govc_host "$addr" vm.info -json $(echo "$paths" | tr '\n' ' ') 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for vm in d.get("virtualMachines") or []:
    cfg = vm.get("config") or {}
    print("\t".join([vm.get("name","?"),
                     (vm.get("runtime") or {}).get("powerState","unknown"),
                     "template" if cfg.get("template") else "vm"]))
')
  done
  log "inventory: ${#VM_HOST[@]} guests across $(echo "$ESXI_HOSTS" | wc -w) host(s)"
}

is_never_start() {
  local name=$1 pat
  for pat in $NEVER_START; do [[ "$name" == *"$pat"* ]] && return 0; done
  return 1
}

# ── Starting a tier ───────────────────────────────────────────────────────────

start_tier() {
  local tier=$1 vms=$2 started=() name addr label
  log "=== tier $tier: ${vms//,/ } ==="
  for name in ${vms//,/ }; do
    if is_never_start "$name"; then
      log "[$name] skipped — on the never-start list"; continue
    fi
    if [[ -z "${VM_HOST[$name]:-}" ]]; then
      fail_note "tier $tier: '$name' is in no host's inventory (host down, or renamed?)"
      continue
    fi
    label="${VM_HOST[$name]}"; addr="${VM_ADDR[$name]}"
    if [[ "${VM_TEMPLATE[$name]}" == "template" ]]; then
      log "[$name] skipped — it is a template"; continue
    fi
    if [[ "${VM_STATE[$name]}" == "poweredOn" ]]; then
      log "[$name] already powered on — skipping (idempotent)"; continue
    fi
    gate_host "$label" "$addr" || { fail_note "tier $tier: '$name' unreachable host $label"; continue; }
    if (( DRY_RUN )); then
      log "[$name] DRY-RUN would power on (host $label)"
      (( VERIFY )) && probe_ok "[$name] resolvable on $label, state=${VM_STATE[$name]}"
      continue
    fi
    log "[$name] powering on (host $label)"
    if govc_host "$addr" vm.power -on "$name" >/dev/null 2>&1; then
      started+=("$name")
    else
      fail_note "tier $tier: power-on failed for '$name' on $label"
    fi
  done

  (( DRY_RUN )) && return 0
  (( ${#started[@]} == 0 )) && { log "tier $tier: nothing started"; return 0; }

  # Wait for the tier to actually be up before loading the datastores further.
  # Tools reporting is the coarsest signal that means "this guest booted"; it is
  # deliberately not an application-level check.
  # pending MUST be initialised: it is only assigned inside the loop below, and
  # with TIER_WAIT=0 (or an immediately-satisfied tier) the loop never runs, so
  # the log line after it would reference an unset variable — fatal under `set -u`,
  # and it killed the script silently right after the first power-on.
  local waited=0 pending=""
  while (( waited < TIER_WAIT )); do
    pending=""
    for name in "${started[@]}"; do
      govc_host "${VM_ADDR[$name]}" vm.info -json "$name" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
vm=(d.get("virtualMachines") or [{}])[0]
sys.exit(0 if (vm.get("guest") or {}).get("toolsRunningStatus")=="guestToolsRunning" else 1)
' || pending="$pending $name"
    done
    [[ -z "$pending" ]] && { log "tier $tier: all guests reporting Tools after ${waited}s"; return 0; }
    sleep 15; waited=$((waited + 15))
  done
  [[ -n "$pending" ]] \
    && log "WARNING tier $tier: still waiting on Tools for$pending after ${TIER_WAIT}s — continuing" \
    || log "tier $tier: not waiting on Tools (TIER_WAIT=${TIER_WAIT}s)"
  return 0
}

# ── VERIFY probes ─────────────────────────────────────────────────────────────
#
# Same rule as the shutdown script: a rehearsal must EXECUTE something for every
# line the real run executes. Every gate here is read-only, so VERIFY can exercise
# all of them for real — the only action it cannot perform is the power-on itself.

probe_privileges() {
  local entry label addr perms role privs
  for entry in $ESXI_HOSTS; do
    label="${entry%%=*}"; addr="${entry##*=}"
    [[ "${HOST_UP[$label]:-0}" == 1 ]] || { probe_fail "[$label] host not reachable"; continue; }
    local hostsys; hostsys=$(govc_host "$addr" find / -type h 2>/dev/null | head -1)
    [[ -z "$hostsys" ]] && { probe_fail "[$label] HostSystem path did not resolve"; continue; }
    perms=$(govc_host "$addr" permissions.ls "$hostsys" 2>/dev/null)
    role=$(awk -v u="$ESXI_USER" '$3==u {print $1}' <<< "$perms" | head -1)
    [[ -z "$role" ]] && { probe_fail "[$label] '$ESXI_USER' has no permission entry"; continue; }
    if [[ "$role" == "Admin" ]]; then
      probe_ok "[$label] '$ESXI_USER' holds Admin (every privilege)"; continue
    fi
    privs=$(govc_host "$addr" role.ls "$role" 2>/dev/null)
    if grep -qxF "VirtualMachine.Interact.PowerOn" <<< "$privs"; then
      probe_ok "[$label] role '$role' holds VirtualMachine.Interact.PowerOn"
    else
      probe_fail "[$label] role '$role' lacks VirtualMachine.Interact.PowerOn — cannot start anything"
    fi
    if (( RESCAN_STORAGE )) && ! grep -qxF "Host.Config.Storage" <<< "$privs"; then
      probe_fail "[$label] RESCAN_STORAGE=1 but role '$role' lacks Host.Config.Storage"
    fi
  done
}

probe_gates() {
  local status charge
  status=$("$UPSC" "$UPS_IDENT" ups.status 2>/dev/null)
  charge=$("$UPSC" "$UPS_IDENT" battery.charge 2>/dev/null)
  if [[ -n "$status" ]]; then
    probe_ok "power gate readable: status='$status' charge=${charge}% (threshold ${UPS_MIN_CHARGE}%)"
  elif (( UPS_GATE_REQUIRED )); then
    probe_fail "power gate: $UPS_IDENT unreadable and UPS_GATE_REQUIRED=1 would refuse to start"
  else
    probe_ok "power gate: $UPS_IDENT unreadable, but UPS_GATE_REQUIRED=0 would proceed"
  fi

  local pool bad=""
  for pool in $ZPOOLS; do
    "$ZPOOL" list -H -o health "$pool" 2>/dev/null | grep -qx ONLINE || bad="$bad $pool"
  done
  [[ -z "$bad" ]] && probe_ok "storage gate: pools ONLINE ($ZPOOLS)" \
                  || probe_fail "storage gate: pools not ONLINE —$bad"
  "$SS" -lnt 2>/dev/null | grep -q ":${ISCSI_PORT}\b" \
    && probe_ok "storage gate: iSCSI ${ISCSI_PORT} listening" \
    || probe_fail "storage gate: nothing listening on ${ISCSI_PORT}"
  [[ -d "$NFS_EXPORT" ]] && probe_ok "storage gate: $NFS_EXPORT present" \
                         || probe_fail "storage gate: $NFS_EXPORT missing"
  port_open "$API_VIP" "$API_PORT" \
    && probe_ok "api gate: ${API_VIP}:${API_PORT} answering" \
    || probe_fail "api gate: ${API_VIP}:${API_PORT} not answering"
}

# Anything powered off that no tier claims would be silently left behind in a real
# recovery. Better to say so now than to discover it during one.
probe_unlisted() {
  local listed=" " t name
  for t in $TIERS; do listed="$listed${t#*:} "; done
  listed="${listed//,/ }"
  local orphans=""
  for name in "${!VM_STATE[@]}"; do
    [[ "${VM_STATE[$name]}" == "poweredOn" ]] && continue
    [[ "${VM_TEMPLATE[$name]}" == "template" ]] && continue
    is_never_start "$name" && continue
    [[ " $listed " == *" $name "* ]] || orphans="$orphans $name"
  done
  [[ -z "$orphans" ]] && probe_ok "no powered-off guest is missing from the tiers" \
                      || probe_fail "powered-off and in no tier, so never started:$orphans"
}

alert_on_failure() {
  [[ -z "$FAILURES" ]] && return 0
  (( ALERT )) || return 0
  [[ -r "$PUSHOVER_ENV" ]] || { log "WARNING $PUSHOVER_ENV unreadable — no alert sent"; return 0; }
  # shellcheck disable=SC1090
  . "$PUSHOVER_ENV"
  [[ -n "${PUSHOVER_TOKEN:-}" && -n "${PUSHOVER_USER:-}" ]] || {
    log "WARNING no Pushover credentials — no alert sent"; return 0; }
  "$CURL" -sf -m 20 https://api.pushover.net/1/messages.json \
    -F "token=$PUSHOVER_TOKEN" -F "user=$PUSHOVER_USER" -F priority=1 \
    -F "title=UPS startup orchestration had failures on $(hostname)" \
    -F "message=$FAILURES" >/dev/null \
    && log "alert sent to Pushover" || log "WARNING Pushover alert failed to send"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# One at a time. A second copy racing the first would double-power-on and double
# the I/O burst this whole design exists to spread out.
exec 9> "$LOCK_FILE" 2>/dev/null || true
if ! flock -n 9 2>/dev/null; then
  log "another startup run holds $LOCK_FILE — exiting"
  exit 0
fi

log "=== UPS graceful startup (DRY_RUN=$DRY_RUN VERIFY=$VERIFY) ==="
[[ -x "$GOVC" ]] || { fail_note "govc not executable at $GOVC"; alert_on_failure; exit 1; }
[[ -n "${ESXI_USER:-}" && -n "${ESXI_PASS:-}" ]] || {
  fail_note "ESXI_USER/ESXI_PASS not set (check $ENV_FILE)"; alert_on_failure; exit 1; }

build_inventory

if (( VERIFY )); then
  probe_privileges
  probe_gates
  probe_unlisted
fi

if ! gate_power; then
  log "refusing to start guests: power is not confirmed back"
  alert_on_failure
  exit 1
fi

storage_ok=1
gate_storage || storage_ok=0

for entry in $TIERS; do
  tier="${entry%%:*}"; vms="${entry#*:}"
  # Tier 0 is the control planes, on host-local storage: no NAS dependency.
  if [[ "$tier" != "0" ]] && (( ! storage_ok )); then
    fail_note "tier $tier skipped: storage never came up"
    continue
  fi
  # Workers want an API endpoint to register with.
  [[ "$tier" == "3" ]] && gate_api
  start_tier "$tier" "$vms"
  (( DRY_RUN )) || sleep "$TIER_DELAY"
done

if (( VERIFY )); then
  if [[ -z "$FAILURES" ]]; then
    log "VERIFY PASSED — every gate is satisfiable and every listed guest resolves"
    exit 0
  fi
  log "VERIFY FAILED:"; printf '%s' "$FAILURES" | while IFS= read -r l; do log "  $l"; done
  exit 1
fi

if [[ -n "$FAILURES" ]]; then
  log "=== startup finished WITH FAILURES ==="
  printf '%s' "$FAILURES" | while IFS= read -r l; do log "  $l"; done
  alert_on_failure
  exit 1
fi
log "=== startup complete, no failures ==="
exit 0
