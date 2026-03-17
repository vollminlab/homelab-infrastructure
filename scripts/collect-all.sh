#!/usr/bin/env bash
# collect-all.sh
#
# Master collection script — runs all host and service config collectors in sequence.
# Run from a terminal where your 1Password SSH agent is active.
#
# Usage: ./scripts/collect-all.sh
#
# After completion, review changes before committing:
#   git diff --stat
#   git diff

set -euo pipefail

export PATH="/c/Windows/System32/OpenSSH:$PATH"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$REPO/scripts"

echo "╔══════════════════════════════════════════╗"
echo "║   Vollminlab infrastructure collection   ║"
echo "╚══════════════════════════════════════════╝"

# ── SSH hosts ─────────────────────────────────────────────────────────────────
echo ""
echo "── SSH hosts ────────────────────────────────"
bash "$SCRIPTS/collect-host-configs.sh"

# ── NPM (Nginx Proxy Manager) ─────────────────────────────────────────────────
echo ""
echo "── Nginx Proxy Manager ──────────────────────"
bash "$SCRIPTS/collect-npm-configs.sh"

# ── TrueNAS ───────────────────────────────────────────────────────────────────
echo ""
echo "── TrueNAS ──────────────────────────────────"
bash "$SCRIPTS/collect-truenas-configs.sh"

# ── Kubernetes ────────────────────────────────────────────────────────────────
echo ""
echo "── Kubernetes ───────────────────────────────"
bash "$SCRIPTS/collect-k8s-configs.sh"

# ── vSphere ───────────────────────────────────────────────────────────────────
echo ""
echo "── vSphere ──────────────────────────────────"
powershell.exe -ExecutionPolicy Bypass -File "$SCRIPTS/Export-VSphereConfigs.ps1"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Done — review before committing        ║"
echo "╚══════════════════════════════════════════╝"
echo ""
git -C "$REPO" diff --stat
