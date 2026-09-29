#!/bin/sh
# expect-findings: 2
# A PID-suffixed temporary name in the shared directory (top level).
SHARE_DIR=/mnt/data/supervisor/share
OUT="$SHARE_DIR/example-status.json"
[ -d "$SHARE_DIR" ] || exit 0
tmp="$OUT.tmp.$$"
cat > "$tmp" <<JSON
{ "schema_version": 2 }
JSON
mv -f "$tmp" "$OUT" 2>/dev/null || { rm -f "$tmp"; exit 0; }
