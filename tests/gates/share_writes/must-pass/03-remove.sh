#!/bin/sh
# Removing a name in the shared directory unlinks the name, never a target.
MARKER=/mnt/data/supervisor/share/.example_marker
rm -f "$MARKER"
rm -f /mnt/data/supervisor/share/example.json
