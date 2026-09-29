#!/bin/sh
# expect-findings: 2
# A fixed temporary name in the shared directory, then a rename onto the file.
SHARE_HEALTH="/mnt/data/supervisor/share/example-health.json"
write_health() {
    _tmp="${SHARE_HEALTH}.tmp"
    cat > "$_tmp" 2>/dev/null <<JSON || { rm -f "$_tmp" 2>/dev/null; return 0; }
{ "ts": 0 }
JSON
    mv "$_tmp" "$SHARE_HEALTH" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
}
