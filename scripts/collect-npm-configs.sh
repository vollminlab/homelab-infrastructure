#!/usr/bin/env bash
# collect-npm-configs.sh
#
# Exports Nginx Proxy Manager configs via the NPM REST API.
# Saves JSON snapshots of proxy hosts, redirection hosts, streams,
# and certificates to hosts/nginx01/npm/.
#
# Run from a terminal with network access to npm.vollminlab.com.
# Usage: ./scripts/collect-npm-configs.sh

set -euo pipefail

NPM_URL="http://npm.vollminlab.com:81"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO/hosts/nginx01/npm"

mkdir -p "$OUT_DIR"

# ── Auth ───────────────────────────────────────────────────────────────────────

if command -v op &>/dev/null; then
  _line=$(op item get jrma5hnjb6de3l2kkul5ghuiri --fields label=username,label=password --reveal)
  NPM_EMAIL="${_line%%,*}"
  NPM_PASS="${_line#*,}"
else
  read -rp "NPM admin email: " NPM_EMAIL
  read -rsp "NPM admin password: " NPM_PASS
  echo
fi

echo "==> Authenticating with NPM at $NPM_URL"

TOKEN=$(curl -sf -X POST "$NPM_URL/api/tokens" \
  -H "Content-Type: application/json" \
  -d "{\"identity\":\"$NPM_EMAIL\",\"secret\":\"$NPM_PASS\"}" \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: Authentication failed — check email/password and that NPM is reachable." >&2
  exit 1
fi

echo "  authenticated"

# ── Fetch ──────────────────────────────────────────────────────────────────────

fetch() {
  local endpoint=$1 outfile=$2
  local dest="$OUT_DIR/$outfile"
  # Write raw first so we always have something even if formatting fails
  curl -sf "$NPM_URL/api/$endpoint" -H "Authorization: Bearer $TOKEN" > "$dest"
  # Pretty-print in-place with LF line endings; redact secrets in meta fields
  for py in python3 python py; do
    if command -v "$py" &>/dev/null 2>&1; then
      "$py" -c "
import sys, json, re

REDACT_KEYS = {'dns_provider_credentials', 'letsencrypt_email', 'email'}

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
fetch "nginx/proxy-hosts?expand=certificate,owner,access_list"  proxy-hosts.json
fetch "nginx/redirection-hosts?expand=certificate,owner"        redirection-hosts.json
fetch "nginx/streams"                                           streams.json
fetch "nginx/certificates"                                      certificates.json

echo ""
echo "Done. Review before committing:"
echo "  git diff --stat hosts/nginx01/npm/"
