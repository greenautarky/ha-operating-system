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

# The shape ga-root-shadow accepts at runtime (its valid_hash): one SHA-512 crypt
# hash, optional rounds=, 1-16 salt characters, 86 hash characters, one line,
# nothing else. A prefix match is not enough: a truncated value would land in
# /etc/shadow as a hash no password matches. ihost_root_password IHPW-09 holds
# this pattern equal to the runtime one.
GA_ROOT_PW_HASH_RE='\$6\$(rounds=[0-9]+\$)?[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}'
case "$ROOT_PW_HASH" in
  *'
'* ) echo "ERROR: ROOT_PW_HASH spans more than one line." >&2; exit 1 ;;
esac
if ! printf '%s\n' "$ROOT_PW_HASH" | grep -Eqx "$GA_ROOT_PW_HASH_RE"; then
  echo "ERROR: ROOT_PW_HASH is not a complete SHA-512 crypt hash (\$6\$[rounds=N\$]<salt>\$<86 chars>)." >&2
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

