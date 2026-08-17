#!/bin/bash
set -u

LOG="/var/log/pihole-healthcheck.log"
STATE_DIR="/var/lib/pihole-healthcheck"
FAIL_FILE="$STATE_DIR/fail-count"
LAST_RESTART_FILE="$STATE_DIR/last-restart-epoch"
MAX_LOG_SIZE=90
FAIL_THRESHOLD=2
RESTART_COOLDOWN=1800
API_URL="http://127.0.0.1/api/auth"
API_TIMEOUT=5

mkdir -p "$STATE_DIR"

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
  echo "[$(timestamp)] $*" >> "$LOG"
}

read_int_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file" 2>/dev/null
  else
    echo 0
  fi
}

write_int_file() {
  local file="$1"
  local value="$2"
  printf '%s\n' "$value" > "$file"
}

api_http_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time "$API_TIMEOUT" "$API_URL" 2>/dev/null || echo 000
}

service_ok=false
api_ok=false
fail_count=$(read_int_file "$FAIL_FILE")
last_restart=$(read_int_file "$LAST_RESTART_FILE")
now_epoch=$(date +%s)
usage=$(df /var/log | awk 'NR==2 {print $5}' | tr -d '%')

log "--- healthcheck start ---"

if (( usage >= MAX_LOG_SIZE )); then
  log "WARNING: /var/log is ${usage}% full"
fi

if systemctl is-active --quiet pihole-FTL; then
  service_ok=true
fi

http_code=$(api_http_code)
if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
  api_ok=true
fi

if $service_ok && $api_ok; then
  if (( fail_count > 0 )); then
    log "FTL recovered: service active and API reachable (HTTP ${http_code}); resetting fail counter from ${fail_count}"
  else
    log "FTL status OK: service active and API reachable (HTTP ${http_code})"
  fi
  write_int_file "$FAIL_FILE" 0
else
  fail_count=$((fail_count + 1))
  write_int_file "$FAIL_FILE" "$fail_count"
  log "FTL healthcheck failure ${fail_count}/${FAIL_THRESHOLD}: service_ok=${service_ok}, api_http_code=${http_code}"

  if ! timedatectl show -p NTPSynchronized --value | grep -q true; then
    log "WARNING: System time is not synchronized with NTP"
  fi

  if (( fail_count < FAIL_THRESHOLD )); then
    log "Deferring restart until ${FAIL_THRESHOLD} consecutive failures"
    exit 0
  fi

  if (( now_epoch - last_restart < RESTART_COOLDOWN )); then
    remaining=$((RESTART_COOLDOWN - (now_epoch - last_restart)))
    log "Restart cooldown active; skipping restart for another ${remaining}s"
    exit 0
  fi

  log "Restarting pihole-FTL after ${fail_count} consecutive failures"
  systemctl restart pihole-FTL
  write_int_file "$LAST_RESTART_FILE" "$now_epoch"
  sleep 10

  if systemctl is-active --quiet pihole-FTL; then
    post_code=$(api_http_code)
    if [[ "$post_code" == "200" || "$post_code" == "401" ]]; then
      log "FTL successfully restarted; API reachable (HTTP ${post_code})"
      write_int_file "$FAIL_FILE" 0
    else
      log "WARNING: FTL restarted but API probe still failing (HTTP ${post_code})"
    fi
  else
    log "FAILED to restart FTL"
  fi
fi

