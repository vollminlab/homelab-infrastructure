#!/bin/bash
echo "[keepalived notify] Starting haproxy..." | systemd-cat -t keepalived
systemctl start haproxy

