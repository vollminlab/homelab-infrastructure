# Syncthing Setup

Syncthing runs on `devsbx01` and syncs the Obsidian vault to other devices so Obsidian stays up to date with docs generated on Linux.

## What it syncs

| Folder ID | Linux path | Purpose |
|-----------|-----------|---------|
| homelab-vault | `~/repos/vollminlab/homelab-obsidian-vault` | Obsidian vault (IS the git repo) |

**Windows path (vollminxps):** `C:\Users\Scott\Documents\Obsidian Vault\homelab`

Note: `~/obsidian/homelab/` is a separate, stale directory — not watched by Syncthing.

## Service management (devsbx01)

```bash
# Status
systemctl --user status syncthing

# Restart
systemctl --user restart syncthing

# Web UI (browser on devsbx01 or via SSH tunnel)
http://127.0.0.1:8384
```

## Sync flow

```
devsbx01 cron (every 5 min)
  └─ sync-docs-to-vault.sh  → writes to ~/repos/vollminlab/homelab-obsidian-vault/
  └─ enforce-graph-colors.sh → writes to .obsidian/graph.json
        │
        ▼
   Syncthing (devsbx01) ──────────────────► Syncthing (vollminxps) [Windows PC — always on]
                                                     │
                                              Obsidian Sync (cloud)
                                              ┌──────┴──────┐
                                           Laptop         Mobile
```

## Adding a new device

1. Install SyncTrayzor (Windows) or Syncthing on the new device
2. Get the device ID from its Syncthing UI (Actions → Show ID)
3. On devsbx01, go to http://127.0.0.1:8384 → Add Remote Device → paste the ID
4. On the new device, accept the connection request
5. On devsbx01, share the `homelab-vault` folder with the new device
6. On the new device, accept the folder share and set the local path

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
