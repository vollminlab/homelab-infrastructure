#!/usr/bin/env bash
# ups-graceful-shutdown.sh — orchestrate a clean lab power-down from TrueNAS.
#
# Runs ON TrueNAS, invoked as the UPS service's `shutdowncmd`. Because
# shutdowncmd REPLACES TrueNAS's default `/sbin/shutdown -P now`, this script is
# solely responsible for powering the NAS off — see poweroff_nas() and the
# hard deadline below.
#
# Why it exists: 18 of 22 VMs (including vCenter) live on TrueNAS iSCSI/NFS.
# With the stock config the NAS shuts down FIRST and then tells the UPS to cut
# the outlets feeding the hosts — storage vanishes under running guests, then
# they are hard-killed. This script inverts that: guests first, hosts second,
# NAS last.
#
# Control path is each ESXi host's OWN API, not vCenter. vCenter is itself a VM
# on the storage being torn down, and VCHA would try to fail over mid-sequence.
# Talking to the hosts directly removes both problems and still works when
# vCenter is already gone.
#
# Usage:
#   ups-graceful-shutdown.sh            # real run (as invoked by NUT)
#   DRY_RUN=1 ups-graceful-shutdown.sh  # enumerate and print the plan only
#   VERIFY=1  ups-graceful-shutdown.sh  # DRY_RUN plus a live probe for every
#                                       # action the real run would take;
#                                       # exits non-zero if any probe fails
#
# Config: ups-shutdown.env next to this script (0600, root) — see .example.
#
# NOTE ON THE POWEROFF FLAG: on TrueNAS SCALE /sbin/shutdown is systemd's
# compat interface, which accepts -P (poweroff) but NOT lowercase -p. NUT's
# upstream docs show the BSD-style `-p`; using it here made the final step fail
# with "invalid option -- 'p'" and exit 1, leaving the NAS running on battery
# after every guest and host had already been shut down cleanly. DRY_RUN could
# never catch it, because poweroff_nas() returns before reaching the command —
# which is why VERIFY mode exists and probes this flag for real.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/ups-shutdown.env}"
GOVC="${GOVC:-$SCRIPT_DIR/govc}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/ups-shutdown.log}"

# ── Defaults (override in the env file) ───────────────────────────────────────

# Hosts to shut down, "label=address" — each is driven independently.
ESXI_HOSTS_DEFAULT="esxi01=192.168.151.2 esxi02=192.168.151.3 esxi03=192.168.151.4"

# Seconds to wait for a host's guests to finish a Tools-initiated shutdown
# before forcing them off.
GUEST_TIMEOUT_DEFAULT=120

# Seconds to wait for an ESXi host to drop off the network after poweroff.
HOST_TIMEOUT_DEFAULT=60

# Hard ceiling on the whole orchestration. When it expires the NAS powers off
# regardless of what is still running. This bound is the single most important
# safety property here: a hung host or a bug must never leave the NAS up until
# the battery dies, because that ends in the exact uncontrolled power loss this
# script exists to prevent. It must fit inside the window the trigger leaves:
# firing at LOWBATT means battery.runtime.low (300 s) of projected runtime, so
# the whole sequence has to finish well inside that.
TOTAL_DEADLINE_DEFAULT=240

# How the NAS powers itself off. Overridable only so the test suite can stub it;
# it is deliberately NOT in the env file, and its value is logged on every run so
# a wrong one is visible in the log rather than discovered during an outage.
POWEROFF_CMD="${POWEROFF_CMD:-/sbin/shutdown -P now}"

DRY_RUN="${DRY_RUN:-0}"
# VERIFY implies DRY_RUN: it must never power anything off. What it adds is that
# every branch DRY_RUN merely *describes* also runs a read-only probe proving the
# real action would have worked.
VERIFY="${VERIFY:-0}"
(( VERIFY )) && DRY_RUN=1

# ── Logging ───────────────────────────────────────────────────────────────────

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  [[ -n "${LOG_FILE:-}" ]] && echo "$msg" >> "$LOG_FILE" 2>/dev/null
  return 0
}

die_but_poweroff() {
  log "FATAL: $*"
  poweroff_nas
}

# ── Setup ─────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR" 2>/dev/null

# A failed append is reported by the *shell* before the command runs, so the
# `2>/dev/null` inside log() never suppressed it: a non-root VERIFY run emitted a
# "Permission denied" line per log call and buried the actual output. Decide once,
# here, and fall back to stdout only.
if [[ -n "${LOG_FILE:-}" ]] && ! { : >> "$LOG_FILE"; } 2>/dev/null; then
  echo "WARNING: $LOG_FILE is not writable — logging to stdout only" >&2
  LOG_FILE=""
fi

# The env file uses plain assignments, so sourcing it would overwrite anything
# passed in the environment — an override for a test run would be silently
# discarded and the script would act on the real hosts instead. Snapshot the
# caller's values first and restore them afterwards, so precedence is
# environment > env file > defaults.
OVERRIDABLE=(ESXI_USER ESXI_PASS ESXI_HOSTS GUEST_TIMEOUT HOST_TIMEOUT TOTAL_DEADLINE)
declare -A _override
for _v in "${OVERRIDABLE[@]}"; do
  [[ -n "${!_v:-}" ]] && _override["$_v"]="${!_v}"
done

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  log "WARNING: $ENV_FILE not found — falling back to environment only"
fi

for _v in "${OVERRIDABLE[@]}"; do
  [[ -n "${_override[$_v]:-}" ]] && printf -v "$_v" '%s' "${_override[$_v]}"
done
unset _v

ESXI_HOSTS="${ESXI_HOSTS:-$ESXI_HOSTS_DEFAULT}"
GUEST_TIMEOUT="${GUEST_TIMEOUT:-$GUEST_TIMEOUT_DEFAULT}"
HOST_TIMEOUT="${HOST_TIMEOUT:-$HOST_TIMEOUT_DEFAULT}"
TOTAL_DEADLINE="${TOTAL_DEADLINE:-$TOTAL_DEADLINE_DEFAULT}"

START_EPOCH=$(date +%s)

deadline_remaining() {
  local elapsed=$(( $(date +%s) - START_EPOCH ))
  local left=$(( TOTAL_DEADLINE - elapsed ))
  (( left < 0 )) && left=0
  echo "$left"
}

# ── VERIFY probes ─────────────────────────────────────────────────────────────
#
# Each probe proves one real action would work, without performing it. The rule
# that matters: VERIFY must EXECUTE something for every line the real run
# executes. A rehearsal that only prints what it would do cannot catch a bad flag
# — which is exactly how `shutdown -p` survived five weeks of green dry runs.
#
# Background host jobs are subshells, so a counter cannot propagate. Each failure
# drops a file in VERIFY_DIR and the main shell tallies them at the end.

VERIFY_DIR=""
if (( VERIFY )); then
  VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ups-verify.XXXXXX")"
  trap 'rm -rf "$VERIFY_DIR"' EXIT
fi

probe_ok()   { log "  PROBE PASS  $*"; }
probe_fail() {
  log "  PROBE FAIL  $*"
  [[ -n "$VERIFY_DIR" ]] && echo "$*" >> "$VERIFY_DIR/failures"
  return 0
}

# Does the poweroff command's flag set actually parse? Substituting --show for
# the time argument makes systemd parse every flag and then only report pending
# state. Exit status is useless here (`-P --show` exits 1 with "No scheduled
# shutdown."), so the signal is the option-parsing error text.
probe_poweroff_cmd() {
  local bin out flags=()
  # shellcheck disable=SC2086
  set -- $POWEROFF_CMD
  bin=$1; shift
  local a
  for a in "$@"; do
    [[ "$a" == "now" || "$a" == "+0" ]] && continue
    flags+=("$a")
  done
  if [[ ! -x "$bin" ]]; then
    probe_fail "poweroff: $bin is not executable"
    return
  fi
  out=$("$bin" "${flags[@]}" --show 2>&1)
  if grep -qiE 'invalid option|unrecognized option|unknown option' <<< "$out"; then
    probe_fail "poweroff: '$bin ${flags[*]}' rejected by $bin — $out"
  else
    probe_ok "poweroff: '$POWEROFF_CMD' flags accepted by $bin"
  fi
}

# Can the configured principal actually power off guests and the host?
#
# This asks what the granted role *contains*, not what it is called. Asserting
# `role == Admin` was wrong in both directions: it fails a correct least-privilege
# role, and it would pass an "Admin" role that someone had edited to remove a
# privilege. Capability is the property that matters.
#
# ShutdownHost_Task requires Host.Config.Maintenance; ShutdownGuest and the forced
# power-off both require VirtualMachine.Interact.PowerOff.
REQUIRED_PRIVILEGES="${REQUIRED_PRIVILEGES:-Host.Config.Maintenance VirtualMachine.Interact.PowerOff}"

probe_host_privilege() {
  local label=$1 addr=$2 hostsys=$3 perms role privs missing=""
  perms=$(govc_host "$addr" permissions.ls "$hostsys" 2>/dev/null)
  if [[ -z "$perms" ]]; then
    probe_fail "[$label] privilege: could not read permissions on $hostsys"
    return
  fi
  role=$(awk -v u="$ESXI_USER" '$3==u {print $1}' <<< "$perms" | head -1)
  if [[ -z "$role" ]]; then
    probe_fail "[$label] privilege: principal '$ESXI_USER' has no permission entry"
    return
  fi
  # Admin holds every privilege by definition and does not enumerate usefully.
  if [[ "$role" == "Admin" ]]; then
    probe_ok "[$label] privilege: '$ESXI_USER' holds Admin (every privilege)"
    return
  fi
  privs=$(govc_host "$addr" role.ls "$role" 2>/dev/null)
  if [[ -z "$privs" ]]; then
    probe_fail "[$label] privilege: could not read the privileges of role '$role'"
    return
  fi
  local p
  for p in $REQUIRED_PRIVILEGES; do
    grep -qxF "$p" <<< "$privs" || missing="$missing $p"
  done
  if [[ -z "$missing" ]]; then
    probe_ok "[$label] privilege: role '$role' holds$(printf ' %s' $REQUIRED_PRIVILEGES)"
  else
    probe_fail "[$label] privilege: role '$role' is missing$missing"
  fi
}

# ── ESXi helpers ──────────────────────────────────────────────────────────────
#
# Every govc call is per-host: GOVC_URL points at the host's own SDK endpoint,
# so "/ha-datacenter/vm" is exactly that host's inventory. No vCenter involved.

govc_host() {
  local addr=$1; shift
  GOVC_URL="https://${addr}/sdk" \
  GOVC_USERNAME="$ESXI_USER" \
  GOVC_PASSWORD="$ESXI_PASS" \
  GOVC_INSECURE=1 \
  "$GOVC" "$@"
}

# Print "name<TAB>powerState<TAB>toolsRunningStatus" for every VM on a host.
list_vms() {
  local addr=$1
  local paths
  paths=$(govc_host "$addr" ls /ha-datacenter/vm 2>/dev/null)
  [[ -z "$paths" ]] && return 1
  # shellcheck disable=SC2046
  govc_host "$addr" vm.info -json $(echo "$paths" | tr '\n' ' ') 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for vm in d.get("virtualMachines") or []:
    print("\t".join([
        vm.get("name", "?"),
        (vm.get("runtime") or {}).get("powerState", "unknown"),
        (vm.get("guest") or {}).get("toolsRunningStatus", "unknown"),
    ]))
'
}

# Shut down every powered-on guest on one host, then power the host off.
# Runs as a background job — one per host — so the three proceed together.
shutdown_host() {
  local label=$1 addr=$2
  local vms on_count=0 tools_count=0

  vms=$(list_vms "$addr")
  if [[ -z "$vms" ]]; then
    log "[$label] could not enumerate VMs — skipping guest shutdown, powering host off anyway"
  else
    while IFS=$'\t' read -r name state tools; do
      [[ "$state" != "poweredOn" ]] && continue
      on_count=$((on_count + 1))
      if [[ "$tools" == "guestToolsRunning" ]]; then
        tools_count=$((tools_count + 1))
        if (( DRY_RUN )); then
          log "[$label] DRY-RUN would ShutdownGuest: $name"
          if (( VERIFY )); then
            # The real call addresses the guest by name; prove that name still
            # resolves on this host rather than trusting the enumeration that
            # produced it.
            govc_host "$addr" vm.info "$name" >/dev/null 2>&1 \
              && probe_ok "[$label] guest '$name' resolves" \
              || probe_fail "[$label] guest '$name' does not resolve"
          fi
        else
          log "[$label] ShutdownGuest: $name"
          govc_host "$addr" vm.power -s "$name" >/dev/null 2>&1 \
            || log "[$label] WARNING ShutdownGuest failed for $name"
        fi
      else
        # No Tools means no graceful path exists — a hard power-off is the only
        # option, and waiting the full guest timeout for it would be wasted.
        if (( DRY_RUN )); then
          log "[$label] DRY-RUN would power OFF (no Tools): $name"
        else
          log "[$label] power off (no Tools): $name"
          govc_host "$addr" vm.power -off "$name" >/dev/null 2>&1 \
            || log "[$label] WARNING power off failed for $name"
        fi
      fi
    done <<< "$vms"
    log "[$label] $on_count powered-on VMs ($tools_count via Tools)"
  fi

  # Poll until every guest is off or the guest timeout expires.
  local waited=0 still
  while (( waited < GUEST_TIMEOUT )); do
    if (( DRY_RUN )); then
      log "[$label] DRY-RUN would poll up to ${GUEST_TIMEOUT}s for guests to power off"
      break
    fi
    still=$(list_vms "$addr" | awk -F'\t' '$2=="poweredOn"' | wc -l)
    if (( still == 0 )); then
      log "[$label] all guests off after ${waited}s"
      break
    fi
    sleep 10
    waited=$((waited + 10))
  done

  # Anything left is forced off, so the host is never blocked by one stuck guest.
  if (( ! DRY_RUN )); then
    while IFS=$'\t' read -r name state _; do
      [[ "$state" == "poweredOn" ]] || continue
      log "[$label] timeout — forcing power off: $name"
      govc_host "$addr" vm.power -off -force "$name" >/dev/null 2>&1
    done <<< "$(list_vms "$addr")"
  fi

  # host.shutdown takes the HostSystem's inventory path, which differs per host
  # (/ha-datacenter/host/<fqdn>/<fqdn>), so discover it rather than hardcoding.
  local hostsys
  hostsys=$(govc_host "$addr" find / -type h 2>/dev/null | head -1)

  if (( DRY_RUN )); then
    log "[$label] DRY-RUN would power off host ${hostsys:-<lookup failed>}"
    if (( VERIFY )); then
      if [[ -n "$hostsys" ]]; then
        probe_ok "[$label] HostSystem path resolves ($hostsys)"
        probe_host_privilege "$label" "$addr" "$hostsys"
      else
        probe_fail "[$label] HostSystem path did not resolve"
      fi
      # The real run confirms the host is down by polling 443, so prove that
      # mechanism answers now, while the host is definitely up.
      if timeout 5 nc -z "$addr" 443 2>/dev/null; then
        probe_ok "[$label] reachable on 443 (host-down poll will work)"
      else
        probe_fail "[$label] not reachable on 443 — host-down poll cannot work"
      fi
    fi
    return 0
  fi

  if [[ -z "$hostsys" ]]; then
    log "[$label] ERROR could not resolve HostSystem path — host left running"
    return 1
  fi

  log "[$label] powering off host ($hostsys)"
  govc_host "$addr" host.shutdown -f "$hostsys" >/dev/null 2>&1 \
    || log "[$label] WARNING host.shutdown returned non-zero"

  # Confirm it actually went down rather than assuming the call took effect —
  # a host still answering means its poweroff did not happen.
  local hw=0
  while (( hw < HOST_TIMEOUT )); do
    if ! timeout 5 nc -z "$addr" 443 2>/dev/null; then
      log "[$label] host down after ${hw}s"
      return 0
    fi
    sleep 5
    hw=$((hw + 5))
  done
  log "[$label] WARNING host still answering after ${HOST_TIMEOUT}s"
}

# ── NAS ───────────────────────────────────────────────────────────────────────

poweroff_nas() {
  local elapsed=$(( $(date +%s) - START_EPOCH ))
  if (( VERIFY )); then
    local failures=0
    [[ -s "$VERIFY_DIR/failures" ]] && failures=$(wc -l < "$VERIFY_DIR/failures")
    if (( failures == 0 )); then
      log "VERIFY PASSED after ${elapsed}s — every probed step would work"
      exit 0
    fi
    log "VERIFY FAILED after ${elapsed}s — $failures probe(s) failed:"
    while IFS= read -r line; do log "  - $line"; done < "$VERIFY_DIR/failures"
    exit 1
  fi
  if (( DRY_RUN )); then
    log "DRY-RUN complete after ${elapsed}s — would now power off the NAS"
    exit 0
  fi
  log "powering off the NAS after ${elapsed}s using: $POWEROFF_CMD"
  local rc=0
  # shellcheck disable=SC2086
  $POWEROFF_CMD || rc=$?
  if (( rc != 0 )); then
    # Never exit 0 on a failed poweroff. The NAS staying up on battery with the
    # pools imported is the one uncontrolled loss this script exists to prevent,
    # so say so loudly and try the direct systemd path before giving up.
    log "FATAL: '$POWEROFF_CMD' failed (rc=$rc) — falling back to systemctl"
    if systemctl --force poweroff; then
      exit 0
    fi
    log "FATAL: fallback 'systemctl --force poweroff' also failed — NAS IS STILL RUNNING"
    exit 1
  fi
  exit 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "=== UPS graceful shutdown starting (DRY_RUN=$DRY_RUN, VERIFY=$VERIFY, deadline=${TOTAL_DEADLINE}s) ==="
log "poweroff command: $POWEROFF_CMD"

# Probe this first: it is the last thing the real run does and the only step with
# no in-cluster consequence, so there is no reason to learn about it last.
(( VERIFY )) && probe_poweroff_cmd

if [[ ! -x "$GOVC" ]]; then
  die_but_poweroff "govc not executable at $GOVC"
fi
if [[ -z "${ESXI_USER:-}" || -z "${ESXI_PASS:-}" ]]; then
  die_but_poweroff "ESXI_USER/ESXI_PASS not set (check $ENV_FILE)"
fi

pids=()
for entry in $ESXI_HOSTS; do
  label="${entry%%=*}"
  addr="${entry##*=}"
  log "[$label] starting ($addr)"
  shutdown_host "$label" "$addr" &
  pids+=($!)
done

# Wait for all three hosts, but never past the hard deadline.
#
# The background jobs are children of THIS shell, so they must be polled here.
# Delegating the wait to a subshell does not work — `wait` only accepts the
# calling shell's own children, so the subshell returns immediately and the NAS
# powers off seconds into the run, while guests are still shutting down. That is
# precisely the failure this script exists to prevent, so it is polled directly.
log "waiting up to $(deadline_remaining)s for hosts to finish"

while :; do
  running=0
  for p in "${pids[@]}"; do
    kill -0 "$p" 2>/dev/null && running=$((running + 1))
  done

  if (( running == 0 )); then
    log "all hosts finished"
    break
  fi

  if (( $(deadline_remaining) == 0 )); then
    log "DEADLINE reached with $running host job(s) still working — powering off the NAS anyway"
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
    break
  fi

  sleep 5
done

poweroff_nas
