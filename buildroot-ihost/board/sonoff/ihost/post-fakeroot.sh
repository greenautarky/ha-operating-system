#!/usr/bin/env sh
set -eu
TARGET_DIR="${1:?TARGET_DIR missing}"

ROOT_PW_HASH="${ROOT_PW_HASH:-}"
[ -n "$ROOT_PW_HASH" ] || exit 0

SHADOW="$TARGET_DIR/etc/shadow"
[ -f "$SHADOW" ] || exit 1

awk -F: -v OFS=: -v H="$ROOT_PW_HASH" '
  $1=="root" { $2=H }
  { print }
' "$SHADOW" > "$SHADOW.tmp"
mv "$SHADOW.tmp" "$SHADOW"
chmod 0400 "$SHADOW"

