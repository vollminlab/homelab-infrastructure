#!/usr/bin/env bash
# collect-k8s-configs.sh
#
# Exports Kubernetes cluster-level configs via kubectl.
# Uses the local kubeconfig (~/.kube/config) — no SSH or credentials needed.
#
# Captures what kubeadm stores in the cluster but is not tracked in the
# Flux GitOps repo (k8s-vollminlab-cluster):
#   - kubeadm ClusterConfiguration
#   - kubelet config template
#   - Node inventory (labels, taints, versions)
#
# Usage: bash scripts/collect-k8s-configs.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO/hosts/k8s"

mkdir -p "$OUT_DIR"

echo "==> Kubernetes cluster configs"

if ! command -v kubectl &>/dev/null; then
  echo "  ERROR: kubectl not found in PATH" >&2
  exit 1
fi

if ! kubectl cluster-info &>/dev/null 2>&1; then
  echo "  ERROR: kubectl cannot reach the cluster — check kubeconfig" >&2
  exit 1
fi

fetch() {
  local desc=$1 outfile=$2
  shift 2
  kubectl "$@" > "$OUT_DIR/$outfile"
  echo "  pulled $outfile ($(wc -c < "$OUT_DIR/$outfile") bytes)"
}

fetch "kubeadm ClusterConfiguration" kubeadm-config.yaml \
  get cm kubeadm-config -n kube-system -o yaml

fetch "kubelet config" kubelet-config.yaml \
  get cm kubelet-config -n kube-system -o yaml

fetch "node inventory" nodes.yaml \
  get nodes -o yaml

echo ""
echo "Done. Review before committing:"
echo "  git diff --stat hosts/k8s/"
