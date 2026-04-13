# Syncthing Setup

Syncthing runs on `devsbx01` and syncs the Obsidian vault to the Windows PC (`vollminxps`) so
Obsidian on Windows stays up to date with docs generated on Linux.

## What it syncs

| Folder | Linux path | Windows path |
|--------|-----------|--------------|
| Obsidian homelab vault | `~/obsidian/homelab/` | `C:\Users\Scott\Documents\Obsidian Vault\homelab` |

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
  └─ sync-docs-to-vault.sh  → writes to ~/obsidian/homelab/
  └─ enforce-graph-colors.sh → writes to ~/obsidian/homelab/.obsidian/graph.json
        │
        ▼
   Syncthing (devsbx01) ──────────────────► Syncthing (vollminxps)
        │                                         │
   ~/obsidian/homelab/              C:\Users\Scott\Documents\Obsidian Vault\homelab
                                                  │
                                                  ▼
                                           Obsidian (Windows)
```

## Vault is also a git repo

`~/obsidian/homelab/` is tracked in [vollminlab/homelab-obsidian-vault](https://github.com/vollminlab/homelab-obsidian-vault).
Commits are made manually when vault-native content changes (index files, architecture docs, runbooks).
The git remote uses HTTPS auth via the `gh` CLI token.

Syncthing syncs `.git/` along with everything else — the Windows clone is a full git repo too,
but pushes should only come from `devsbx01`.

## Troubleshooting

**New folders not appearing in Obsidian on Windows:**
1. Check Syncthing web UI on devsbx01 — confirm folder shows "Up to Date"
2. If synced but still not visible: reload the vault in Obsidian (Settings → Files and links → Reindex vault, or quit and reopen)

**Sync stuck / out of date:**
```bash
systemctl --user restart syncthing
# Then check UI at http://127.0.0.1:8384
```

**Adding a new device to sync:**
Use the Syncthing web UI on both devices to exchange device IDs and accept the shared folder.
