# Syncthing Setup

Syncthing runs on `devsbx01` and syncs the Obsidian vault to the Windows PC (`GLaDOS`) so it serves as the always-on relay for Obsidian Sync.

## What it syncs

| Folder ID | Linux path | Windows path (GLaDOS) |
|-----------|-----------|----------------------|
| homelab-vault | `~/repos/vollminlab/homelab-obsidian-vault` | `C:\Users\Scott\Documents\Obsidian Vault\homelab` |

## Device inventory

| Device | Role | Syncthing |
|--------|------|-----------|
| devsbx01 | Linux dev VM — vault source | Always on, runs cron |
| GLaDOS | Windows PC — always-on relay | **Needs setup** (see below) |
| vollminxps | Laptop — not always on | **Remove from Syncthing** once GLaDOS is set up; use Obsidian Sync instead |

Note: `~/obsidian/homelab/` is a separate stale directory — not watched by Syncthing.

## Intended sync flow

```
devsbx01 cron (every 5 min)
  └─ sync-docs-to-vault.sh + enforce-graph-colors.sh
        │
        ▼
   Syncthing (devsbx01) ─────────────────► Syncthing (GLaDOS) [Windows PC — always on]
                                                    │
                                             Obsidian Sync (cloud)
                                          ┌─────────┴─────────┐
                                     vollminxps (laptop)    Mobile
```

## Service management (devsbx01)

```bash
# Status
systemctl --user status syncthing

# Restart
systemctl --user restart syncthing

# Web UI (browser on devsbx01 or via SSH tunnel)
http://127.0.0.1:8384
```

## Setting up GLaDOS (one-time)

**devsbx01 device ID:** `LCMBZJE-WWJQ3MM-P7M37A2-QGOW777-NE67R72-BLXFRB7-O4IURUL-FR7ZJQO`

1. Install [SyncTrayzor](https://github.com/canton7/SyncTrayzor/releases) on GLaDOS
2. In SyncTrayzor: Add Remote Device → paste devsbx01's device ID above
3. On devsbx01 Syncthing UI (http://127.0.0.1:8384): accept the connection request from GLaDOS
4. On devsbx01: share the `Homelab Obsidian Vault` folder with GLaDOS
5. On GLaDOS: accept the folder share, set path to `C:\Users\Scott\Documents\Obsidian Vault\homelab`
6. Verify GLaDOS shows "Up to Date" in the Syncthing UI
7. Set up Obsidian on GLaDOS to open the vault at that path
8. Enable Obsidian Sync on GLaDOS — this pushes to vollminxps and mobile

## Removing vollminxps from Syncthing (after GLaDOS is set up)

1. On devsbx01: Syncthing UI → Devices → vollminxps → Remove
2. On vollminxps: unshare or uninstall SyncTrayzor
3. vollminxps gets the vault via Obsidian Sync from GLaDOS instead

## .stignore (what Syncthing skips)

```
.git
.obsidian/graph.json
```

`repos/*/docs/` and `repos/*/diagrams/` are gitignored in the vault repo but NOT excluded from Syncthing — they sync to all devices normally.

## Troubleshooting

**New folders not appearing in Obsidian:**
1. Check Syncthing web UI on devsbx01 — confirm folder shows "Up to Date"
2. If synced but still not visible: reload vault in Obsidian (Settings → Files and links → Reindex vault)

**Sync stuck / out of date:**
```bash
systemctl --user restart syncthing
# Then check UI at http://127.0.0.1:8384
```
