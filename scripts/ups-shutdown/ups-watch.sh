#!/usr/bin/env bash
# ups-watch.sh — tell somebody when the lab goes on battery.
#
# Everything else in this directory is about what happens DURING an outage. None of
# it says one is happening. TrueNAS's own notification path
# (NOTIFYFLAG -> upssched -> midclt -> middleware alert) terminates in an unconfigured
# mail server, so today a power event is silent until things start shutting down.
#
# Runs from cron every minute and pushes to Pushover on a STATE CHANGE only. It is
# deliberately independent of the cluster: a UPS problem has to be reportable when
# the thing hosting Alertmanager is exactly what is at risk.
#
# Usage:
#   ups-watch.sh              # normal, cron
#   DRY_RUN=1 ups-watch.sh    # evaluate and log, never notify, never save state

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/logs/.ups-watch.state}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/logs/ups-watch.log}"
PUSHOVER_ENV="${PUSHOVER_ENV:-$SCRIPT_DIR/pushover.env}"
UPSC="${UPSC:-upsc}"
CURL="${CURL:-curl}"
UPS_IDENT="${UPS_IDENT:-ups@localhost}"
DRY_RUN="${DRY_RUN:-0}"

# The driver logs benign libusb "Pipe error" lines dozens of times a day and keeps
# working, so a single unreadable poll means nothing. Only a sustained silence is
# worth waking someone for.
DEAD_AFTER="${DEAD_AFTER:-3}"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  [[ -n "$LOG_FILE" ]] && { echo "$msg" >> "$LOG_FILE"; } 2>/dev/null
  return 0
}

# $1 priority  $2 title  $3 message
notify() {
  local prio=$1 title=$2 msg=$3
  if (( DRY_RUN )); then log "DRY-RUN would notify (p$prio): $title — $msg"; return 0; fi
  [[ -r "$PUSHOVER_ENV" ]] || { log "WARNING $PUSHOVER_ENV unreadable — cannot notify"; return 1; }
  # shellcheck disable=SC1090
  . "$PUSHOVER_ENV"
  [[ -n "${PUSHOVER_TOKEN:-}" && -n "${PUSHOVER_USER:-}" ]] || {
    log "WARNING no Pushover credentials — cannot notify"; return 1; }
  local extra=()
  # Priority 2 is Pushover's emergency tier and REQUIRES retry and expire; without
  # them the API rejects the message and the most important alert is the one lost.
  (( prio == 2 )) && extra=(-F retry=120 -F expire=3600)
  "$CURL" -sf -m 20 https://api.pushover.net/1/messages.json \
    -F "token=$PUSHOVER_TOKEN" -F "user=$PUSHOVER_USER" -F "priority=$prio" \
    "${extra[@]}" -F "title=$title" -F "message=$msg" >/dev/null \
    && { log "notified (p$prio): $title"; return 0; } \
    || { log "WARNING Pushover send failed: $title"; return 1; }
}

# ── Read the UPS ──────────────────────────────────────────────────────────────
status=$("$UPSC" "$UPS_IDENT" ups.status 2>/dev/null | tr -d '\r')
charge=$("$UPSC" "$UPS_IDENT" battery.charge 2>/dev/null | tr -d '\r')
runtime=$("$UPSC" "$UPS_IDENT" battery.runtime 2>/dev/null | tr -d '\r')

prev_state=""; prev_misses=0
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE" 2>/dev/null
  prev_state="${WATCH_STATE:-}"; prev_misses="${WATCH_MISSES:-0}"
fi

save_state() {
  (( DRY_RUN )) && return 0
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  printf 'WATCH_STATE=%s\nWATCH_MISSES=%s\n' "$1" "$2" > "$STATE_FILE" 2>/dev/null
}

# ── Classify ──────────────────────────────────────────────────────────────────
# Order matters: FSD and LB are more urgent than plain OB, and OL can legitimately
# appear alongside them in a bad-telemetry case, so check the severe flags first.
if [[ -z "$status" ]]; then
  state="unreadable"
elif [[ "$status" == *FSD* ]]; then
  state="fsd"
elif [[ "$status" == *LB* && "$status" != *OL* ]]; then
  state="lowbattery"
elif [[ "$status" == *OB* ]]; then
  state="onbattery"
elif [[ "$status" == *OL* ]]; then
  state="online"
else
  state="other"
fi

# ── Sustained silence, with hysteresis ────────────────────────────────────────
if [[ "$state" == "unreadable" ]]; then
  misses=$((prev_misses + 1))
  if (( misses == DEAD_AFTER )) && [[ "$prev_state" != "unreadable" ]]; then
    notify 1 "UPS driver is not reporting" \
      "upsc has returned nothing for ${DEAD_AFTER} consecutive minutes on $(hostname). The shutdown path cannot trigger if the UPS state is unknown."
    save_state "unreadable" "$misses"; exit 0
  fi
  log "ups unreadable (${misses}/${DEAD_AFTER})"
  # Keep the previous state until the threshold trips, so a blip cannot look like a
  # transition when readings resume.
  save_state "${prev_state:-unknown}" "$misses"
  exit 0
fi

# ── Transitions ───────────────────────────────────────────────────────────────
if [[ "$state" == "$prev_state" ]]; then
  save_state "$state" 0
  exit 0
fi

case "$state" in
  onbattery)
    notify 1 "Lab is on battery" \
      "ups.status=$status, charge ${charge}%, about $((${runtime:-0} / 60)) min of runtime. Shutdown orchestration triggers at LOWBATT." ;;
  lowbattery)
    notify 2 "Lab UPS at LOW BATTERY" \
      "ups.status=$status, charge ${charge}%. The graceful shutdown of all guests, hosts and the NAS is starting now." ;;
  fsd)
    notify 2 "Lab shutdown in progress" \
      "upsmon has set FSD. Guests, hosts and the NAS are shutting down." ;;
  online)
    if [[ -n "$prev_state" && "$prev_state" != "online" ]]; then
      notify 0 "Lab power restored" "ups.status=$status, charge ${charge}%. Previous state: $prev_state."
    else
      # First run, or recovery from a driver outage. Nothing happened worth waking
      # anyone for, so record and stay quiet.
      log "baseline established: $state ($status)"
    fi ;;
  *)
    log "unclassified ups.status: $status" ;;
esac

save_state "$state" 0
exit 0
