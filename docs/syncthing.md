# Syncthing Setup

Syncthing runs on `devsbx01` and syncs the Obsidian vault to the Windows PC (`GLaDOS`) so it serves as the always-on relay for Obsidian Sync.

## What it syncs

| Folder ID | Linux path | Windows path (GLaDOS) |
|-----------|-----------|----------------------|
| homelab-vault | `~/repos/vollminlab/homelab-obsidian-vault` | `C:\Users\Scott\Documents\Obsidian Vault\homelab` |

## Device inventory

| Device | Role | Status in `~/.local/state/syncthing/config.xml` on devsbx01 |
|--------|------|-------------------------------------------------------------|
| devsbx01 | Linux dev VM — vault source | Configured; shares `homelab-vault`. Always on, runs cron |
| GLaDOS | Windows PC — always-on relay | **Configured and sharing `homelab-vault`** — the setup below is already done |
| vollminxps | Laptop — not always on | Still a configured *device*, but **no longer shares `homelab-vault`** — it gets the vault through Obsidian Sync |

`homelab-vault` is shared with exactly two devices: devsbx01 and GLaDOS. There is a second folder,
`default` (`~/Sync`), shared with devsbx01 only; it is unrelated to the vault.

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

## Setting up GLaDOS (one-time — already completed, kept for rebuilds)

**devsbx01 device ID:** `LCMBZJE-WWJQ3MM-P7M37A2-QGOW777-NE67R72-BLXFRB7-O4IURUL-FR7ZJQO`
**GLaDOS device ID:** `WBNIPO5-UIFASPU-…` (full value in devsbx01's `config.xml`)

1. Install [SyncTrayzor](https://github.com/canton7/SyncTrayzor/releases) on GLaDOS
2. In SyncTrayzor: Add Remote Device → paste devsbx01's device ID above
3. On devsbx01 Syncthing UI (http://127.0.0.1:8384): accept the connection request from GLaDOS
4. On devsbx01: share the `Homelab Obsidian Vault` folder with GLaDOS
5. On GLaDOS: accept the folder share, set path to `C:\Users\Scott\Documents\Obsidian Vault\homelab`
6. Verify GLaDOS shows "Up to Date" in the Syncthing UI
7. Set up Obsidian on GLaDOS to open the vault at that path
8. Enable Obsidian Sync on GLaDOS — this pushes to vollminxps and mobile

## Removing vollminxps from Syncthing

**Partly done already:** vollminxps no longer shares `homelab-vault`, so it is already off the
Syncthing path for the vault and receives it via Obsidian Sync from GLaDOS. It is still listed as a
configured device. To finish:

1. On devsbx01: Syncthing UI → Devices → vollminxps → Remove
2. On vollminxps: unshare or uninstall SyncTrayzor

## .stignore (what Syncthing skips)

```
.git
.obsidian
!.obsidian/graph.json
```

**Read the third line carefully — it is a negation.** The whole `.obsidian` directory is excluded,
and `graph.json` is then explicitly *un*-ignored, so the graph configuration **does** sync while the
rest of the Obsidian workspace state does not. (This doc previously listed
`.obsidian/graph.json` as an ignore, which is the opposite of what the file does.)

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
