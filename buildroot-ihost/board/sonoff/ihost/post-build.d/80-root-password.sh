#!/usr/bin/env sh
set -eu

TARGET_DIR="${1:-}"
ROOT_PW_HASH="${ROOT_PW_HASH:-}"

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
  echo "ERROR: TARGET_DIR not provided or invalid"
  exit 1
fi

if [ -z "$ROOT_PW_HASH" ]; then
  echo "INFO: ROOT_PW_HASH not set; leaving root password unchanged"
  exit 0
fi

case "$ROOT_PW_HASH" in
  '$6$'* ) : ;;
  * )
    echo "ERROR: ROOT_PW_HASH does not look like a SHA-512 crypt hash (\$6\$...)."
    exit 1
    ;;
esac

SHADOW="$TARGET_DIR/etc/shadow"
if [ ! -f "$SHADOW" ]; then
  echo "ERROR: $SHADOW not found"
  exit 1
fi

tmp="$SHADOW.tmp"

awk -F: -v OFS=: -v H="$ROOT_PW_HASH" '
  BEGIN { found=0 }
  $1=="root" { $2=H; found=1 }
  { print }
  END { if (!found) exit 42 }
' "$SHADOW" > "$tmp" || {
  rc=$?
  if [ "$rc" -eq 42 ]; then
    echo "ERROR: root entry not found in $SHADOW"
  else
    echo "ERROR: failed to update $SHADOW (awk exit $rc)"
  fi
  rm -f "$tmp"
  exit 1
}

mv "$tmp" "$SHADOW"
chown 0:0 "$SHADOW" 2>/dev/null || true
chmod 0600 "$SHADOW"

echo "INFO: root password hash updated in /etc/shadow"
