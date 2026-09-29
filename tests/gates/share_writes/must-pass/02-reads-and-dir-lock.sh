#!/bin/sh
# Reads of shared files, and a read-only fd on the shared directory for flock.
SHARE=/mnt/data/supervisor/share/example.json
LOCK_DIR="$(dirname "$SHARE")"
[ -f "$SHARE" ] && tr -d '\n' < "$SHARE" 2>/dev/null | sed -n 's/x/y/p'
grep -q enabled "$SHARE" 2>/dev/null
v=$(cat "$SHARE" 2>/dev/null)
( flock -w 5 9; echo "$v" ) 9<"$LOCK_DIR"
