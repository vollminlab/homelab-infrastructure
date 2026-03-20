#!/usr/bin/env bash
# deploy-pihole-flask-api.sh
#
# Pull the latest pihole-flask-api on both Pi-hole hosts and restart the service.
# Optionally adds DNS CNAME records via the Flask API.
#
# Usage:
#   bash deploy-pihole-flask-api.sh           # deploy only
#   bash deploy-pihole-flask-api.sh --dns     # deploy + add CNAME records
#
# Requirements:
#   - System32 OpenSSH in PATH (for 1Password agent on Windows Git Bash)
#   - SSH access to pihole1 and pihole2 (via ssh config aliases)
#   - op CLI authenticated (for --dns flag)

set -euo pipefail

# Use System32 OpenSSH so the 1Password SSH agent named pipe is reachable
export PATH="/c/Windows/System32/OpenSSH:$PATH"

HOSTS=("pihole1" "pihole2")
DEPLOY_DIR="/opt/pihole-flask-api"
SERVICE="pihole-flask-api"
ADD_DNS=false

if [[ "${1:-}" == "--dns" ]]; then
  ADD_DNS=true
fi

# ── Deploy ────────────────────────────────────────────────────────────────────

for host in "${HOSTS[@]}"; do
  echo "==> Deploying to $host"
  ssh "$host" "sudo git -C $DEPLOY_DIR pull && sudo systemctl restart $SERVICE"
  echo "    ✓ $host done"
done

echo ""
echo "==> Verifying services are active"
for host in "${HOSTS[@]}"; do
  status=$(ssh "$host" "systemctl is-active $SERVICE" 2>/dev/null || true)
  echo "    $host: $SERVICE is $status"
done

# ── DNS CNAME records (optional) ─────────────────────────────────────────────

if [[ "$ADD_DNS" == "true" ]]; then
  echo ""
  echo "==> Adding DNS CNAME records via pihole-flask-api"

  # Fetch API key from 1Password
  API_KEY=$(op read "op://Homelab/recordimporter-api-token/password")
  API_BASE="http://192.168.100.2:5001"
  TARGET="haproxyvip.vollminlab.com"

  CNAMES=(
    "go.vollminlab.com"
    "shlink.vollminlab.com"
  )

  for domain in "${CNAMES[@]}"; do
    echo "    Adding CNAME: $domain → $TARGET"
    response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/add-cname-record" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_KEY" \
      -d "{\"domain\": \"$domain\", \"target\": \"$TARGET\"}")
    if [[ "$response" == "200" ]]; then
      echo "    ✓ $domain added"
    elif [[ "$response" == "409" ]]; then
      echo "    ~ $domain already exists (skipped)"
    else
      echo "    ✗ $domain failed (HTTP $response)"
    fi
  done
fi

echo ""
echo "Done."
