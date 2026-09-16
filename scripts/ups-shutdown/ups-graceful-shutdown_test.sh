#!/usr/bin/env bash
# Tests for ups-graceful-shutdown.sh. Pure shell stubs, no cluster, no UPS.
#
# Run: bash ups-graceful-shutdown_test.sh
#
# These exist because of one defect class: the script's terminal actions
# (`shutdown`, `vm.power`, `host.shutdown`) are exactly the lines DRY_RUN skips,
# so they were the only lines never exercised — and one of them, `shutdown -p`,
# was wrong for five weeks while every dry run reported success. Every test here
# either executes a real parse/probe or asserts the destructive verbs are absent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/ups-graceful-shutdown.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check(){ if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (looked for '$3')"; fi; }
absent(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 ('$3' should not appear)"; fi; }

# A sandbox per test: fake govc, fake poweroff, an env file, and a call log.
setup() {
  SANDBOX="$(mktemp -d)"
  CALLS="$SANDBOX/calls"
  : > "$CALLS"

  cat > "$SANDBOX/govc" <<'STUB'
#!/usr/bin/env bash
echo "govc $*" >> "$CALLS"
case "$*" in
  *"ls /ha-datacenter/vm"*) echo "/ha-datacenter/vm/testvm" ;;
  *"vm.info -json"*) cat <<'JSON'
{"virtualMachines":[{"name":"testvm","runtime":{"powerState":"poweredOn"},"guest":{"toolsRunningStatus":"guestToolsRunning"}}]}
JSON
    ;;
  *"vm.info testvm"*) echo "Name: testvm" ;;
  *"find / -type h"*) echo "/ha-datacenter/host/esxi-test/esxi-test" ;;
  *permissions.ls*) printf 'Role   Entity  Principal  Propagate\n%s  /       root       Yes\n' "${STUB_ROLE:-Admin}" ;;
  *role.ls*) printf '%s\n' ${STUB_ROLE_PRIVS-Host.Config.Maintenance VirtualMachine.Interact.PowerOff System.View} ;;
esac
exit 0
STUB
  chmod +x "$SANDBOX/govc"

  cat > "$SANDBOX/poweroff-stub" <<'STUB'
#!/usr/bin/env bash
echo "poweroff-stub $*" >> "$CALLS"
# Mimic systemd's compat shutdown: -P is accepted, lowercase -p is not.
for a in "$@"; do
  case "$a" in
    -p) echo "poweroff-stub: invalid option -- 'p'" >&2; exit 1 ;;
  esac
done
[[ "$*" == *--show* ]] && { echo "No scheduled shutdown."; exit 1; }
exit 0
STUB
  chmod +x "$SANDBOX/poweroff-stub"

  # The host-down poll uses nc; stub it so the happy path is reachable without a
  # real host. TEST-NET addresses are unroutable by design.
  cat > "$SANDBOX/nc" <<'STUB'
#!/usr/bin/env bash
echo "nc $*" >> "$CALLS"
exit ${NC_EXIT:-0}
STUB
  chmod +x "$SANDBOX/nc"

  cat > "$SANDBOX/ups-shutdown.env" <<'ENV'
ESXI_USER=root
ESXI_PASS=stub
ESXI_HOSTS="fromfile=203.0.113.9"
GUEST_TIMEOUT=1
HOST_TIMEOUT=1
TOTAL_DEADLINE=30
ENV
}
teardown() { rm -rf "$SANDBOX"; }

run() {  # run the script in the sandbox; args are extra env assignments
  env CALLS="$CALLS" \
      ENV_FILE="$SANDBOX/ups-shutdown.env" \
      GOVC="$SANDBOX/govc" \
      LOG_DIR="$SANDBOX/logs" \
      LOG_FILE="$SANDBOX/logs/test.log" \
      POWEROFF_CMD="$SANDBOX/poweroff-stub -P now" \
      PATH="$SANDBOX:$PATH" \
      "$@" bash "$SCRIPT" 2>&1
}

echo "== the poweroff flag =="
# The regression test for the five-week bug. Static, so it holds even where
# /sbin/shutdown does not exist (CI containers).
src="$(cat "$SCRIPT")"
absent "script never calls shutdown with lowercase -p" "$src" 'shutdown -p now'
check  "script's default poweroff uses -P" "$src" '/sbin/shutdown -P now'

# And the live version of the same assertion, where a real systemd is present.
if [[ -x /sbin/shutdown ]]; then
  out=$(/sbin/shutdown -P --show 2>&1); 
  if grep -qiE 'invalid option|unrecognized option' <<< "$out"; then
    bad "local /sbin/shutdown rejects -P"
  else
    ok "local /sbin/shutdown accepts -P"
  fi
  out=$(/sbin/shutdown -p --show 2>&1)
  if grep -qiE 'invalid option|unrecognized option' <<< "$out"; then
    ok "local /sbin/shutdown rejects -p (the bug was real)"
  else
    ok "local /sbin/shutdown tolerates -p (not systemd compat — fine)"
  fi
else
  echo "  skip — no /sbin/shutdown on this machine"
fi

echo "== VERIFY mode =="
setup
out=$(run VERIFY=1 ESXI_HOSTS="h1=203.0.113.9")
check  "reports the mode"                "$out" "VERIFY=1"
check  "probes the poweroff command"     "$out" "PROBE PASS  poweroff:"
check  "probes guest name resolution"    "$out" "guest 'testvm' resolves"
check  "probes the HostSystem path"      "$out" "HostSystem path resolves"
check  "probes the granted role"         "$out" "holds Admin"
check  "probes host reachability"        "$out" "host-down poll will work"
check  "verdict is PASSED"               "$out" "VERIFY PASSED"
calls="$(cat "$CALLS")"
absent "VERIFY never powers a guest off" "$calls" "vm.power"
absent "VERIFY never shuts a host down"  "$calls" "host.shutdown"
absent "VERIFY never powers off the NAS" "$calls" "poweroff-stub -P now"
teardown

echo "== VERIFY catches an unreachable host =="
setup
out=$(run VERIFY=1 ESXI_HOSTS="h1=203.0.113.9" NC_EXIT=1)
check "unreachable host is reported" "$out" "host-down poll cannot work"
check "verdict is FAILED"            "$out" "VERIFY FAILED"
teardown

echo "== privilege is judged by capability, not by role name =="
setup
# A least-privilege custom role that holds what the orchestrator needs must pass.
out=$(run VERIFY=1 ESXI_HOSTS="h1=203.0.113.9" STUB_ROLE=ups-shutdown)
check "custom role accepted"  "$out" "role 'ups-shutdown' holds"
check "verdict is PASSED"     "$out" "VERIFY PASSED"
teardown

setup
# ...and a role missing one of them must fail, however it is named.
out=$(run VERIFY=1 ESXI_HOSTS="h1=203.0.113.9" STUB_ROLE=ups-shutdown \
          STUB_ROLE_PRIVS="System.View VirtualMachine.Interact.PowerOff"); rc=$?
check "missing privilege named"  "$out" "missing Host.Config.Maintenance"
check "verdict is FAILED"        "$out" "VERIFY FAILED"
if (( rc != 0 )); then ok "exit status is non-zero ($rc)"; else bad "exit status was 0"; fi
teardown

setup
# Admin holds everything by definition and must still pass without enumerating.
out=$(run VERIFY=1 ESXI_HOSTS="h1=203.0.113.9" STUB_ROLE=Admin)
check "Admin still accepted" "$out" "holds Admin (every privilege)"
teardown

echo "== VERIFY fails loudly when a probe fails =="
setup
# A poweroff command whose flag the stub rejects must fail the run, not pass it.
out=$(run VERIFY=1 ESXI_HOSTS="h1=203.0.113.9" POWEROFF_CMD="$SANDBOX/poweroff-stub -p now"); rc=$?
check "bad flag is reported"   "$out" "PROBE FAIL  poweroff:"
check "verdict is FAILED"      "$out" "VERIFY FAILED"
if (( rc != 0 )); then ok "exit status is non-zero ($rc)"; else bad "exit status was 0"; fi
teardown

echo "== environment beats the env file (regression, PR #26) =="
setup
out=$(run DRY_RUN=1 ESXI_HOSTS="fromenv=203.0.113.9")
check  "uses the env value"   "$out" "[fromenv] starting"
absent "ignores the file value" "$out" "fromfile"
teardown

echo "== the hard deadline still powers the NAS off =="
setup
# 203.0.113.0/24 is TEST-NET-3: connections hang, so the host jobs cannot finish.
out=$(run ESXI_HOSTS="blackhole=203.0.113.9" TOTAL_DEADLINE=10 GUEST_TIMEOUT=60 HOST_TIMEOUT=60)
check "deadline fires"              "$out" "DEADLINE reached"
check "NAS poweroff is attempted"   "$out" "powering off the NAS"
check "the command used is logged"   "$out" "poweroff-stub -P now"
check "poweroff actually ran"       "$(cat "$CALLS")" "poweroff-stub -P now"
teardown

echo "== a failed poweroff is never silent =="
setup
out=$(run ESXI_HOSTS="h1=203.0.113.9" TOTAL_DEADLINE=10 POWEROFF_CMD="$SANDBOX/poweroff-stub -p now"); rc=$?
check "failure is logged as FATAL" "$out" "FATAL"
if (( rc != 0 )); then ok "exit status is non-zero ($rc)"; else bad "exit status was 0 after a failed poweroff"; fi
teardown

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
