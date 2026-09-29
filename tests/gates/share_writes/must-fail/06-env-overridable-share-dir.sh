#!/bin/sh
# expect-findings: 2
# The share dir comes from an env hook with the real path as its default.
SHARE_DIR="${GA_EXAMPLE_SHARE_DIR:-/mnt/data/supervisor/share}"
STATUS_FILE="$SHARE_DIR/example-status.json"
write_status() {
  tmp="$STATUS_FILE.tmp.$$"
  cat > "$tmp" <<EOF
{ "enabled": $1 }
EOF
  mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || rm -f "$tmp"
}
