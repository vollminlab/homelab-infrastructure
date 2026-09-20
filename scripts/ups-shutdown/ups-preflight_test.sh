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
  # Emits the two lines preflight reads the EFFECTIVE timeouts back from, so the
  # stub exercises that path rather than skipping it. Overridable per-test.
  printf '#!/usr/bin/env bash\necho "=== UPS graceful shutdown starting (DRY_RUN=1, VERIFY=1, deadline=${STUB_DEADLINE:-240}s) ==="\necho "[esxi01] DRY-RUN would poll up to ${STUB_GUEST:-180}s for guests to power off"\nexit ${VERIFY_EXIT:-0}\n' > "$S/orchestrator.sh"
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
  cat > "$S/ss" <<'STUB'
#!/usr/bin/env bash
echo "Recv-Q Send-Q Local Address:Port Peer Address:Port"
n=${STUB_SECONDARIES-2}
i=0; while [ "$i" -lt "$n" ]; do echo "0 0 [::ffff:192.168.150.2]:3493 [::ffff:192.168.100.$((3+i))]:41766"; i=$((i+1)); done
echo "0 0 [::1]:3493 [::1]:34578"
STUB
  chmod +x "$S/ss"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\nexit 0\n' "$CALLS" > "$S/curl"; chmod +x "$S/curl"
}
teardown() { rm -rf "$S"; }

run() {
  env CALLS="$CALLS" SHUTDOWN_SCRIPT="$S/orchestrator.sh" SHA_FILE="$S/orchestrator.sha256" \
      GOVC_BIN="$S/govc" ENV_FILE="$S/ups-shutdown.env" PUSHOVER_ENV="$S/pushover.env" \
      UPSMON_CONF="$S/upsmon.conf" STAMP_FILE="$S/logs/stamp" \
      UPSC="$S/upsc" MIDCLT="$S/midclt" CURL="$S/curl" SS="$S/ss" \
      STARTUP_SCRIPT="$S/startup.sh" STARTUP_SHA_FILE="$S/startup.sha256" \
      STUB_ARMED="${BASELINE_ARMED:-1}" \
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
check "effective guest timeout"     "$out" "effective GUEST_TIMEOUT is 180s"
check "effective total deadline"    "$out" "effective TOTAL_DEADLINE is 240s"
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

echo "== the env file pinning a stale GUEST_TIMEOUT is caught =="
# The 2026-09-20 case: script deployed, sha256 matches git, every other check
# passes, and ups-shutdown.env still overrides GUEST_TIMEOUT back to 120.
setup
out=$(run STUB_GUEST=120); rc=$?
check "stale guest timeout reported" "$out" "effective GUEST_TIMEOUT is 120s, expected 180s"
check "names the env file"           "$out" "it overrides the script default"
[[ $rc -ne 0 ]] && ok "exit non-zero" || bad "exit was $rc"

echo "== EXPECT_GUEST_TIMEOUT retunes the check without code changes =="
setup
out=$(run STUB_GUEST=120 EXPECT_GUEST_TIMEOUT=120); rc=$?
check "accepts the tuned value" "$out" "effective GUEST_TIMEOUT is 120s"
[[ $rc -eq 0 ]] && ok "exit zero" || bad "exit was $rc"

echo "== a stale TOTAL_DEADLINE is caught too =="
setup
out=$(run STUB_DEADLINE=200); rc=$?
check "stale deadline reported" "$out" "effective TOTAL_DEADLINE is 200s, expected 240s"
[[ $rc -ne 0 ]] && ok "exit non-zero" || bad "exit was $rc"

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
check "arming state reported"   "$out" "POSTINIT hook is registered"
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

echo "== a hook that has gone missing is now a FAILURE, not a note =="
setup
out=$(run STUB_ARMED=0); rc=$?
check "absence enforced by default" "$out" "no init hook references"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
check "alert sent"                  "$(cat "$CALLS")" "curl"
teardown

echo "== EXPECT_STARTUP_ARMED=0 downgrades it back to a note =="
setup
out=$(run STUB_ARMED=0 EXPECT_STARTUP_ARMED=0); rc=$?
check "reported as a note" "$out" "NOT armed at boot"
if (( rc == 0 )); then ok "exit 0 — a note does not fail the run"; else bad "exit was $rc"; fi
teardown

echo "== NUT secondaries are counted, not assumed =="
setup
out=$(run)
check "both secondaries seen" "$out" "2 NUT secondary connection(s) established"
teardown

echo "== a secondary that stopped connecting is caught =="
setup
out=$(run STUB_SECONDARIES=1); rc=$?
check "shortfall reported" "$out" "only 1 NUT secondary"
check "says why it matters" "$out" "gets hard-cut"
if (( rc != 0 )); then ok "exit non-zero"; else bad "exit was 0"; fi
teardown

echo "== loopback connections are not counted as secondaries =="
setup
out=$(run STUB_SECONDARIES=0); rc=$?
check "zero counted" "$out" "only 0 NUT secondary"
teardown

echo "== EXPECT_SECONDARIES=0 disables the check =="
setup
out=$(run STUB_SECONDARIES=0 EXPECT_SECONDARIES=0); rc=$?
absent "check skipped" "$out" "NUT secondary connection"
if (( rc == 0 )); then ok "exit 0"; else bad "exit was $rc"; fi
teardown

echo
echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
