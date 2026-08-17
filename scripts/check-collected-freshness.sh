#!/usr/bin/env bash
#
# Report how stale the collected host configs are.
#
# Why this exists: every doc in this repo that turned out to be wrong on
# 2026-08-17 was wrong because it faithfully described a stale snapshot, not
# because anyone mis-typed it. Specifically:
#
#   hosts/vsphere/cluster.json    128 days  -> docs said DRS was "partially
#                                              automated"; live is fullyAutomated
#   hosts/truenas/services.json   128 days  -> docs said the UPS service was
#                                              disabled; live is enabled+running
#   hosts/vsphere/datastores.json 126 days  -> vm-lt-metrics looked non-existent;
#                                              it is a live 13.4 TB datastore
#   hosts/vsphere/vms.json         45 days  -> control plane looked like it sat on
#                                              shared storage; it is on local NVMe
#
# generate-vm-inventory.py --check already proves the *doc* matches the
# *snapshot*. That check passed throughout, because a doc generated from stale
# data is perfectly consistent and perfectly wrong. Consistency and freshness are
# different properties and both need a guard.
#
# Age is measured from the last commit that touched each file, not mtime, because
# mtime is meaningless after a clone.
#
# Usage: scripts/check-collected-freshness.sh [--fail-over DAYS]
# Exit 0 unless a file exceeds the hard limit.

set -uo pipefail

WARN_DAYS="${WARN_DAYS:-30}"
FAIL_DAYS="${FAIL_DAYS:-180}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fail-over) FAIL_DAYS="$2"; shift 2 ;;
    --warn-over) WARN_DAYS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
[[ -d hosts ]] || { echo "❌ hosts/ not found — run from the repo root"; exit 1; }

# GitHub Actions renders ::warning:: as a PR annotation; locally it is just text.
annotate() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::warning file=$2::$1"; fi
}

now=$(date +%s)
worst=0
stale_count=0
rows=()

while IFS= read -r f; do
  ts=$(git log -1 --format=%at -- "$f" 2>/dev/null)
  [[ -z "$ts" ]] && continue          # untracked, nothing to date it by
  age=$(( (now - ts) / 86400 ))
  (( age > worst )) && worst=$age
  flag="ok"
  if (( age >= FAIL_DAYS )); then
    flag="STALE"
    annotate "Collected $f is ${age} days old (hard limit ${FAIL_DAYS}). Re-run the matching collector; docs generated from it are consistent but not current." "$f"
    stale_count=$((stale_count+1))
  elif (( age >= WARN_DAYS )); then
    flag="aging"
    annotate "Collected $f is ${age} days old. Re-run the matching collector before trusting docs derived from it." "$f"
  fi
  rows+=("$(printf '%5s  %-7s %s' "$age" "$flag" "$f")")
done < <(find hosts -type f \( -name '*.json' -o -name '*.conf' -o -name '*.cfg' -o -name '*.toml' \) | sort)

echo "Collected snapshot ages (days since the last commit that touched each file)"
echo "  warn >= ${WARN_DAYS}d, fail >= ${FAIL_DAYS}d"
echo
printf '%s\n' "${rows[@]}" | sort -rn
echo
echo "oldest: ${worst} days"

if (( stale_count > 0 )); then
  echo
  echo "❌ ${stale_count} file(s) past the ${FAIL_DAYS}-day hard limit."
  echo "   Re-collect with scripts/collect-all.sh, or the specific collector:"
  echo "     hosts/vsphere/*   -> scripts/Export-VSphereConfigs.ps1"
  echo "     hosts/truenas/*   -> scripts/collect-truenas-configs.sh"
  echo "     hosts/k8s/*       -> scripts/collect-k8s-configs.sh"
  echo "     everything else   -> scripts/collect-host-configs.sh"
  exit 1
fi

echo "✅ nothing past the ${FAIL_DAYS}-day hard limit"
