#!/usr/bin/env sh
set -eu

TARGET_DIR="${1:-}"
ROOT_PW_HASH="${ROOT_PW_HASH:-}"

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
  echo "ERROR: TARGET_DIR not provided or invalid"
  exit 1
fi

if [ -z "$ROOT_PW_HASH" ]; then
  # Fail closed on EVERY build: an image must NEVER ship a passwordless root.
  # Since ADR-0027 D9 there is one build mode, so there is no "non-prod" image
  # that may be passwordless — every image is installable by the fleet.
  # CI writes ROOT_PW_HASH from a secret; an unset/empty secret must break the
  # build loudly rather than silently produce `root::` (passwordless console —
  # anyone with brief physical/serial access on a shipped device gets root). [Vuln-7]
  echo "ERROR: ROOT_PW_HASH not set — refusing to ship passwordless root (ADR-0027 D9: every build)" >&2
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
