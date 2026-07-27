#!/usr/bin/env sh
set -eu
TARGET_DIR="${1:?TARGET_DIR missing}"

ROOT_PW_HASH="${ROOT_PW_HASH:-}"
if [ -z "$ROOT_PW_HASH" ]; then
  # Fail closed on prod — mirrors post-build.d/80-root-password.sh. A prod image
  # must never ship a passwordless root; dev/bench may. [Vuln-7]
  if [ "${GA_ENV:-dev}" = "prod" ]; then
    echo "ERROR: ROOT_PW_HASH not set for a prod build (GA_ENV=prod) — refusing passwordless root" >&2
    exit 1
  fi
  exit 0
fi

SHADOW="$TARGET_DIR/etc/shadow"
[ -f "$SHADOW" ] || exit 1

awk -F: -v OFS=: -v H="$ROOT_PW_HASH" '
  $1=="root" { $2=H }
  { print }
' "$SHADOW" > "$SHADOW.tmp"
mv "$SHADOW.tmp" "$SHADOW"
chmod 0400 "$SHADOW"

