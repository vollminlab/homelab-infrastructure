#!/bin/bash
echo "[keepalived notify] Stopping haproxy..." | systemd-cat -t keepalived
systemctl stop haproxy

