#!/usr/bin/env bash
# Tests for ups-graceful-startup.sh. Every dependency stubbed: no hosts, no UPS,
# no pools, no network. Run: bash ups-graceful-startup_test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/ups-graceful-startup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (wanted '$3')"; fi; }
absent() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 ('$3' should be absent)"; fi; }

setup() {
  S="$(mktemp -d)"; CALLS="$S/calls"; : > "$CALLS"

  # govc stub. Inventory is driven by STUB_VMS: "name:state:template,..."
  cat > "$S/govc" <<'STUB'
#!/usr/bin/env bash
echo "govc $*" >> "$CALLS"
vms="${STUB_VMS:-a1:poweredOff:vm}"
case "$*" in
  *"ls /ha-datacenter/vm"*)
      IFS=, read -ra list <<< "$vms"
      for e in "${list[@]}"; do echo "/ha-datacenter/vm/${e%%:*}"; done ;;
  *"vm.info -json"*)
      printf '{"virtualMachines":['
      IFS=, read -ra list <<< "$vms"; first=1
      for e in "${list[@]}"; do
        n="${e%%:*}"; rest="${e#*:}"; st="${rest%%:*}"; tm="${rest##*:}"
        [[ $first == 1 ]] || printf ','
        first=0
        printf '{"name":"%s","runtime":{"powerState":"%s"},"config":{"template":%s},"guest":{"toolsRunningStatus":"%s"}}' \
          "$n" "$st" "$([[ $tm == template ]] && echo true || echo false)" "${STUB_TOOLS:-guestToolsRunning}"
      done
      printf ']}' ;;
  *"find / -type h"*) echo "/ha-datacenter/host/stub/stub" ;;
  *permissions.ls*)   printf 'Role   Entity  Principal  Propagate\n%s  /   ups-shutdown  Yes\n' "${STUB_ROLE:-ups-shutdown}" ;;
  *role.ls*)          printf '%s\n' ${STUB_PRIVS-VirtualMachine.Interact.PowerOn VirtualMachine.Interact.PowerOff Host.Config.Maintenance} ;;
  *"vm.power -on"*)   exit ${STUB_POWERON_RC:-0} ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\necho "upsc $*" >> "%s"\ncase "$2" in ups.status) echo "${STUB_UPS_STATUS-OL}";; battery.charge) echo "${STUB_CHARGE-100}";; esac\nexit 0\n' "$CALLS" > "$S/upsc"
  printf '#!/usr/bin/env bash\necho "${STUB_POOL_HEALTH-ONLINE}"\n' > "$S/zpool"
  printf '#!/usr/bin/env bash\necho "${STUB_SS-LISTEN 0 0 *:3260 *:*}"\n' > "$S/ss"
  printf '#!/usr/bin/env bash\necho "nc $*" >> "%s"\nexit ${STUB_NC_RC:-0}\n' "$CALLS" > "$S/nc"
  # The curl stub doubles as the AMT endpoint: it reads the SOAP body from stdin
  # and answers either a power state or a RequestPowerStateChange result.
  cat > "$S/curl" <<'STUB'
#!/usr/bin/env bash
# Only the AMT calls pipe a body in. The Pushover alert path passes -F flags and no
# stdin, so reading stdin unconditionally hangs the whole suite waiting on a pipe
# that will never close.
case "$*" in *--data-binary*) body=$(cat) ;; *) body="" ;; esac
echo "curl $*" >> "$CALLS"
case "$body" in
  *RequestPowerStateChange_INPUT*)
      echo "amt-power-on-issued" >> "$CALLS"
      echo "requested-state=$(sed -n 's/.*<p:PowerState>\([0-9]*\)<.*/\1/p' <<< "$body")" >> "$CALLS"
      if [[ "${STUB_AMT_ACCEPT:-1}" == 1 ]]; then echo "<g:ReturnValue>0</g:ReturnValue>"; else echo "<g:ReturnValue>2</g:ReturnValue>"; fi ;;
  *CIM_AssociatedPowerManagementService*)
      echo "<g:PowerState>${STUB_AMT_STATE-8}</g:PowerState>" ;;
esac
exit 0
STUB
  chmod +x "$S/curl"
  printf 'AMT_USER=admin\nAMT_PASS=stub\n' > "$S/amt.env"; chmod 600 "$S/amt.env"
  chmod +x "$S"/{govc,upsc,zpool,ss,nc}
  mkdir -p "$S/nfs"
  printf 'ESXI_USER=ups-shutdown\nESXI_PASS=stub\nESXI_HOSTS="h1=203.0.113.9"\n' > "$S/env"
  printf 'PUSHOVER_TOKEN=t\nPUSHOVER_USER=u\n' > "$S/pushover.env"
}
teardown() { rm -rf "$S"; }

run() {
  env CALLS="$CALLS" ENV_FILE="$S/env" GOVC="$S/govc" \
      LOG_DIR="$S/logs" LOG_FILE="$S/logs/startup.log" \
      PUSHOVER_ENV="$S/pushover.env" LOCK_FILE="$S/logs/.lock" \
      UPSC="$S/upsc" ZPOOL="$S/zpool" SS="$S/ss" NC="$S/nc" CURL="$S/curl" \
      AMT_ENV="$S/amt.env" AMT_HOSTS="h1=198.51.100.9" AMT_WAIT=0 \
      NFS_EXPORT="$S/nfs" ZPOOLS="pool_0" TIER_DELAY=0 \
      UPS_WAIT=0 STORAGE_WAIT=0 HOST_WAIT=0 API_WAIT=0 TIER_WAIT=0 \
      "$@" bash "$SCRIPT" 2>&1
}

echo "== a normal recovery starts every tier, in order =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm,vcenter:poweredOff:vm,haproxy01:poweredOff:vm" \
          TIERS="0:k8scp01 1:vcenter 2:haproxy01")
check "power gate passes"      "$out" "power gate: OK"
check "storage gate passes"    "$out" "storage gate: OK"
check "tier 0 runs first"      "$out" "=== tier 0"
check "k8scp01 powered on"     "$out" "[k8scp01] powering on"
check "vcenter powered on"     "$out" "[vcenter] powering on"
check "completes cleanly"      "$out" "startup complete, no failures"
o01=$(grep -n 'tier 0' <<< "$out" | head -1 | cut -d: -f1)
o02=$(grep -n 'tier 2' <<< "$out" | head -1 | cut -d: -f1)
if [[ -n "$o01" && -n "$o02" ]] && (( o01 < o02 )); then ok "tier order is 0 before 2"; else bad "tier order wrong"; fi
teardown

echo "== already-on guests are skipped (idempotent) =="
setup
out=$(run STUB_VMS="k8scp01:poweredOn:vm" TIERS="0:k8scp01")
check "skip is explicit" "$out" "already powered on — skipping"
absent "no power-on issued" "$(cat "$CALLS")" "vm.power -on"
teardown

echo "== templates and vCLS are never started =="
setup
out=$(run STUB_VMS="ubuntu-template:poweredOff:template,vCLS-abc:poweredOff:vm" \
          TIERS="0:ubuntu-template,vCLS-abc")
check "vCLS refused by name"  "$out" "vCLS-abc] skipped — on the never-start list"
check "template refused"      "$out" "ubuntu-template] skipped"
absent "nothing powered on"   "$(cat "$CALLS")" "vm.power -on"
teardown

echo "== a flapping utility must not start anything =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_UPS_STATUS="OB DISCHRG" STUB_CHARGE=20); rc=$?
check "power gate refuses"   "$out" "power gate: still not satisfied"
check "says why it stopped"  "$out" "refusing to start guests"
absent "nothing powered on"  "$(cat "$CALLS")" "vm.power -on"
if (( rc != 0 )); then ok "exit non-zero ($rc)"; else bad "exit was 0"; fi
check "alert sent"           "$(cat "$CALLS")" "curl"
teardown

echo "== charge below threshold is refused even when OL =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_CHARGE=10 UPS_MIN_CHARGE=50)
check "threshold enforced" "$out" "power gate: still not satisfied"
teardown

echo "== an unreadable UPS proceeds by default, refuses when told to =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_UPS_STATUS="")
check "proceeds with a warning" "$out" "proceeding anyway"
check "still starts the tier"   "$out" "[k8scp01] powering on"
teardown
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_UPS_STATUS="" UPS_GATE_REQUIRED=1)
check "fail-closed honoured" "$out" "UPS_GATE_REQUIRED=1"
absent "nothing powered on"  "$(cat "$CALLS")" "vm.power -on"
teardown

echo "== tier 0 starts without storage; later tiers do not =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm,vcenter:poweredOff:vm" TIERS="0:k8scp01 1:vcenter" \
          STUB_POOL_HEALTH="DEGRADED")
check "storage gate fails"        "$out" "storage gate: not serving"
check "tier 0 still starts"       "$out" "[k8scp01] powering on"
check "tier 1 is skipped"         "$out" "tier 1 skipped: storage never came up"
absent "vcenter not started"      "$out" "[vcenter] powering on"
teardown

echo "== a host that never comes back does not strand the others =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_NC_RC=1)
check "host gate reported"    "$out" "never answered on 443"
check "inventory says why"    "$out" "its guests cannot be enumerated"
check "guest reported, not silently dropped" "$out" "is in no host's inventory"
check "count of live hosts logged"           "$out" "hosts up: 0 of 1"
teardown

echo "== a failed power-on is reported, not swallowed =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_POWERON_RC=1); rc=$?
check "failure recorded" "$out" "power-on failed for 'k8scp01'"
check "run marked failed" "$out" "finished WITH FAILURES"
if (( rc != 0 )); then ok "exit non-zero ($rc)"; else bad "exit was 0"; fi
teardown

echo "== VERIFY probes without starting anything =="
setup
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01")
check "privilege probed"   "$out" "holds VirtualMachine.Interact.PowerOn"
check "power gate probed"  "$out" "power gate readable"
check "pools probed"       "$out" "pools ONLINE"
check "iSCSI probed"       "$out" "iSCSI 3260 listening"
check "api probed"         "$out" "api gate:"
check "verdict passed"     "$out" "VERIFY PASSED"
absent "never powers on"   "$(cat "$CALLS")" "vm.power -on"
teardown

echo "== VERIFY fails when the role cannot power anything on =="
setup
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" \
          STUB_PRIVS="VirtualMachine.Interact.PowerOff Host.Config.Maintenance"); rc=$?
check "missing privilege named" "$out" "lacks VirtualMachine.Interact.PowerOn"
check "verdict failed"          "$out" "VERIFY FAILED"
if (( rc != 0 )); then ok "exit non-zero ($rc)"; else bad "exit was 0"; fi
teardown

echo "== VERIFY names guests that no tier would ever start =="
setup
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm,forgotten01:poweredOff:vm" TIERS="0:k8scp01")
check "orphan named" "$out" "never started: forgotten01"
teardown

echo "== RESCAN_STORAGE=1 without the privilege is caught =="
setup
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" RESCAN_STORAGE=1 \
          STUB_PRIVS="VirtualMachine.Interact.PowerOn")
check "missing rescan privilege" "$out" "lacks Host.Config.Storage"
teardown

echo "== environment beats the env file =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" ESXI_HOSTS="fromenv=203.0.113.9")
check "env host used" "$out" "[fromenv]"
absent "file host ignored" "$out" "[h1]"
teardown

echo "== AMT fallback: a powered-off host gets powered on =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_NC_RC=1 AMT_FALLBACK=1 STUB_AMT_STATE=8)
check "reads the AMT power state" "$out" "reports PowerState=8"
check "issues the power-on"       "$out" "AMT accepted the power-on"
check "power-on was sent"         "$(cat "$CALLS")" "amt-power-on-issued"
check "and ONLY ever state 2"     "$(cat "$CALLS")" "requested-state=2"
absent "never a reset value"      "$(cat "$CALLS")" "requested-state=5"
teardown

echo "== AMT refuses to touch a host that is already on =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_NC_RC=1 AMT_FALLBACK=1 STUB_AMT_STATE=2)
check "explains why it declines" "$out" "not touching it"
absent "no power-on issued"      "$(cat "$CALLS")" "amt-power-on-issued"
teardown

echo "== AMT is tried at most once per host per run =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm,k8scp02:poweredOff:vm" TIERS="0:k8scp01,k8scp02" STUB_NC_RC=1 AMT_FALLBACK=1 STUB_AMT_STATE=8)
n=$(grep -c 'amt-power-on-issued' "$CALLS")
if (( n == 1 )); then ok "one power-on for one host"; else bad "issued $n power-ons"; fi
teardown

echo "== with the fallback off, AMT is never contacted =="
setup
out=$(run STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" STUB_NC_RC=1 AMT_FALLBACK=0)
absent "no AMT traffic" "$(cat "$CALLS")" "16993"
teardown

echo "== VERIFY probes AMT, and catches a loose or missing creds file =="
setup
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" AMT_FALLBACK=1)
check "AMT probed"   "$out" "reachable and authenticated"
check "mode checked" "$out" "AMT credentials file mode 600"
teardown
setup
chmod 644 "$S/amt.env"
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" AMT_FALLBACK=1)
check "loose mode caught" "$out" "must be 600"
teardown
setup
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01" AMT_FALLBACK=1 AMT_ENV="$S/nope")
check "missing creds caught" "$out" "is not readable"
check "verdict failed"       "$out" "VERIFY FAILED"
teardown

echo "== AMT disabled is reported, not silently skipped =="
setup
out=$(run VERIFY=1 STUB_VMS="k8scp01:poweredOff:vm" TIERS="0:k8scp01")
check "says it is disabled" "$out" "AMT fallback disabled"
teardown

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
