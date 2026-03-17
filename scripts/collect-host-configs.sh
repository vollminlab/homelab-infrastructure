#!/usr/bin/env bash
# collect-host-configs.sh
#
# Pulls configs from homelab hosts into the repo using a SINGLE SSH session per
# host — one 1Password prompt per host, not one per file.
#
# Each host runs a remote bash script (via sudo bash -s) that discovers and
# streams all needed files in a delimited format; the local parse_remote()
# function writes them into hosts/<host>/.
#
# Run from a terminal where your 1Password SSH agent is active.
# Usage: ./scripts/collect-host-configs.sh [HOST...]
#   Defaults to: pihole1 pihole2 groupme01

set -euo pipefail

# Prepend Windows OpenSSH so git bash uses the System32 ssh that reaches the
# 1Password named pipe agent. No-op on Linux (path won't exist).
export PATH="/c/Windows/System32/OpenSSH:$PATH"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOSTS_DIR="$REPO/hosts"

# ── Local helpers ──────────────────────────────────────────────────────────────

# Parse delimited output from a remote collection script.
#
# Protocol (written by the remote emit() function):
#   <<<FILE local/rel/path>>>
#   <file content>
#   <<<ENDFILE>>>
#
# Writes files under $HOSTS_DIR/$host/, removes files that ended up empty.
parse_remote() {
  local host=$1
  local dest="" rel=""
  while IFS= read -r line; do
    if [[ "$line" == '<<<FILE '* ]]; then
      # Close previous section
      if [[ -n "$dest" ]]; then
        [[ -s "$dest" ]] && echo "  pulled $rel" || rm -f "$dest"
        dest=""
      fi
      rel="${line#<<<FILE }"
      rel="${rel%>>>}"
      dest="$HOSTS_DIR/$host/$rel"
      mkdir -p "$(dirname "$dest")"
      : > "$dest"
    elif [[ "$line" == '<<<ENDFILE>>>' ]]; then
      if [[ -n "$dest" ]]; then
        [[ -s "$dest" ]] && echo "  pulled $rel" || rm -f "$dest"
        dest=""
      fi
    elif [[ -n "$dest" ]]; then
      printf '%s\n' "$line" >> "$dest"
    fi
  done
  # Handle missing final ENDFILE
  if [[ -n "$dest" ]]; then
    [[ -s "$dest" ]] && echo "  pulled $rel" || rm -f "$dest"
  fi
}

# Redact key=value secrets (handles both quoted and unquoted values).
redact_kv() {
  local file=$1; shift
  [[ -f "$file" ]] || return 0
  for key in "$@"; do
    sed -i -E \
      -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*\")([^\"]+)\"|\1REDACTED\"|" \
      -e "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)([^\"\n#][^\n#]*)|\1REDACTED|" \
      "$file"
  done
}

# Remove crontab files that contain only comments/blanks.
prune_empty_crontabs() {
  local host=$1
  for f in "$HOSTS_DIR/$host/crontab-root" "$HOSTS_DIR/$host/crontab-vollmin"; do
    if [[ -f "$f" ]] && ! grep -qv '^#\|^[[:space:]]*$' "$f" 2>/dev/null; then
      rm -f "$f"
    fi
  done
}

# ── pihole1 / pihole2 ─────────────────────────────────────────────────────────
collect_pihole() {
  local host=$1
  echo ""
  echo "==> $host"

  # Single SSH session — all discovery and reading in one sudo bash -s call.
  # Single-quoted heredoc: no local variable expansion inside the script.
  ssh "$host" "sudo bash -s" << 'REMOTE' | parse_remote "$host"
set -euo pipefail

SKIP='^(pihole-FTL|pihole-updateGravity|pihole-logrotate|ssh|cron|rsyslog|syslog|networking|getty|serial-getty|plymouth|display-manager|avahi|wpa_supplicant|systemd-|dbus|apparmor|ufw|snapd|multipathd|iscsi|vmtoolsd|open-vm-tools)'

# emit <local_rel_path> <remote_abs_path>
# Outputs the file wrapped in protocol delimiters; skips missing files.
emit() {
  local rel="$1" path="$2"
  [[ -f "$path" ]] || return 0
  printf '<<<FILE %s>>>\n' "$rel"
  cat "$path"
  printf '\n<<<ENDFILE>>>\n'
}

# Pi-hole configs — TOML and list files ONLY (no databases).
find /etc/pihole -maxdepth 1 \( -name '*.toml' -o -name '*.list' \) -type f 2>/dev/null | sort | \
while IFS= read -r f; do
  emit "configs/pihole/$(basename "$f")" "$f"
done

emit "configs/pihole-flask-api/.env"       "/etc/pihole-flask-api/.env"
emit "configs/keepalived/keepalived.conf"  "/etc/keepalived/keepalived.conf"

# Custom systemd units and timers (skip stock OS/pihole units).
{ ls /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null || true; } | sort | \
while IFS= read -r f; do
  name=$(basename "$f")
  printf '%s\n' "$name" | grep -qE "$SKIP" && continue
  emit "systemd/$name" "$f"
done

# Custom scripts in /usr/local/bin.
{ ls /usr/local/bin/ 2>/dev/null || true; } | sort | \
while IFS= read -r name; do
  f="/usr/local/bin/$name"
  LC_ALL=C grep -qI '' "$f" 2>/dev/null || continue  # skip binaries
  emit "scripts/$name" "$f"
done

emit "fstab" "/etc/fstab"

# Crontabs (running as root, use -u to target each user).
printf '<<<FILE crontab-root>>>\n'
crontab -u root -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'

printf '<<<FILE crontab-vollmin>>>\n'
crontab -u vollmin -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'
REMOTE

  # Redact secrets locally after pulling.
  for toml in "$HOSTS_DIR/$host/configs/pihole/"*.toml; do
    [[ -f "$toml" ]] && redact_kv "$toml" "pwhash"
  done
  redact_kv "$HOSTS_DIR/$host/configs/pihole-flask-api/.env" "PIHOLE_API_KEY"
  local kc="$HOSTS_DIR/$host/configs/keepalived/keepalived.conf"
  [[ -f "$kc" ]] && sed -i -E 's|(auth_pass[[:space:]]+)[^[:space:]#]+|\1REDACTED|g' "$kc"
  prune_empty_crontabs "$host"
}

# pihole1-only: nebula-sync compose project (files owned by vollmin — no sudo needed).
collect_pihole1_extras() {
  echo "  (nebula-sync)"

  ssh pihole1 "sudo bash -s" << 'REMOTE' | parse_remote pihole1
set -euo pipefail
emit() {
  local rel="$1" path="$2"
  [[ -f "$path" ]] || return 0
  printf '<<<FILE %s>>>\n' "$rel"
  cat "$path"
  printf '\n<<<ENDFILE>>>\n'
}
emit "nebula-sync/docker-compose.yml"  "/home/vollmin/nebula-sync/docker-compose.yml"
emit "nebula-sync/.env"                "/home/vollmin/nebula-sync/.env"
REMOTE

  local ns_env="$HOSTS_DIR/pihole1/nebula-sync/.env"
  if [[ -f "$ns_env" ]]; then
    # Redact standard key=value secrets
    redact_kv "$ns_env" \
      ".*[Pp][Aa][Ss][Ss].*" ".*[Tt][Oo][Kk][Ee][Nn].*" \
      ".*[Kk][Ee][Yy].*"     ".*[Ss][Ee][Cc][Rr][Ee][Tt].*"
    # Redact Pi-hole API keys embedded as url|apikey in PRIMARY/REPLICAS
    sed -i -E 's|(PRIMARY=https?://[^|]+\|)[^[:space:]]+|\1REDACTED|' "$ns_env"
    sed -i -E 's|(REPLICAS=https?://[^|]+\|)[^[:space:]]+|\1REDACTED|' "$ns_env"
  fi
}

# ── groupme01 ─────────────────────────────────────────────────────────────────
collect_groupme01() {
  echo ""
  echo "==> groupme01"

  # groupme01 requires a sudo password — run as vollmin and use sudo -n so
  # privileged files are grabbed when NOPASSWD is configured, skipped otherwise.
  ssh groupme01 bash << 'REMOTE' | parse_remote groupme01
set -euo pipefail

SKIP='^(pihole-FTL|pihole-updateGravity|pihole-logrotate|ssh|cron|rsyslog|syslog|networking|getty|serial-getty|plymouth|avahi|wpa_supplicant|systemd-|dbus|apparmor|ufw|snapd|multipathd|iscsi|vmtoolsd|open-vm-tools)'

# Try sudo -n first (non-interactive, instant fail if password needed),
# then fall back to regular cat for world-readable files.
emit() {
  local rel="$1" path="$2"
  local content
  content=$(sudo -n cat "$path" 2>/dev/null) \
    || content=$(cat "$path" 2>/dev/null) \
    || { echo "  SKIPPED (permission denied): $path" >&2; return 0; }
  [[ -z "$content" ]] && return 0
  printf '<<<FILE %s>>>\n' "$rel"
  printf '%s\n' "$content"
  printf '\n<<<ENDFILE>>>\n'
}

emit "fstab" "/etc/fstab"

{ ls /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null || true; } | sort | \
while IFS= read -r f; do
  name=$(basename "$f")
  printf '%s\n' "$name" | grep -qE "$SKIP" && continue
  emit "systemd/$name" "$f"
done

{ ls /usr/local/bin/ 2>/dev/null || true; } | sort | \
while IFS= read -r name; do
  f="/usr/local/bin/$name"
  LC_ALL=C grep -qI '' "$f" 2>/dev/null || continue  # skip binaries
  emit "scripts/$name" "$f"
done

printf '<<<FILE crontab-root>>>\n'
sudo -n crontab -u root -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'

printf '<<<FILE crontab-vollmin>>>\n'
crontab -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'
REMOTE

  prune_empty_crontabs groupme01
}

# ── Generic host (systemd, scripts, fstab, crontabs) ─────────────────────────
collect_generic() {
  local host=$1
  echo ""
  echo "==> $host (generic)"

  ssh "$host" bash << 'REMOTE' | parse_remote "$host"
set -euo pipefail

SKIP='^(ssh|cron|rsyslog|networking|getty|serial-getty|plymouth|avahi|wpa_supplicant|systemd-|dbus|apparmor|ufw|snapd|multipathd)'

emit() {
  local rel="$1" path="$2"
  local content
  content=$(sudo -n cat "$path" 2>/dev/null) \
    || content=$(cat "$path" 2>/dev/null) \
    || { echo "  SKIPPED (permission denied): $path" >&2; return 0; }
  [[ -z "$content" ]] && return 0
  printf '<<<FILE %s>>>\n' "$rel"
  printf '%s\n' "$content"
  printf '\n<<<ENDFILE>>>\n'
}

emit "fstab" "/etc/fstab"

{ ls /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null || true; } | sort | \
while IFS= read -r f; do
  name=$(basename "$f")
  printf '%s\n' "$name" | grep -qE "$SKIP" && continue
  emit "systemd/$name" "$f"
done

{ ls /usr/local/bin/ 2>/dev/null || true; } | sort | \
while IFS= read -r name; do
  f="/usr/local/bin/$name"
  LC_ALL=C grep -qI '' "$f" 2>/dev/null || continue  # skip binaries
  emit "scripts/$name" "$f"
done

printf '<<<FILE crontab-root>>>\n'
sudo -n crontab -u root -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'

printf '<<<FILE crontab-vollmin>>>\n'
crontab -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'
REMOTE

  prune_empty_crontabs "$host"
}

# ── HAProxy hosts ─────────────────────────────────────────────────────────────
# To unlock /etc/haproxy/haproxy.cfg and /etc/keepalived/keepalived.conf,
# add on each host:
#   echo 'vollmin ALL=(ALL) NOPASSWD: /bin/cat /etc/haproxy/haproxy.cfg, /bin/cat /etc/keepalived/keepalived.conf' \
#     | sudo tee /etc/sudoers.d/vollmin-collect && sudo chmod 440 /etc/sudoers.d/vollmin-collect
collect_haproxy() {
  local host=$1
  echo ""
  echo "==> $host"

  ssh "$host" bash << 'REMOTE' | parse_remote "$host"
set -euo pipefail

SKIP='^(ssh|cron|rsyslog|syslog|networking|getty|serial-getty|plymouth|avahi|wpa_supplicant|systemd-|dbus|apparmor|ufw|snapd|multipathd|iscsi|vmtoolsd|open-vm-tools)'

emit() {
  local rel="$1" path="$2"
  local content
  content=$(sudo -n cat "$path" 2>/dev/null) \
    || content=$(cat "$path" 2>/dev/null) \
    || { echo "  SKIPPED (permission denied): $path" >&2; return 0; }
  [[ -z "$content" ]] && return 0
  printf '<<<FILE %s>>>\n' "$rel"
  printf '%s\n' "$content"
  printf '\n<<<ENDFILE>>>\n'
}

emit "configs/haproxy/haproxy.cfg"         "/etc/haproxy/haproxy.cfg"
emit "configs/keepalived/keepalived.conf"  "/etc/keepalived/keepalived.conf"
emit "fstab"                               "/etc/fstab"

{ ls /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null || true; } | sort | \
while IFS= read -r f; do
  name=$(basename "$f")
  printf '%s\n' "$name" | grep -qE "$SKIP" && continue
  emit "systemd/$name" "$f"
done

{ ls /usr/local/bin/ 2>/dev/null || true; } | sort | \
while IFS= read -r name; do
  f="/usr/local/bin/$name"
  LC_ALL=C grep -qI '' "$f" 2>/dev/null || continue  # skip binaries
  emit "scripts/$name" "$f"
done

printf '<<<FILE crontab-root>>>\n'
sudo -n crontab -u root -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'

printf '<<<FILE crontab-vollmin>>>\n'
crontab -l 2>/dev/null || true
printf '\n<<<ENDFILE>>>\n'
REMOTE

  local kc="$HOSTS_DIR/$host/configs/keepalived/keepalived.conf"
  [[ -f "$kc" ]] && sed -i -E 's|(auth_pass[[:space:]]+)[^[:space:]#]+|\1REDACTED|g' "$kc"
  # Redact HAProxy stats passwords: "stats auth user:password"
  local hc="$HOSTS_DIR/$host/configs/haproxy/haproxy.cfg"
  [[ -f "$hc" ]] && sed -i -E 's|(stats auth[[:space:]]+[^:]+:)[^[:space:]]+|\1REDACTED|g' "$hc"
  prune_empty_crontabs "$host"
}

# ── nginx01 ───────────────────────────────────────────────────────────────────
# NPM proxy configs live in MariaDB — collect via scripts/collect-npm-configs.sh.
# This captures the docker-compose and host-level files only.
collect_nginx01() {
  echo ""
  echo "==> nginx01"

  # nginx01 runs NPM via docker-compose (already committed to repo manually).
  # Only world-readable files are collected here — no sudo needed.
  # NPM proxy configs live in MariaDB; use scripts/collect-npm-configs.sh for those.
  ssh nginx01 bash << 'REMOTE' | parse_remote nginx01
set -euo pipefail

SKIP='^(ssh|cron|rsyslog|syslog|networking|getty|serial-getty|plymouth|avahi|wpa_supplicant|systemd-|dbus|apparmor|ufw|snapd|multipathd|iscsi|vmtoolsd|open-vm-tools)'

emit() {
  local rel="$1" path="$2"
  local content
  content=$(cat "$path" 2>/dev/null) || return 0
  [[ -z "$content" ]] && return 0
  printf '<<<FILE %s>>>\n' "$rel"
  printf '%s\n' "$content"
  printf '\n<<<ENDFILE>>>\n'
}

emit "docker-compose.yml"  "/home/vollmin/nginx-proxy-manager/docker-compose.yml"
emit "fstab"               "/etc/fstab"

{ ls /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null || true; } | sort | \
while IFS= read -r f; do
  name=$(basename "$f")
  printf '%s\n' "$name" | grep -qE "$SKIP" && continue
  emit "systemd/$name" "$f"
done

{ ls /usr/local/bin/ 2>/dev/null || true; } | sort | \
while IFS= read -r name; do
  f="/usr/local/bin/$name"
  LC_ALL=C grep -qI '' "$f" 2>/dev/null || continue  # skip binaries
  emit "scripts/$name" "$f"
done
REMOTE
}

# ── UDM SE ────────────────────────────────────────────────────────────────────
collect_udm() {
  echo ""
  echo "==> udm"

  local dest="$HOSTS_DIR/udm"
  mkdir -p "$dest"

  # Pull current network config (symlink resolves to active versioned file).
  # Running as root — no sudo needed.
  local raw="$dest/udapi-net-cfg.json.raw"
  ssh -n udm "cat /data/udapi-config/udapi-net-cfg.json" > "$raw"

  # Redact sensitive fields and pretty-print using Python.
  # Keys seen in config: password, secret. Also redact common UniFi WiFi keys.
  local py_script='
import sys, json

REDACT = {"password","secret","x_passphrase","x_wpa_psk","x_password","private_key"}

def redact(obj):
    if isinstance(obj, dict):
        return {k: "REDACTED" if k in REDACT else redact(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(i) for i in obj]
    return obj

with open(sys.argv[1]) as f:
    data = json.load(f)
with open(sys.argv[2], "w") as f:
    json.dump(redact(data), f, indent=2)
    f.write("\n")
'
  local ok=false
  for py in python3 python py; do
    if command -v "$py" &>/dev/null 2>&1; then
      "$py" -c "$py_script" "$raw" "$dest/udapi-net-cfg.json" 2>/dev/null && ok=true && break
    fi
  done

  rm -f "$raw"

  if $ok; then
    echo "  pulled udapi-net-cfg.json (redacted)"
  else
    echo "  WARNING: Python not found — skipping UDM config (install Python and re-run)" >&2
  fi
}

# ── Pi-hole sync verification ─────────────────────────────────────────────────
verify_pihole_sync() {
  local p1="$HOSTS_DIR/pihole1"  p2="$HOSTS_DIR/pihole2"
  [[ -d "$p1" && -d "$p2" ]] || return 0

  echo ""
  echo "==> Verifying pihole1 vs pihole2 sync"

  # fstab excluded: different hardware means different PARTUUIDs — expected.
  local skip="keepalived|nebula-sync|fstab"
  local drift=0

  while IFS= read -r -d '' f1; do
    local rel="${f1#$p1/}"
    echo "$rel" | grep -qE "$skip" && continue
    local f2="$p2/$rel"
    if [[ ! -f "$f2" ]]; then
      echo "  MISSING on pihole2: $rel"
      drift=1
    elif ! diff -q \
        <(grep -vE '^\s*#.*Last updated|app_pwhash' "$f1") \
        <(grep -vE '^\s*#.*Last updated|app_pwhash' "$f2") \
        >/dev/null 2>&1; then
      echo "  DRIFT: $rel"
      diff --unified=2 "$f1" "$f2" | grep -vE '^\s*[+-].*Last updated|^\s*[+-].*app_pwhash' | sed 's/^/    /' || true
      drift=1
    fi
  done < <(find "$p1" -type f -print0)

  if [[ $drift -eq 0 ]]; then
    echo "  OK — configs are in sync (keepalived and nebula-sync excluded)"
  else
    echo ""
    echo "  WARNING: Drift detected. Investigate before committing."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  HOSTS=(pihole1 pihole2 groupme01 haproxy01 haproxy02 haproxydmz01 haproxydmz02 nginx01 udm)
else
  HOSTS=("$@")
fi

for host in "${HOSTS[@]}"; do
  {
    case "$host" in
      pihole1)
        collect_pihole pihole1
        collect_pihole1_extras
        ;;
      pihole2)
        collect_pihole pihole2
        ;;
      groupme01)
        collect_groupme01
        ;;
      haproxy01|haproxy02|haproxydmz01|haproxydmz02)
        collect_haproxy "$host"
        ;;
      nginx01)
        collect_nginx01
        ;;
      udm)
        collect_udm
        ;;
      *)
        collect_generic "$host"
        ;;
    esac
  } || echo "  ERROR: collection failed for $host — skipping" >&2
done

if [[ " ${HOSTS[*]} " == *" pihole1 "* && " ${HOSTS[*]} " == *" pihole2 "* ]]; then
  verify_pihole_sync
fi

echo ""
echo "Done. Review before committing:"
echo "  git diff --stat"
echo "  git diff"
