#!/usr/bin/env bash
# collect-truenas-configs.sh
#
# Exports TrueNAS config via the REST API v2.0.
# Saves JSON snapshots to hosts/truenas/.
#
# Run from a terminal with network access to truenas.vollminlab.com.
# Usage: ./scripts/collect-truenas-configs.sh

set -euo pipefail

TRUENAS_URL="https://truenas.vollminlab.com"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO/hosts/truenas"

mkdir -p "$OUT_DIR"

# ── Auth ───────────────────────────────────────────────────────────────────────

if command -v op &>/dev/null; then
  TRUENAS_KEY=$(op item get 5n53chsckejehks7ke2arv2n6e --fields label=password --reveal)
else
  read -rsp "TrueNAS API key: " TRUENAS_KEY
  echo
fi

echo "==> Authenticating with TrueNAS at $TRUENAS_URL"

if ! curl -sf -o /dev/null \
    -H "Authorization: Bearer $TRUENAS_KEY" \
    "$TRUENAS_URL/api/v2.0/system/info"; then
  echo "ERROR: Authentication failed — check API key and that TrueNAS is reachable." >&2
  exit 1
fi

echo "  authenticated"

# ── Fetch ──────────────────────────────────────────────────────────────────────

fetch() {
  local endpoint=$1 outfile=$2
  local dest="$OUT_DIR/$outfile"
  curl -sf \
    -H "Authorization: Bearer $TRUENAS_KEY" \
    "$TRUENAS_URL/api/v2.0/$endpoint" > "$dest"
  # Pretty-print in-place with LF line endings (json.tool uses OS default = CRLF on Windows)
  for py in python3 python py; do
    if command -v "$py" &>/dev/null 2>&1; then
      "$py" -c "
import sys, json

REDACT_KEYS = {'privatekey', 'certificate', 'CSR'}

def redact(obj):
    if isinstance(obj, dict):
        return {k: 'REDACTED' if k in REDACT_KEYS else redact(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(i) for i in obj]
    return obj

d = json.load(open(sys.argv[1]))
open(sys.argv[1], 'w', newline='\n').write(json.dumps(redact(d), indent=2) + '\n')
" "$dest" 2>/dev/null && break
    fi
  done
  echo "  pulled $outfile ($(wc -c < "$dest") bytes)"
}

echo "==> Fetching configs"
fetch "pool"                  pools.json
fetch "pool/dataset"          datasets.json
fetch "sharing/smb"           smb-shares.json
fetch "sharing/nfs"           nfs-shares.json
fetch "network/configuration" network-config.json
fetch "service"               services.json
fetch "system/general"        system-general.json
fetch "cronjob"               cronjobs.json

echo ""
echo "Done. Review before committing:"
echo "  git diff --stat hosts/truenas/"
