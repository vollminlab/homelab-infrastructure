#!/bin/bash

CERT_NAME="vollminlab.com"
SRC_FULLCHAIN="/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem"
SRC_PRIVKEY="/etc/letsencrypt/live/${CERT_NAME}/privkey.pem"

LOCAL_PEM="/etc/haproxy/certs/wildcard-vollminlab.com.pem"

REMOTE_HOST="haproxydmz02.vollminlab.com"
REMOTE_TMP="/tmp/wildcard-vollminlab.com.pem"
REMOTE_PEM="/etc/haproxy/certs/wildcard-vollminlab.com.pem"
SSH_KEY="/root/.ssh/id_ed25519_certsync"

echo "[sync] Rebuilding local HAProxy PEM from Let's Encrypt cert..."
cat "$SRC_FULLCHAIN" "$SRC_PRIVKEY" > "$LOCAL_PEM"
chown root:root "$LOCAL_PEM"
chmod 600 "$LOCAL_PEM"
echo "[sync] Local PEM rebuilt at $LOCAL_PEM"

echo "[sync] Copying PEM to ${REMOTE_HOST}:${REMOTE_TMP} as vollmin..."
scp -i "$SSH_KEY" "$LOCAL_PEM" "vollmin@${REMOTE_HOST}:${REMOTE_TMP}"

echo "[sync] Installing PEM on ${REMOTE_HOST} and (re)loading haproxy..."
ssh -i "$SSH_KEY" "vollmin@${REMOTE_HOST}" '
  set -e
  sudo mv /tmp/wildcard-vollminlab.com.pem /etc/haproxy/certs/wildcard-vollminlab.com.pem
  sudo chown root:root /etc/haproxy/certs/wildcard-vollminlab.com.pem
  sudo chmod 600 /etc/haproxy/certs/wildcard-vollminlab.com.pem
  if sudo systemctl reload haproxy 2>/dev/null; then
    echo "[sync-remote] haproxy reloaded."
  else
    echo "[sync-remote] reload failed, trying restart..."
    sudo systemctl restart haproxy 2>/dev/null || echo "[sync-remote] WARNING: haproxy restart failed."
  fi
'

echo "[sync] (Re)loading haproxy locally..."
if systemctl reload haproxy 2>/dev/null; then
  echo "[sync] Local haproxy reloaded."
else
  echo "[sync] Local reload failed, trying restart..."
  systemctl restart haproxy 2>/dev/null || echo "[sync] WARNING: local haproxy restart failed."
fi

echo "[sync] Done."

