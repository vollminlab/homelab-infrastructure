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
3. Restore pihole-flask-api systemd unit (`hosts/pihole1/systemd/pihole-flask-api.service` or `pihole2` as appropriate — runs on both hosts) and retrieve the API token from 1Password (`op read "op://Homelab/Recordimporter/credential"`)
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

### Lessons learned from pihole2 migration

These were discovered during the actual pihole2 migration and must be followed for pihole1:

- **The SD card reads at ~6 MB/s** — cloning 119GB takes ~5.5 hours. Plan accordingly and keep the SSH session alive (laptop plugged in, lid open). Do not interrupt dd.
- **Do not run the Argon eeprom script before the clone is complete and verified.** The eeprom script sets NVMe as the boot device immediately. If the NVMe isn't ready, you'll boot into initramfs with no SSH access and have to fix it manually via keyboard/monitor.
- **The `dd` clone creates duplicate PARTUUIDs** — both SD and NVMe will have identical PARTUUIDs. This causes boot ambiguity. After cloning, you must assign a new UUID to the NVMe root partition with `tune2fs -U random` and update both `cmdline.txt` and `/etc/fstab` before running the eeprom script.
- **`growpart` is not installed by default** — install with `sudo apt install -y cloud-guest-utils` before running it.
- **`resize2fs` requires `e2fsck -f` first** if the partition hasn't been booted — run fsck before attempting resize.
- **nebula-sync runs on pihole1 only** — pihole2 does not need it. If a nebula-sync container exists on pihole2, remove it (`sudo docker stop nebula-sync && sudo docker rm nebula-sync`).
- **The Argon NEO 5 M.2 case makes the SD card inaccessible** — do not plan to remove it. Leave the SD card in as a fallback boot device.
- **`argonone-uninstall` will fail** on the NEO 5 M.2 — ignore it, it's for a different case model.

### Additional lessons learned from pihole1 migration

- **Static IP is set via NetworkManager**, not dhcpcd or netplan. The connection profile is at `/etc/NetworkManager/system-connections/RPI Pi-Hole Connection.nmconnection`. When cloning pihole2 → pihole1, copy pihole1's nmconnection file to the NVMe root and remove pihole2's (`Wired connection 1.nmconnection`) before first boot.
- **`authorized_keys` comes from the clone** — after first NVMe boot, pihole1 will have pihole2's authorized key and reject your normal SSH key. Fix by using pihole2's key to add pihole1's key: `ssh -i ~/.ssh/pihole2_id_rsa.pub vollmin@192.168.100.2 "echo '$(cat ~/.ssh/pihole1_id_rsa.pub)' >> ~/.ssh/authorized_keys"`
- **nebula-sync `app_sudo` required on replicas (Pi-hole v6)** — pihole2 needs `webserver.api.app_sudo = true` for nebula-sync to import configs. Set it with `sudo pihole-FTL --config webserver.api.app_sudo true` on pihole2. Without this, nebula-sync will authenticate successfully but get 403 on the teleporter endpoint.
- **Network clone (pihole2 NVMe → pihole1 NVMe) runs at ~48 MB/s** — 238GB takes ~85 minutes. Significantly faster than SD card clone. Run via a temp SSH key rather than trying to pipe through a Windows intermediary host.
- **Pi-hole app password must be reset after clone** — the clone brings pihole2's Pi-hole database including its app password hash. nebula-sync will get 401 on pihole1 until you reset the pihole1 admin password via the web UI and update the PRIMARY credential in `~/nebula-sync/.env` and 1Password.

---

### Phase 1 — Migrate pihole2

> **pihole2 is already complete.** This section is kept for reference. Proceed to Phase 2 for pihole1.

pihole1 holds the VIP and serves DNS throughout. pihole2 is offline only during its reboot.

1. **Build the Argon case** — assemble pihole2's Pi 5 into the Argon NEO 5 M.2 case with the NVMe installed. The SD card remains in place (case makes removal difficult — leave it as fallback).

2. **Boot pihole2 from SD as normal**, verify it's up and wait for load average to settle below 1.0 (fsck may run on first boot after case reassembly):
   ```bash
   ssh pihole2 "uptime && lsblk"
   ```
   Confirm `nvme0n1` is visible before proceeding.

3. **Clone SD → NVMe** (run on pihole2). Takes ~5.5 hours at SD card read speeds. Keep SSH session alive:
   ```bash
   sudo dd if=/dev/mmcblk0 of=/dev/nvme0n1 bs=4M status=progress
   ```
   Verify completion — partition sizes must match:
   ```bash
   lsblk
   # nvme0n1p2 must show ~118.9GB, not 5.5GB
   sudo fsck.ext4 -n /dev/nvme0n1p2  # file/block counts must match SD
   sudo fsck.ext4 -n /dev/mmcblk0p2
   ```

4. **Fix the NVMe filesystem** (journal cleanup from clone):
   ```bash
   sudo apt install -y cloud-guest-utils
   sudo fsck.ext4 -f -y /dev/nvme0n1p2
   ```

5. **Expand the root partition**:
   ```bash
   sudo growpart /dev/nvme0n1 2
   sudo resize2fs /dev/nvme0n1p2
   df -h /  # verify ~235GB
   ```

6. **Assign a unique UUID to the NVMe root** (critical — avoids PARTUUID conflict with SD card):
   ```bash
   sudo tune2fs -U random /dev/nvme0n1p2
   sudo blkid /dev/nvme0n1p2  # note the new UUID
   ```

7. **Update NVMe cmdline.txt** to use the new UUID:
   ```bash
   # /boot/firmware is mounted from nvme0n1p1 at this point
   NEW_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p2)
   sudo sed -i "s|root=PARTUUID=cb0aa740-02|root=UUID=$NEW_UUID|" /boot/firmware/cmdline.txt
   cat /boot/firmware/cmdline.txt  # verify
   ```

8. **Update NVMe fstab** to use the new UUID:
   ```bash
   sudo mkdir /mnt/nvmeroot
   sudo mount /dev/nvme0n1p2 /mnt/nvmeroot
   sudo sed -i "s|PARTUUID=cb0aa740-02|UUID=$NEW_UUID|" /mnt/nvmeroot/etc/fstab
   cat /mnt/nvmeroot/etc/fstab  # verify
   sudo umount /mnt/nvmeroot
   ```

9. **Run the Argon eeprom script** (sets NVMe boot priority — only run after steps 6–8 are complete):
   ```bash
   curl https://download.argon40.com/argon-eeprom.sh | bash
   sudo reboot
   ```

10. **After reboot**, verify booting from NVMe:
    ```bash
    findmnt /  # must show /dev/nvme0n1p2
    ```

11. **Run the Argon NEO 5 fan control script**:
    ```bash
    curl https://download.argon40.com/argonneo5.sh | bash
    sudo reboot
    ```

12. **Upgrade** while staged:
    ```bash
    sudo apt update && sudo apt upgrade -y && sudo apt autoremove -y
    sudo pihole -up
    sudo reboot
    ```

13. **Verify pihole2 is healthy on NVMe**:
    ```bash
   ssh pihole2 "lsblk && sudo systemctl status keepalived --no-pager && sudo systemctl status pihole-flask-api --no-pager"
   ```
   Confirm root is mounted on `nvme0n1p2`, not `mmcblk0p2`.

---

### Phase 2 — Migrate pihole1

Fail over to pihole2 first. pihole2 (NVMe) handles all DNS while pihole1 is migrated. The failing SD card is no longer load-bearing.

1. **Fail over to pihole2**:
   ```bash
   export PATH="/c/Windows/System32/OpenSSH:$PATH"
   ssh pihole1 "sudo systemctl stop keepalived"
   ssh pihole2 "ip addr show | grep 192.168.100.4"  # confirm pihole2 holds VIP
   ```

2. **Build the Argon case** — assemble pihole1's Pi 5 into the second Argon NEO 5 M.2 case with the NVMe installed. Leave SD card in place.

3. **Boot pihole1 from its SD card**. It may log I/O errors — that's fine, we just need SSH access.

4. **Clone pihole2's NVMe → pihole1's NVMe over the network** (much faster than SD card clone — NVMe read speeds). Run on pihole1:
   ```bash
   ssh pihole2 "sudo dd if=/dev/nvme0n1 bs=4M | gzip -1" | gunzip | sudo dd of=/dev/nvme0n1 bs=4M status=progress
   ```
   Verify completion:
   ```bash
   lsblk  # nvme0n1p2 must show ~235GB
   sudo fsck.ext4 -n /dev/nvme0n1p2
   ```

5. **Fix NVMe filesystem**:
   ```bash
   sudo fsck.ext4 -f -y /dev/nvme0n1p2
   ```

6. **Assign a unique UUID to pihole1's NVMe root**:
   ```bash
   sudo tune2fs -U random /dev/nvme0n1p2
   NEW_UUID=$(sudo blkid -s UUID -o value /dev/nvme0n1p2)
   ```

7. **Update NVMe cmdline.txt**:
   ```bash
   sudo sed -i "s|root=UUID=64961cb6-1ef9-4ed4-991a-3e20ffbd70cb|root=UUID=$NEW_UUID|" /boot/firmware/cmdline.txt
   cat /boot/firmware/cmdline.txt  # verify
   ```

8. **Update NVMe fstab**:
   ```bash
   sudo mkdir /mnt/nvmeroot
   sudo mount /dev/nvme0n1p2 /mnt/nvmeroot
   sudo sed -i "s|UUID=64961cb6-1ef9-4ed4-991a-3e20ffbd70cb|UUID=$NEW_UUID|" /mnt/nvmeroot/etc/fstab
   cat /mnt/nvmeroot/etc/fstab  # verify
   sudo umount /mnt/nvmeroot
   ```

9. **Run Argon eeprom script** (only after steps 6–8 complete):
   ```bash
   curl https://download.argon40.com/argon-eeprom.sh | bash
   sudo reboot
   ```

10. **Verify booting from NVMe**:
    ```bash
    findmnt /  # must show /dev/nvme0n1p2
    ```

11. **Run Argon NEO 5 fan control script**:
    ```bash
    curl https://download.argon40.com/argonneo5.sh | bash
    sudo reboot
    ```

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

---

## Pi-hole v6 configuration notes

### Session timeout (homepage widget fix)

Pi-hole v6 defaults to a 1800-second (30 min) session timeout. The homepage Pi-hole widget does not re-authenticate when the session expires, causing the widget to show "Failed to authenticate" every 30 minutes until the homepage pod is restarted.

**Fix applied 2026-04-17** — session timeout set to 0 (no expiry) on both Pi-holes:
```bash
sudo pihole-FTL --config webserver.session.timeout 0
```

This setting is not exposed in the Pi-hole v6 web UI — it must be set via the CLI or the API (requires a web-password session, not an app-password session).

If either Pi-hole is rebuilt or the config is reset, this must be re-applied.

### app_sudo for nebula-sync

pihole2 requires `webserver.api.app_sudo = true` for nebula-sync to import configs from pihole1. Without it, nebula-sync authenticates successfully but gets 403 on the teleporter endpoint.

```bash
sudo pihole-FTL --config webserver.api.app_sudo true
```
