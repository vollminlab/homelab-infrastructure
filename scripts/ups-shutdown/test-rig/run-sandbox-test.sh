#!/usr/bin/env bash
# run-sandbox-test.sh — drive the real orchestrator from a real upsmon, using a
# simulated UPS, without touching anything that matters.
#
# WHAT THIS COVERS THAT NOTHING ELSE DOES
#
# VERIFY=1 proves the orchestrator would do the right thing *if it were called*.
# The preflight proves the configuration still points at it. Neither exercises
# the link between them: upsmon's own decision that the UPS is critical, and the
# hand-off from that decision to SHUTDOWNCMD. That link is upstream C code plus a
# generated config, it runs exactly once in the life of a power event, and on
# this cluster it had never run at all.
#
# So: a `dummy-ups` driver replays OL -> OB -> OB LB into a private NUT stack on
# an alternate port, a private upsmon watches it, and its SHUTDOWNCMD is a probe
# that records how it was called and then runs the real orchestrator against
# stubs. Nothing real is contacted and nothing is powered off.
#
# ISOLATION — every one of these matters:
#   * NUT_CONFPATH points at a temp dir, so /etc/nut is never read or written.
#   * NUT_STATEPATH is a short private dir (the socket path has a 108-char limit).
#   * upsd listens on 127.0.0.1:3494, not the default 3493.
#   * The binaries are called at /lib/nut/*, bypassing the Debian /sbin wrappers
#     that refuse to start unless MODE is set in the SYSTEM nut.conf.
#   * The orchestrator runs with a stub govc, TEST-NET hosts and a stub poweroff.
#
# Usage:  sudo ./run-sandbox-test.sh          (needs root: upsmon runs as root)
#         sudo KEEP=1 ./run-sandbox-test.sh   (leave the sandbox for inspection)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR="${ORCHESTRATOR:-$(cd "$HERE/.." && pwd)/ups-graceful-shutdown.sh}"
NUT_LIB="${NUT_LIB:-/lib/nut}"
WAIT_SECONDS="${WAIT_SECONDS:-45}"
KEEP="${KEEP:-0}"

# The PATH the NAS's upsmon actually hands its SHUTDOWNCMD — deliberately not
# this machine's. It has no /sbin, which is why the orchestrator calls
# /sbin/shutdown by absolute path. Testing under a richer PATH would hide that.
NAS_PATH="${NAS_PATH:-/usr/local/bin:/usr/bin:/bin:/usr/games}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

(( EUID == 0 )) || { echo "must run as root (upsmon needs it to invoke SHUTDOWNCMD)"; exit 2; }
for b in dummy-ups upsd upsmon; do
  [[ -x "$NUT_LIB/$b" ]] || { echo "missing $NUT_LIB/$b — apt install nut-server nut-client"; exit 2; }
done
[[ -x "$ORCHESTRATOR" ]] || { echo "orchestrator not executable at $ORCHESTRATOR"; exit 2; }

CONF="$(mktemp -d)"                 # config: path length does not matter
STATE="$(mktemp -d /tmp/nutrig.XXXXXX)"   # sockets live here: MUST stay short
cleanup() {
  pkill -f "$NUT_LIB/upsmon" 2>/dev/null
  pkill -f "$NUT_LIB/upsd" 2>/dev/null
  pkill -f "$NUT_LIB/dummy-ups" 2>/dev/null
  sleep 1
  if (( KEEP )); then echo "sandbox kept at $CONF and $STATE"
  else rm -rf "$CONF" "$STATE"; fi
}
trap cleanup EXIT

# ── the simulated UPS ─────────────────────────────────────────────────────────
cat > "$CONF/nut.conf" <<< "MODE=standalone"
cat > "$CONF/ups.conf" <<EOF
[test]
	driver = dummy-ups
	port = $CONF/outage.dev
	mode = dummy-loop
	desc = "sandbox"
EOF
# The outage, compressed. upsmon declares a UPS critical only when OB and LB are
# set together, so the sequence has to pass through OB alone first — a UPS that
# reports LB while still OL is exactly the bad-telemetry case TrueNAS guards
# against, and it must NOT trigger anything.
cat > "$CONF/outage.dev" <<'EOF'
ups.mfr: sandbox
ups.model: dummy
battery.charge: 100
ups.status: OL
TIMER 5
ups.status: OL LB
TIMER 5
ups.status: OB
battery.charge: 40
TIMER 5
ups.status: OB LB
battery.charge: 9
TIMER 300
EOF
echo "LISTEN 127.0.0.1 3494" > "$CONF/upsd.conf"
printf '[rigmon]\n\tpassword = rigpass\n\tupsmon primary\n' > "$CONF/upsd.users"
chmod 640 "$CONF/upsd.users"

# ── stubs the orchestrator will meet ──────────────────────────────────────────
cat > "$CONF/govc" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ls /ha-datacenter/vm"*) echo "/ha-datacenter/vm/sandboxvm" ;;
  *"vm.info -json"*) echo '{"virtualMachines":[{"name":"sandboxvm","runtime":{"powerState":"poweredOn"},"guest":{"toolsRunningStatus":"guestToolsRunning"}}]}' ;;
  *"find / -type h"*) echo "/ha-datacenter/host/sandbox/sandbox" ;;
esac
exit 0
STUB
chmod +x "$CONF/govc"
printf '#!/usr/bin/env bash\necho "$*" > %s/poweroff-called\nexit 0\n' "$CONF" > "$CONF/poweroff-stub"
chmod +x "$CONF/poweroff-stub"
printf 'ESXI_USER=sandbox\nESXI_PASS=sandbox\n' > "$CONF/orchestrator.env"
chmod 600 "$CONF/orchestrator.env"

# ── the SHUTDOWNCMD upsmon will call ──────────────────────────────────────────
# Records how upsmon called it, then runs the REAL orchestrator under the NAS's
# environment. `env -i` is the point: it reproduces the bare environment upsmon
# provides rather than inheriting this shell's.
cat > "$CONF/shutdowncmd-probe.sh" <<EOF
#!/usr/bin/env bash
{
  echo "uid=\$(id -u)"
  echo "killpower_flag=\$([ -f "$CONF/killpower" ] && echo present || echo absent)"
} > "$CONF/invoked"
# Deliberately NOT DRY_RUN: dry run returns before the poweroff line, which is
# the line this whole rig exists to see executed. Safety comes from the stubs —
# a fake govc, TEST-NET hosts and a poweroff command that only writes a file.
env -i PATH="$NAS_PATH" HOME=/root \\
  GOVC="$CONF/govc" \\
  ENV_FILE="$CONF/orchestrator.env" \\
  LOG_DIR="$CONF/logs" LOG_FILE="$CONF/logs/orchestrator.log" \\
  POWEROFF_CMD="$CONF/poweroff-stub -P now" \\
  ESXI_HOSTS="sandbox=203.0.113.9" GUEST_TIMEOUT=2 HOST_TIMEOUT=2 TOTAL_DEADLINE=20 \\
  "$ORCHESTRATOR" > "$CONF/orchestrator.out" 2>&1
echo "orchestrator_rc=\$?" >> "$CONF/invoked"
touch "$CONF/done"
EOF
chmod +x "$CONF/shutdowncmd-probe.sh"

cat > "$CONF/upsmon.conf" <<EOF
MONITOR test@127.0.0.1:3494 1 rigmon rigpass primary
SHUTDOWNCMD "$CONF/shutdowncmd-probe.sh"
POWERDOWNFLAG $CONF/killpower
FINALDELAY 0
POLLFREQ 1
POLLFREQALERT 1
EOF
chmod 640 "$CONF/upsmon.conf"

# ── run it ────────────────────────────────────────────────────────────────────
export NUT_CONFPATH="$CONF" NUT_STATEPATH="$STATE"
echo "== starting the sandbox NUT stack =="
"$NUT_LIB/dummy-ups" -a test -u root >/dev/null 2>&1
sleep 2
"$NUT_LIB/upsd" -u root >/dev/null 2>&1
sleep 2
"$NUT_LIB/upsmon" -u root >/dev/null 2>&1

echo "== replaying OL -> OL LB -> OB -> OB LB =="
# Wait for the orchestrator to FINISH, not merely to be invoked. `invoked` is
# written on entry and `done` on exit; asserting on the first is a race that
# reads a half-finished run as a failure.
saw_early_trigger=0
waited=0
invoked_at=""
while (( waited < WAIT_SECONDS )); do
  st=$(upsc test@127.0.0.1:3494 ups.status 2>/dev/null)
  # An invocation while the UPS is still OL would mean upsmon acts on LB alone.
  if [[ -f "$CONF/invoked" && "$st" != *OB* ]]; then saw_early_trigger=1; fi
  [[ -f "$CONF/invoked" && -z "$invoked_at" ]] && invoked_at="${waited}s"
  [[ -f "$CONF/done" ]] && break
  sleep 2; waited=$((waited+2))
done

echo
echo "== results =="
if [[ -f "$CONF/invoked" ]]; then
  ok "upsmon reached FSD and invoked SHUTDOWNCMD (after ${invoked_at:-?})"
else
  bad "SHUTDOWNCMD was never invoked within ${WAIT_SECONDS}s"
  echo "     last ups.status: $(upsc test@127.0.0.1:3494 ups.status 2>/dev/null)"
fi
inv=$(cat "$CONF/invoked" 2>/dev/null)
[[ "$inv" == *"uid=0"* ]] && ok "invoked as root" || bad "not invoked as root ($inv)"
[[ "$inv" == *"killpower_flag=present"* ]] \
  && ok "POWERDOWNFLAG written before SHUTDOWNCMD (UPS outlets will be cut)" \
  || bad "POWERDOWNFLAG was absent when SHUTDOWNCMD ran"
(( saw_early_trigger == 0 )) \
  && ok "no trigger while the UPS was OL (LB alone is correctly ignored)" \
  || bad "triggered while still OL — bad telemetry would cause a shutdown"
if [[ ! -f "$CONF/done" ]]; then
  bad "orchestrator did not finish within ${WAIT_SECONDS}s"
elif [[ "$inv" == *"orchestrator_rc=0"* ]]; then
  ok "orchestrator ran to completion under upsmon's environment (PATH without /sbin)"
else
  bad "orchestrator exited non-zero: $(grep orchestrator_rc "$CONF/invoked" 2>/dev/null)"
fi
if [[ -f "$CONF/poweroff-called" ]]; then
  ok "orchestrator reached its NAS-poweroff step and ran the command"
else
  bad "orchestrator never reached the poweroff step"
  echo "     orchestrator output tail:"; tail -5 "$CONF/orchestrator.out" 2>/dev/null | sed 's/^/       /'
fi
out=$(cat "$CONF/orchestrator.out" 2>/dev/null)
[[ "$out" == *"poweroff command: $CONF/poweroff-stub -P now"* ]] \
  && ok "poweroff command logged as configured" \
  || bad "poweroff command not logged"

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
