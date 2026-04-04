# Pi-hole Hardware Diagnostics

pihole1 has shown signs of potential SD card degradation (observed issues with `lsblk`). This runbook covers how to assess the storage health and decide on a remediation path before it causes an unplanned outage.

> **Context:** Both Pi-holes run `log2ram` to reduce SD card write wear by keeping logs in RAM. Its presence means SD card longevity has already been a concern. A degraded card can manifest as read errors, filesystem going read-only, or silent data corruption.

---

## Run diagnostics

SSH to pihole1:
```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"
ssh pihole1
```

### 1. Block device layout
```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL
```
Note the SD card device name (typically `/dev/mmcblk0`) and any unusual output.

### 2. Kernel I/O errors
```bash
sudo dmesg | grep -iE "i/o error|mmc|ext4-fs error|buffer i/o|reset"
```
Any hits here indicate the SD card is throwing hardware errors. Even one `I/O error` on `mmcblk0` is significant.

### 3. Boot-time errors
```bash
sudo journalctl -p err -b
```
Look for filesystem errors, failed mounts, or storage-related service failures on the most recent boot.

### 4. Filesystem read-only check
```bash
mount | grep " ro,"
```
If the root or data partition shows `ro` (read-only), the kernel has already remounted it to protect against corruption — this is a serious sign.

### 5. Disk and inode usage
```bash
df -h
df -i
```
An SD card that's nearly full accelerates wear and can cause write failures.

### 6. SMART data (if available)
```bash
sudo smartctl -a /dev/mmcblk0 2>/dev/null || echo "smartctl not available or not supported for SD"
```
SD cards often don't expose SMART data, but worth trying.

### 7. Filesystem error count
```bash
sudo tune2fs -l /dev/mmcblk0p2 2>/dev/null | grep -E "Mount count|Check interval|Filesystem errors"
```
Adjust partition number (`p2`) to match the root partition from `lsblk` output.

---

## Interpret results

| Finding | Severity | Action |
|---------|----------|--------|
| No errors in dmesg, mount, or journalctl | Low | Defer — monitor |
| Inode/disk usage >80% | Medium | Free space or expand storage |
| Occasional I/O errors in dmesg, no read-only | Medium | Plan replacement soon |
| Filesystem errors count > 0 in tune2fs | Medium–High | Replace before next maintenance window |
| Root filesystem mounted read-only | High | Replace immediately; pihole1 may be unreliable |
| Repeated I/O errors in dmesg | High | Replace immediately |

---

## Remediation options

### Option A — Replace SD card (minimal cost)
- Buy a higher-endurance SD card (e.g., Samsung Pro Endurance or SanDisk High Endurance — these are rated for continuous writes unlike standard cards)
- Clone the current card: `sudo dd if=/dev/mmcblk0 of=/path/to/backup.img bs=4M status=progress` (if card is still readable)
- Flash new card, restore image, verify boot
- **Cost:** ~$15–25. Best if the Pi hardware is otherwise healthy.

### Option B — USB/SSD boot (recommended long-term)
- Most Raspberry Pi 4 models support USB boot
- Use a small USB SSD or flash drive (e.g., Samsung T7 or a cheap USB 3 flash drive)
- SD cards are not designed for the write patterns of a continuously-running server; USB SSD removes this failure class entirely
- Procedure: enable USB boot in Pi bootloader, flash OS to USB drive, migrate config
- **Cost:** ~$15–40 for a USB SSD or quality flash drive

### Option C — Defer (if no active errors)
- Continue running with log2ram in place
- Set a reminder to re-evaluate before the next maintenance window
- **Risk:** SD card failure is unplanned; pihole1 goes down without warning; pihole2 becomes sole DNS until pihole1 is restored

---

## After hardware replacement

If pihole1 is rebuilt or the SD card is replaced:

1. Restore `pihole.toml` from this repo (`hosts/pihole1/configs/pihole/pihole.toml`)
2. Restore keepalived config (`hosts/pihole1/configs/keepalived/keepalived.conf`)
3. Restore pihole-flask-api systemd unit (`hosts/pihole1/systemd/pihole-flask-api.service` or `pihole2` as appropriate — runs on both hosts) and retrieve the API token from 1Password (`op read "op://Homelab/recordimporter-api-token/password"`)
4. Restore nebula-sync: copy `hosts/pihole1/nebula-sync/docker-compose.yml`, create `.env` from 1Password, `docker compose up -d`
5. Regenerate TLS cert — see [pihole-tls.md](pihole-tls.md)
6. Verify VRRP failover works correctly before closing out

---

## NVMe migration plan (Argon NEO 5 M.2)

Migrate both Pi-holes from SD card to NVMe without a DNS outage. VRRP keeps one unit serving DNS at all times throughout.

**Hardware:** Argon NEO 5 M.2 NVMe case × 2 (includes 256GB NVMe and 27W PSU).

**Order matters:** Migrate pihole2 first (healthy card, safe to clone). Once pihole2 is on NVMe, it becomes the stable base for pihole1's migration.

---

### Pre-migration checks

```bash
export PATH="/c/Windows/System32/OpenSSH:$PATH"
# Confirm pihole1 holds the VIP
ssh pihole1 "ip addr show | grep 192.168.100.4"
# Confirm keepalived is running on both
ssh pihole1 "sudo systemctl status keepalived --no-pager"
ssh pihole2 "sudo systemctl status keepalived --no-pager"
```

If pihole1 does not hold the VIP, restart keepalived so it reclaims MASTER before proceeding:
```bash
ssh pihole1 "sudo systemctl start keepalived"
```

**Cleanup check** — remove the retired `orbital-sync` directory from both hosts if present (it was replaced by nebula-sync and has no running service):
```bash
ssh pihole1 "ls ~/orbital-sync 2>/dev/null && echo 'present' || echo 'already gone'"
ssh pihole2 "ls ~/orbital-sync 2>/dev/null && echo 'present' || echo 'already gone'"
# Remove if present:
ssh pihole1 "rm -rf ~/orbital-sync"
ssh pihole2 "rm -rf ~/orbital-sync"
```

**Capture nebula-sync .env variable names** before migration so you know what to reconstruct:
```bash
ssh pihole1 "grep -o '^[^=]*' ~/nebula-sync/.env"
```
The API credentials are stored in 1Password as **Pihole1** and **Pihole2** (API Credential type, Homelab vault).

---

### Phase 1 — Migrate pihole2

pihole1 holds the VIP and serves DNS throughout. pihole2 is offline only during its reboot.

1. **Build the Argon case** — assemble pihole2's Pi 5 into the Argon NEO 5 M.2 case with the NVMe installed. The SD card slot remains accessible.

2. **Boot pihole2 from SD as normal**, verify it's up:
   ```bash
   ssh pihole2 "uptime"
   ```

3. **Clone SD → NVMe** (run on pihole2):
   ```bash
   sudo dd if=/dev/mmcblk0 of=/dev/nvme0n1 bs=4M status=progress
   ```
   This takes ~5–10 minutes. pihole2 stays live throughout.

4. **Expand the root partition** to use the full 256GB (run on pihole2):
   ```bash
   sudo growpart /dev/nvme0n1 2
   sudo resize2fs /dev/nvme0n1p2
   ```

5. **Set boot order to prefer NVMe** (run on pihole2):
   ```bash
   sudo raspi-config
   # Advanced Options → Boot Order → NVMe/USB Boot
   ```
   Or non-interactively:
   ```bash
   sudo rpi-eeprom-config --edit
   # Set: BOOT_ORDER=0xf416  (NVMe first, then USB, then SD)
   ```

6. **Power off pihole2**:
   ```bash
   sudo poweroff
   ```
   pihole1 now handles all DNS. Verify:
   ```bash
   ping 192.168.100.4
   ```

7. **Remove the SD card from pihole2**, power it back on. It should boot from NVMe.

8. **Verify pihole2 is healthy on NVMe**:
   ```bash
   ssh pihole2 "lsblk && sudo systemctl status keepalived --no-pager && sudo systemctl status pihole-flask-api --no-pager"
   ```
   Confirm root is mounted on `nvme0n1p2`, not `mmcblk0p2`.

---

### Phase 2 — Migrate pihole1

Fail over to pihole2 first. pihole2 (NVMe) handles all DNS while pihole1 is migrated. The failing SD card is no longer load-bearing.

1. **Fail over to pihole2**:
   ```bash
   ssh pihole1 "sudo systemctl stop keepalived"
   ssh pihole2 "ip addr show | grep 192.168.100.4"  # confirm pihole2 holds VIP
   ```

2. **Build the Argon case** — assemble pihole1's Pi 5 into the second Argon NEO 5 M.2 case with the NVMe installed.

3. **Boot pihole1 from its SD card** (last time). It may be slow or log I/O errors — that's fine, we just need it up long enough to run the clone.

4. **Clone pihole2's NVMe → pihole1's NVMe over SSH** (run on pihole1):
   ```bash
   ssh pihole2 "sudo dd if=/dev/nvme0n1 bs=4M | gzip -1" | gunzip | sudo dd of=/dev/nvme0n1 bs=4M status=progress
   ```
   This pulls pihole2's full disk image over the network. Takes ~15–25 minutes depending on link speed.

5. **Set boot order to prefer NVMe** (run on pihole1):
   ```bash
   sudo raspi-config
   # Advanced Options → Boot Order → NVMe/USB Boot
   ```

6. **Power off pihole1, remove the SD card**, power back on. It boots from NVMe with pihole2's config — needs adjustments before going live.

---

### Phase 2 continued — Fix pihole1 config post-clone

pihole1 has booted with pihole2's identity. Fix each difference:

**Hostname:**
```bash
sudo hostnamectl set-hostname pihole1
sudo sed -i 's/pihole2/pihole1/g' /etc/hosts
```

**Static IP** — find and update the network config (check which is in use):
```bash
# Check which config sets the static IP
grep -r "192.168.100.3" /etc/dhcpcd.conf /etc/network/interfaces /etc/systemd/network/ 2>/dev/null
# Update 192.168.100.3 → 192.168.100.2 in whichever file owns it
```

**keepalived** — restore from repo (priority 10, MASTER):
```bash
sudo cp /path/to/repo/hosts/pihole1/configs/keepalived/keepalived.conf /etc/keepalived/keepalived.conf
```
Or copy the file from your local machine:
```bash
# From Windows
export PATH="/c/Windows/System32/OpenSSH:$PATH"
scp c:/git/homelab-infrastructure/hosts/pihole1/configs/keepalived/keepalived.conf pihole1:/tmp/
ssh pihole1 "sudo cp /tmp/keepalived.conf /etc/keepalived/keepalived.conf"
```

**Regenerate SSH host keys** (pihole1 currently has pihole2's keys — this will cause a host key warning):
```bash
sudo rm /etc/ssh/ssh_host_*
sudo dpkg-reconfigure openssh-server
sudo systemctl restart ssh
```
After this, clear the old key from your Windows known_hosts:
```bash
ssh-keygen -R 192.168.100.2
```

**Reboot** to apply hostname and IP changes:
```bash
sudo reboot
```

**Set up nebula-sync** (runs on pihole1 only — not present on pihole2's clone):
```bash
ssh pihole1
mkdir -p ~/nebula-sync
# Copy docker-compose.yml from repo (already at hosts/pihole1/nebula-sync/docker-compose.yml)
export PATH="/c/Windows/System32/OpenSSH:$PATH"
scp c:/git/homelab-infrastructure/hosts/pihole1/nebula-sync/docker-compose.yml pihole1:~/nebula-sync/
# Reconstruct .env using 1Password credentials (Pihole1 and Pihole2, API Credential type, Homelab vault)
# Check the variable names captured in pre-migration, then populate:
ssh pihole1
cd ~/nebula-sync
# Fill .env with the variable names from pre-migration capture, values from:
#   op read "op://Homelab/Pihole1/credential"
#   op read "op://Homelab/Pihole2/credential"
nano .env
sudo docker compose up -d
sudo docker ps | grep nebula-sync
```

---

### Post-migration verification

Run on both hosts:
```bash
ssh pihole1 "lsblk | grep nvme && sudo systemctl is-active keepalived pihole-flask-api"
ssh pihole2 "lsblk | grep nvme && sudo systemctl is-active keepalived pihole-flask-api"
```

Verify VIP and DNS:
```bash
ssh pihole1 "ip addr show | grep 192.168.100.4"  # pihole1 should hold VIP as MASTER
dig @192.168.100.4 vollminlab.com
```

Verify nebula-sync:
```bash
ssh pihole1 "docker ps | grep nebula-sync"
```

Verify NVMe health (no errors on either host):
```bash
ssh pihole1 "sudo dmesg | grep -iE 'nvme|i/o error'"
ssh pihole2 "sudo dmesg | grep -iE 'nvme|i/o error'"
```
