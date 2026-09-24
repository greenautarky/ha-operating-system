#!/usr/bin/env sh
set -eu
TARGET_DIR="${1:?TARGET_DIR missing}"

ROOT_PW_HASH="${ROOT_PW_HASH:-}"
if [ -z "$ROOT_PW_HASH" ]; then
  # Fail closed on every build — mirrors post-build.d/80-root-password.sh.
  # One build mode since ADR-0027 D9: no image may ship a passwordless root. [Vuln-7]
  echo "ERROR: ROOT_PW_HASH not set — refusing passwordless root (ADR-0027 D9: every build)" >&2
  exit 1
fi

SHADOW="$TARGET_DIR/etc/shadow"
[ -f "$SHADOW" ] || exit 1

awk -F: -v OFS=: -v H="$ROOT_PW_HASH" '
  $1=="root" { $2=H }
  { print }
' "$SHADOW" > "$SHADOW.tmp"
mv "$SHADOW.tmp" "$SHADOW"
chmod 0400 "$SHADOW"

