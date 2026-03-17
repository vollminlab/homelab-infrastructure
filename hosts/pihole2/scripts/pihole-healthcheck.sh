#!/bin/bash

LOG="/var/log/pihole-healthcheck.log"
MAX_LOG_SIZE=90 # percent

echo "--- $(date) ---" >> "$LOG"

# Check /var/log usage
usage=$(df /var/log | awk 'NR==2 {print $5}' | tr -d '%')
if (( usage >= MAX_LOG_SIZE )); then
  echo "WARNING: /var/log is ${usage}% full" >> "$LOG"
fi

# Check FTL status
if ! pihole status | grep -q 'FTL is listening'; then
  echo "ERROR: Pi-hole FTL is not running or responding" >> "$LOG"
  echo "Attempting to restart FTL..." >> "$LOG"
  sudo systemctl restart pihole-FTL
  sleep 5
  if pihole status | grep -q 'FTL is listening'; then
    echo "FTL successfully restarted" >> "$LOG"
  else
    echo "FAILED to restart FTL" >> "$LOG"
  fi
else
  echo "FTL status: OK" >> "$LOG"
fi

# Optional: NTP check
if ! timedatectl show -p NTPSynchronized --value | grep -q true; then
  echo "WARNING: System time is not synchronized with NTP" >> "$LOG"
fi


