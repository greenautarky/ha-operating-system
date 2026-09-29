#!/bin/sh
# expect-findings: 2
# A PID-suffixed temporary name in the shared directory (inside a function).
SHARE_DIR=/mnt/data/supervisor/share
STATUS_FILE="$SHARE_DIR/example-status.json"
write_status() {
	[ -d "$SHARE_DIR" ] || return 0
	tmp="$STATUS_FILE.tmp.$$"
	cat > "$tmp" <<EOF
{ "enabled": $1 }
EOF
	mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || { rm -f "$tmp"; return 0; }
}
