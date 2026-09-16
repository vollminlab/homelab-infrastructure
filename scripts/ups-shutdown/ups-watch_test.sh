#!/usr/bin/env bash
# Tests for ups-watch.sh. No UPS, no network. Run: bash ups-watch_test.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/ups-watch.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (wanted '$3')"; fi; }
absent() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 ('$3' should be absent)"; fi; }

setup() {
  S="$(mktemp -d)"; CALLS="$S/calls"; : > "$CALLS"
  cat > "$S/upsc" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  ups.status)      printf '%s' "${STUB_STATUS-OL}" ;;
  battery.charge)  printf '%s' "${STUB_CHARGE-100}" ;;
  battery.runtime) printf '%s' "${STUB_RUNTIME-1375}" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\nexit 0\n' "$CALLS" > "$S/curl"
  chmod +x "$S/upsc" "$S/curl"
  printf 'PUSHOVER_TOKEN=t\nPUSHOVER_USER=u\n' > "$S/pushover.env"
}
teardown() { rm -rf "$S"; }
run() {
  env STATE_FILE="$S/state" LOG_FILE="$S/log" PUSHOVER_ENV="$S/pushover.env" \
      UPSC="$S/upsc" CURL="$S/curl" "$@" bash "$SCRIPT" 2>&1
}
titles() { grep -o 'title=[^ ]*.*' "$CALLS" 2>/dev/null | sed 's/.*title=//' | cut -d' ' -f1-6; }

echo "== first run on mains establishes a baseline quietly =="
setup
out=$(run)
check "baseline logged"    "$out" "baseline established"
absent "nobody woken up"   "$(cat "$CALLS")" "curl"
teardown

echo "== going on battery notifies once, not every minute =="
setup
run >/dev/null                                   # baseline OL
out=$(run STUB_STATUS="OB DISCHRG" STUB_CHARGE=87 STUB_RUNTIME=1200)
check "alerted"            "$out" "notified (p1): Lab is on battery"
check "includes runtime"   "$(cat "$CALLS")" "20 min of runtime"
n1=$(grep -c curl "$CALLS")
run STUB_STATUS="OB DISCHRG" STUB_CHARGE=80 >/dev/null   # still on battery
run STUB_STATUS="OB DISCHRG" STUB_CHARGE=75 >/dev/null
n2=$(grep -c curl "$CALLS")
if (( n1 == 1 && n2 == 1 )); then ok "one alert across three on-battery polls"; else bad "sent $n2 alerts"; fi
teardown

echo "== low battery escalates to emergency priority, with retry/expire =="
setup
run >/dev/null
out=$(run STUB_STATUS="OB LB" STUB_CHARGE=9)
check "emergency priority" "$out" "notified (p2): Lab UPS at LOW BATTERY"
check "retry set"          "$(cat "$CALLS")" "retry=120"
check "expire set"         "$(cat "$CALLS")" "expire=3600"
teardown

echo "== FSD is reported too =="
setup
run >/dev/null
out=$(run STUB_STATUS="FSD OB LB")
check "fsd alert" "$out" "Lab shutdown in progress"
teardown

echo "== OL LB is bad telemetry, not a low battery =="
setup
run >/dev/null
out=$(run STUB_STATUS="OL LB")
absent "no low-battery alert" "$out" "LOW BATTERY"
absent "nothing sent"         "$(cat "$CALLS")" "curl"
teardown

echo "== power restored is reported, at normal priority =="
setup
run >/dev/null
run STUB_STATUS="OB DISCHRG" >/dev/null
out=$(run STUB_STATUS="OL")
check "restore alert"   "$out" "notified (p0): Lab power restored"
check "names the prior state" "$(cat "$CALLS")" "onbattery"
teardown

echo "== a single unreadable poll is ignored; sustained silence alerts once =="
setup
run >/dev/null
out=$(run STUB_STATUS="")
check "counts the miss"  "$out" "ups unreadable (1/3)"
absent "no alert yet"    "$(cat "$CALLS")" "curl"
run STUB_STATUS="" >/dev/null
out=$(run STUB_STATUS="")
check "alerts at the threshold" "$out" "UPS driver is not reporting"
run STUB_STATUS="" >/dev/null
n=$(grep -c curl "$CALLS")
if (( n == 1 )); then ok "does not repeat while still silent"; else bad "sent $n"; fi
teardown

echo "== recovering from a driver outage does not fake a power event =="
setup
run >/dev/null                       # baseline online
run STUB_STATUS="" >/dev/null
run STUB_STATUS="" >/dev/null
out=$(run)                           # readings return, still OL
absent "no restored alert" "$out" "power restored"
teardown

echo "== DRY_RUN never notifies and never writes state =="
setup
out=$(run DRY_RUN=1 STUB_STATUS="OB DISCHRG")
check "says what it would do" "$out" "DRY-RUN would notify"
absent "nothing sent"         "$(cat "$CALLS")" "curl"
[[ -f "$S/state" ]] && bad "state file was written" || ok "no state written"
teardown

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
