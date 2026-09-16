#!/usr/bin/env bash
# ups-preflight.sh — scheduled proof that the UPS shutdown path still works.
#
# Runs on TrueNAS from a middleware cron job, as root. Every check answers one
# question: "if the power failed right now, would the orchestration run?"
#
# It exists because every link in that chain fails silently. A rotated ESXi
# password, a TrueNAS upgrade regenerating /etc/nut, a hand-edit of the deployed
# script, a govc binary lost to a dataset rollback — none of them announce
# themselves, and all of them surface for the first time during an outage, which
# is the one moment with no time to debug.
#
# Usage:
#   ups-preflight.sh          # run every check, alert on failure
#   ALERT=0 ups-preflight.sh  # run every check, never send a notification
#
# Exit status: 0 = every performed check passed. Non-zero = at least one failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Seams. Defaults are production; the test suite overrides every one of them.
SHUTDOWN_SCRIPT="${SHUTDOWN_SCRIPT:-$SCRIPT_DIR/ups-graceful-shutdown.sh}"
SHA_FILE="${SHA_FILE:-$SCRIPT_DIR/ups-graceful-shutdown.sh.sha256}"
STARTUP_SCRIPT="${STARTUP_SCRIPT:-$SCRIPT_DIR/ups-graceful-startup.sh}"
STARTUP_SHA_FILE="${STARTUP_SHA_FILE:-$SCRIPT_DIR/ups-graceful-startup.sh.sha256}"
# The boot hook is deliberately unarmed for now, so its absence is a note rather
# than a failure. Flip this to 1 once it is armed and it becomes enforced.
EXPECT_STARTUP_ARMED="${EXPECT_STARTUP_ARMED:-0}"
GOVC_BIN="${GOVC_BIN:-$SCRIPT_DIR/govc}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/ups-shutdown.env}"
PUSHOVER_ENV="${PUSHOVER_ENV:-$SCRIPT_DIR/pushover.env}"
UPSMON_CONF="${UPSMON_CONF:-/etc/nut/upsmon.conf}"
STAMP_FILE="${STAMP_FILE:-$SCRIPT_DIR/logs/last-preflight-ok}"
UPSC="${UPSC:-upsc}"
MIDCLT="${MIDCLT:-midclt}"
CURL="${CURL:-curl}"
UPS_IDENT="${UPS_IDENT:-ups@localhost}"
ALERT="${ALERT:-1}"

PASSED=0; FAILED=0; SKIPPED=0
FAILURES=""

say()  { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
pass() { PASSED=$((PASSED+1)); say "  PASS  $1"; }
skip() { SKIPPED=$((SKIPPED+1)); say "  SKIP  $1"; }
fail() { FAILED=$((FAILED+1)); FAILURES="${FAILURES}- $1"$'\n'; say "  FAIL  $1"; }

say "=== UPS preflight starting ==="

# 1 — the orchestrator is where NUT expects it, and runnable.
if [[ -x "$SHUTDOWN_SCRIPT" ]]; then
  pass "orchestrator present and executable ($SHUTDOWN_SCRIPT)"
else
  fail "orchestrator missing or not executable at $SHUTDOWN_SCRIPT"
fi

# 2 — it is the version that was reviewed. The deployed copy is a file on a
# dataset, not a git checkout; nothing but this check would notice a hand-edit.
if [[ -f "$SHA_FILE" ]]; then
  want=$(awk '{print $1}' "$SHA_FILE")
  got=$(sha256sum "$SHUTDOWN_SCRIPT" 2>/dev/null | awk '{print $1}')
  if [[ -n "$got" && "$got" == "$want" ]]; then
    pass "orchestrator matches the pinned sha256"
  else
    fail "orchestrator sha256 mismatch — pinned ${want:0:12}, on disk ${got:0:12}"
  fi
else
  skip "no pinned sha256 at $SHA_FILE (write one at deploy time)"
fi

# 3 — govc is the only way the script reaches the hosts.
[[ -x "$GOVC_BIN" ]] && pass "govc present and executable" \
                     || fail "govc missing or not executable at $GOVC_BIN"

# 4 — the credential file exists and is not world-readable.
if [[ -f "$ENV_FILE" ]]; then
  mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null)
  if [[ "$mode" == "600" || "$mode" == "400" ]]; then
    pass "env file present, mode $mode"
  else
    fail "env file mode is $mode — must be 600 (it holds an ESXi credential in cleartext)"
  fi
else
  fail "env file missing at $ENV_FILE"
fi

# 5 — NUT is actually talking to the UPS. A driver that has stopped reporting
# cannot raise the event that starts any of this.
status=$("$UPSC" "$UPS_IDENT" ups.status 2>/dev/null)
if [[ -n "$status" ]]; then
  pass "UPS reachable, ups.status = $status"
else
  fail "no ups.status from $UPS_IDENT — the driver is not reporting"
fi

# 6 — the UPS service still points at the orchestrator. A TrueNAS upgrade or a
# UI save regenerates /etc/nut from the middleware config, so this is the field
# that decides what actually runs.
if cfg=$("$MIDCLT" call ups.config 2>/dev/null) && [[ -n "$cfg" ]]; then
  eval "$(printf '%s' "$cfg" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
def q(v): return str(v).replace(chr(39),'')
print('CFG_CMD=%r'    % q(d.get('shutdowncmd') or ''))
print('CFG_MODE=%r'   % q(d.get('mode') or ''))
print('CFG_PD=%r'     % q(d.get('powerdown')))
print('CFG_SHUT=%r'   % q(d.get('shutdown') or ''))
" 2>/dev/null)"
  [[ "${CFG_CMD:-}" == "$SHUTDOWN_SCRIPT" ]] \
    && pass "ups.config shutdowncmd points at the orchestrator" \
    || fail "ups.config shutdowncmd is '${CFG_CMD:-<unset>}', expected '$SHUTDOWN_SCRIPT'"
  [[ "${CFG_MODE:-}" == "MASTER" ]] \
    && pass "ups.config mode is MASTER (this NAS owns the shutdown)" \
    || fail "ups.config mode is '${CFG_MODE:-<unset>}', expected MASTER"
  [[ "${CFG_PD:-}" == "True" || "${CFG_PD:-}" == "true" ]] \
    && pass "ups.config powerdown is on (UPS outlets get cut)" \
    || fail "ups.config powerdown is '${CFG_PD:-<unset>}', expected True"
  say "  note  ups.config shutdown trigger = ${CFG_SHUT:-<unset>}"
else
  skip "midclt unavailable (not root?) — ups.config invariants unchecked"
fi

# 7 — and the generated file agrees. MONITOR is what makes upsmon watch anything
# at all; without it the daemon starts happily and monitors nothing.
if [[ -r "$UPSMON_CONF" ]]; then
  grep -q '^MONITOR ' "$UPSMON_CONF" \
    && pass "upsmon.conf has a MONITOR statement" \
    || fail "upsmon.conf has no MONITOR statement — upsmon is watching nothing"
  grep -q "^SHUTDOWNCMD \"$SHUTDOWN_SCRIPT\"" "$UPSMON_CONF" \
    && pass "upsmon.conf SHUTDOWNCMD matches the orchestrator" \
    || fail "upsmon.conf SHUTDOWNCMD does not match $SHUTDOWN_SCRIPT"
else
  skip "$UPSMON_CONF not readable (not root?) — generated config unchecked"
fi

# 8 — the end-to-end probe: hosts reachable, credential valid, privilege held,
# poweroff flags accepted. This is the check that would have caught `-p`.
if [[ -x "$SHUTDOWN_SCRIPT" ]]; then
  if verify_out=$(VERIFY=1 "$SHUTDOWN_SCRIPT" 2>&1); then
    pass "VERIFY run passed ($(grep -c 'PROBE PASS' <<< "$verify_out") probes)"
  else
    fail "VERIFY run failed: $(grep 'PROBE FAIL' <<< "$verify_out" | head -5 | tr '\n' ';')"
  fi
else
  skip "VERIFY not run — orchestrator not executable"
fi

# ── The startup path gets the same treatment ─────────────────────────────────
#
# It rots the same way and for the same reasons. Two paths that are verified to
# different standards is how one of them quietly stops working.

if [[ -x "$STARTUP_SCRIPT" ]]; then
  pass "startup orchestrator present and executable"
else
  fail "startup orchestrator missing or not executable at $STARTUP_SCRIPT"
fi

if [[ -f "$STARTUP_SHA_FILE" ]]; then
  swant=$(awk '{print $1}' "$STARTUP_SHA_FILE")
  sgot=$(sha256sum "$STARTUP_SCRIPT" 2>/dev/null | awk '{print $1}')
  if [[ -n "$sgot" && "$sgot" == "$swant" ]]; then
    pass "startup orchestrator matches its pinned sha256"
  else
    fail "startup orchestrator sha256 mismatch — pinned ${swant:0:12}, on disk ${sgot:0:12}"
  fi
else
  skip "no pinned sha256 at $STARTUP_SHA_FILE (write one at deploy time)"
fi

# Covers the PowerOn privilege, every gate, the tier list, orphaned guests, and the
# AMT credentials when the fallback is enabled — all read-only.
if [[ -x "$STARTUP_SCRIPT" ]]; then
  if sverify=$(VERIFY=1 "$STARTUP_SCRIPT" 2>&1); then
    pass "startup VERIFY run passed ($(grep -c 'PROBE PASS' <<< "$sverify") probes)"
  else
    fail "startup VERIFY run failed: $(grep 'PROBE FAIL' <<< "$sverify" | head -5 | tr '\n' ';')"
  fi
else
  skip "startup VERIFY not run — orchestrator not executable"
fi

# Is anything actually going to run it at boot? A perfect script nobody invokes is
# the same outcome as no script.
if hooks=$("$MIDCLT" call initshutdownscript.query 2>/dev/null) && [[ -n "$hooks" ]]; then
  if grep -q 'ups-graceful-startup.sh' <<< "$hooks"; then
    pass "a POSTINIT hook is registered for the startup orchestrator"
  elif (( EXPECT_STARTUP_ARMED )); then
    fail "EXPECT_STARTUP_ARMED=1 but no init hook references ups-graceful-startup.sh"
  else
    say "  note  startup orchestrator is NOT armed at boot (expected for now)"
  fi
else
  skip "could not query init scripts (not root?) — arming state unchecked"
fi

say "=== preflight complete: $PASSED passed, $FAILED failed, $SKIPPED skipped ==="

if (( FAILED == 0 )); then
  mkdir -p "$(dirname "$STAMP_FILE")" 2>/dev/null
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP_FILE" 2>/dev/null
  (( SKIPPED > 0 )) && say "NOTE: $SKIPPED check(s) skipped — a clean result is only as broad as what ran"
  exit 0
fi

# Failure path. Alerting goes straight to Pushover rather than through
# Alertmanager on purpose: a UPS problem must be reportable when the cluster
# that hosts Alertmanager is exactly what is at risk.
if (( ALERT )) && [[ -r "$PUSHOVER_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$PUSHOVER_ENV"
  if [[ -n "${PUSHOVER_TOKEN:-}" && -n "${PUSHOVER_USER:-}" ]]; then
    "$CURL" -sf -m 20 https://api.pushover.net/1/messages.json \
      -F "token=$PUSHOVER_TOKEN" -F "user=$PUSHOVER_USER" -F priority=1 \
      -F "title=UPS shutdown preflight FAILED on $(hostname)" \
      -F "message=$FAILED of $((PASSED+FAILED)) checks failed:"$'\n'"$FAILURES" \
      >/dev/null && say "alert sent to Pushover" || say "WARNING: Pushover alert failed to send"
  else
    say "WARNING: $PUSHOVER_ENV has no PUSHOVER_TOKEN/PUSHOVER_USER — no alert sent"
  fi
elif (( ALERT )); then
  say "WARNING: $PUSHOVER_ENV missing or unreadable — no alert sent"
fi

exit 1
