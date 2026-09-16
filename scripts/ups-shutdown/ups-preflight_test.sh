#!/usr/bin/env bash
# Tests for ups-preflight.sh. Every external dependency is stubbed; no NAS, no
# UPS, no hosts. Run: bash ups-preflight_test.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/ups-preflight.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (wanted '$3')"; fi; }
absent() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 ('$3' should be absent)"; fi; }

setup() {
  S="$(mktemp -d)"; CALLS="$S/calls"; : > "$CALLS"

  # A healthy world: every stub returns what production would.
  printf '#!/usr/bin/env bash\nexit ${VERIFY_EXIT:-0}\n' > "$S/orchestrator.sh"
  chmod +x "$S/orchestrator.sh"
  sha256sum "$S/orchestrator.sh" > "$S/orchestrator.sha256"
  printf '#!/usr/bin/env bash\nexit ${STARTUP_VERIFY_EXIT:-0}\n' > "$S/startup.sh"
  chmod +x "$S/startup.sh"
  sha256sum "$S/startup.sh" > "$S/startup.sha256"
  : > "$S/govc"; chmod +x "$S/govc"
  echo "ESXI_USER=root" > "$S/ups-shutdown.env"; chmod 600 "$S/ups-shutdown.env"
  printf 'PUSHOVER_TOKEN=t\nPUSHOVER_USER=u\n' > "$S/pushover.env"; chmod 600 "$S/pushover.env"
  printf 'MONITOR ups@localhost 1 upsmon pw MASTER\nSHUTDOWNCMD "%s"\n' "$S/orchestrator.sh" > "$S/upsmon.conf"

  printf '#!/usr/bin/env bash\necho "${UPSC_OUT-OL}"\n' > "$S/upsc"; chmod +x "$S/upsc"
  cat > "$S/midclt" <<MID
#!/usr/bin/env bash
echo "midclt \$*" >> "$CALLS"
case "\$*" in
  *initshutdownscript.query*)
      if [[ "\${STUB_ARMED:-0}" == 1 ]]; then
        echo '[{"type":"SCRIPT","script":"/x/ups-graceful-startup.sh","when":"POSTINIT"}]'
      else
        echo '[{"type":"COMMAND","command":"other","when":"POSTINIT"}]'
      fi
      exit 0 ;;
esac
cat <<JSON
{"shutdowncmd": "\${CFG_CMD_OVERRIDE:-$S/orchestrator.sh}", "mode": "\${CFG_MODE_OVERRIDE:-MASTER}", "powerdown": true, "shutdown": "LOWBATT"}
JSON
MID
  chmod +x "$S/midclt"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\nexit 0\n' "$CALLS" > "$S/curl"; chmod +x "$S/curl"
}
teardown() { rm -rf "$S"; }

run() {
  env CALLS="$CALLS" SHUTDOWN_SCRIPT="$S/orchestrator.sh" SHA_FILE="$S/orchestrator.sha256" \
      GOVC_BIN="$S/govc" ENV_FILE="$S/ups-shutdown.env" PUSHOVER_ENV="$S/pushover.env" \
      UPSMON_CONF="$S/upsmon.conf" STAMP_FILE="$S/logs/stamp" \
      UPSC="$S/upsc" MIDCLT="$S/midclt" CURL="$S/curl" \
      STARTUP_SCRIPT="$S/startup.sh" STARTUP_SHA_FILE="$S/startup.sha256" \
      "$@" bash "$SCRIPT" 2>&1
}

echo "== a healthy system passes =="
setup
out=$(run); rc=$?
check "orchestrator present"        "$out" "PASS  orchestrator present"
check "sha is pinned and matches"   "$out" "matches the pinned sha256"
check "env file mode checked"       "$out" "env file present, mode 600"
check "UPS reachable"               "$out" "UPS reachable"
check "shutdowncmd verified"        "$out" "shutdowncmd points at the orchestrator"
check "MASTER verified"             "$out" "mode is MASTER"
check "MONITOR verified"            "$out" "has a MONITOR statement"
check "VERIFY ran"                  "$out" "VERIFY run passed"
if (( rc == 0 )); then ok "exit 0"; else bad "exit was $rc"; fi
[[ -f "$S/logs/stamp" ]] && ok "success stamp written" || bad "no success stamp"
absent "no alert on success"        "$(cat "$CALLS")" "curl"
teardown

echo "== a hand-edited orchestrator is caught =="
setup
echo "# sneaky edit" >> "$S/orchestrator.sh"
out=$(run); rc=$?
check "sha mismatch reported" "$out" "sha256 mismatch"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
check "alert sent"            "$(cat "$CALLS")" "curl"
teardown

echo "== a regenerated ups.config is caught =="
setup
out=$(run CFG_CMD_OVERRIDE=/sbin/shutdown); rc=$?
check "wrong shutdowncmd reported" "$out" "expected"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
teardown

echo "== a slave-mode NAS is caught =="
setup
out=$(run CFG_MODE_OVERRIDE=SLAVE)
check "mode failure reported" "$out" "expected MASTER"
teardown

echo "== a silent UPS driver is caught =="
setup
out=$(run UPSC_OUT=""); rc=$?
check "no status reported" "$out" "the driver is not reporting"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
teardown

echo "== a failing VERIFY is caught =="
setup
out=$(run VERIFY_EXIT=1); rc=$?
check "VERIFY failure reported" "$out" "VERIFY run failed"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
teardown

echo "== a world-readable credential file is caught =="
setup
chmod 644 "$S/ups-shutdown.env"
out=$(run)
check "mode failure reported" "$out" "must be 600"
teardown

echo "== ALERT=0 suppresses the notification =="
setup
echo "# edit" >> "$S/orchestrator.sh"
out=$(run ALERT=0)
absent "no curl call" "$(cat "$CALLS")" "curl"
teardown

echo "== missing MONITOR is caught (upsmon would watch nothing) =="
setup
grep -v '^MONITOR ' "$S/upsmon.conf" > "$S/u2" && mv "$S/u2" "$S/upsmon.conf"
out=$(run)
check "MONITOR failure reported" "$out" "watching nothing"
teardown

echo "== the startup path is checked to the same standard =="
setup
out=$(run)
check "startup script checked"  "$out" "startup orchestrator present and executable"
check "startup sha checked"     "$out" "startup orchestrator matches its pinned sha256"
check "startup VERIFY run"      "$out" "startup VERIFY run passed"
check "arming state reported"   "$out" "NOT armed at boot"
teardown

echo "== a hand-edited startup script is caught =="
setup
echo "# edit" >> "$S/startup.sh"
out=$(run); rc=$?
check "mismatch reported" "$out" "startup orchestrator sha256 mismatch"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
teardown

echo "== a failing startup VERIFY is caught =="
setup
out=$(run STARTUP_VERIFY_EXIT=1); rc=$?
check "failure reported" "$out" "startup VERIFY run failed"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
teardown

echo "== an armed hook is recognised =="
setup
out=$(run STUB_ARMED=1)
check "arming detected" "$out" "POSTINIT hook is registered"
teardown

echo "== once arming is expected, its absence fails =="
setup
out=$(run EXPECT_STARTUP_ARMED=1); rc=$?
check "absence enforced" "$out" "no init hook references"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
teardown

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
