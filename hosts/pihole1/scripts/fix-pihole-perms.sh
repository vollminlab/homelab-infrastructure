#!/bin/bash
WATCH_DIR="/etc/pihole"
TOML_FILE="$WATCH_DIR/pihole.toml"

while inotifywait -e close_write,move,create "$WATCH_DIR"; do
    if [ -f "$TOML_FILE" ]; then
        echo "Detected change to $TOML_FILE, fixing permissions..."
        chown pihole:pihole "$TOML_FILE"
        chmod 664 "$TOML_FILE"
    fi
done

