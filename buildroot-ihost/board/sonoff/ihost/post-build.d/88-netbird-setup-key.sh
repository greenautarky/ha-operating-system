#!/bin/bash
# Inject NetBird reusable setup key into the rootfs at first-boot path.
# Key file is stored in secrets/netbird-setup-key.txt (gitignored).
#
# This key lets a freshly-flashed device self-register against
# api.netbird.io on first boot via /usr/libexec/ga-netbird-register.
# Mirrors the pattern of 85-wifi-install-psk.sh (WiFi PSK injection).
set -e

TARGET_DIR="$1"
DST_DIR="${TARGET_DIR}/usr/share/ga-netbird"
DST_FILE="${DST_DIR}/setup-key"
KEY_FILE="/build/secrets/netbird-setup-key.txt"

# Ensure target dir exists even if key absent (so the register script
# can probe predictably and skip gracefully).
mkdir -p "$DST_DIR"

if [ ! -f "$KEY_FILE" ]; then
    echo "netbird-setup-key: $KEY_FILE not found — devices flashed from this"
    echo "                   build will NOT auto-register with NetBird."
    echo "                   Place the reusable setup key from the NetBird admin"
    echo "                   panel at secrets/netbird-setup-key.txt and rebuild."
    # Remove any stale key file from a previous build.
    rm -f "$DST_FILE"
    exit 0
fi

# Strip surrounding whitespace + comment lines; expect a single non-empty line.
KEY_VALUE=$(grep -vE '^[[:space:]]*(#|$)' "$KEY_FILE" | head -1 | tr -d '[:space:]')
if [ -z "$KEY_VALUE" ]; then
    echo "netbird-setup-key: $KEY_FILE has no usable key line (only comments?) — skipping"
    rm -f "$DST_FILE"
    exit 0
fi

# Loose sanity check: NetBird setup keys are typically standard UUIDs.
# Don't enforce — operators might use a different format in the future.
case "$KEY_VALUE" in
    [0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*)
        # looks like a UUID — ok
        ;;
    *)
        echo "netbird-setup-key: WARNING key '${KEY_VALUE:0:8}...' is not a typical UUID;"
        echo "                   proceeding anyway."
        ;;
esac

printf '%s\n' "$KEY_VALUE" > "$DST_FILE"
chmod 600 "$DST_FILE"
chown 0:0 "$DST_FILE" 2>/dev/null || true
echo "netbird-setup-key: injected setup key (${#KEY_VALUE} chars) into $DST_FILE"
