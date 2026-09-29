#!/bin/bash
# Inject the NetBird reusable setup key into the rootfs at the first-boot path.
#
# Usage:
#   88-netbird-setup-key.sh <TARGET_DIR>   post-build hook (buildroot)
#   88-netbird-setup-key.sh --check        preflight (scripts/ga_build.sh)
#
# The key file is secrets/netbird-setup-key.txt (gitignored), read from
# /build/secrets/. It lets a freshly-flashed device self-register on first
# boot via /usr/libexec/ga-netbird-register.
#
# A missing key file, or one with no usable (non-comment) line, FAILS THE
# BUILD. There is one build mode (ADR-0027 D9), so every image is one the
# fleet may install — and an image without the key produces devices that can
# never join the mesh on their own, while looking healthy on the bench.
# Both modes share one reader below, so the preflight and the hook cannot
# disagree. NB-REG-05 in tests/ga_tests/run_build_tests.sh checks the result.
#
# NETBIRD_SETUP_KEY_FILE overrides the path (self-tests only); it does not
# relax the check.
set -e

KEY_FILE="${NETBIRD_SETUP_KEY_FILE:-/build/secrets/netbird-setup-key.txt}"

die() {
    echo "netbird-setup-key: FAIL: $*" >&2
    echo "                   Place the reusable setup key from the NetBird admin" >&2
    echo "                   panel at secrets/netbird-setup-key.txt and rebuild." >&2
    exit 1
}

# First non-comment, non-blank line, whitespace stripped. Sets KEY_VALUE or dies.
read_key() {
    [ -f "$KEY_FILE" ] || die "$KEY_FILE not found — devices flashed from this build could never join the mesh"
    KEY_VALUE=$(grep -vE '^[[:space:]]*(#|$)' "$KEY_FILE" | head -1 | tr -d '[:space:]')
    [ -n "$KEY_VALUE" ] || die "$KEY_FILE has no usable key line (empty or only comments)"
}

if [ "${1:-}" = "--check" ]; then
    read_key
    echo "netbird-setup-key: preflight ok (${#KEY_VALUE} chars in $KEY_FILE)"
    exit 0
fi

TARGET_DIR="$1"
if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    echo "netbird-setup-key: FAIL: TARGET_DIR not provided or invalid" >&2
    exit 1
fi
DST_DIR="${TARGET_DIR}/usr/share/ga-netbird"
DST_FILE="${DST_DIR}/setup-key"

mkdir -p "$DST_DIR"
# Never let a key from a previous build survive a failed read.
rm -f "$DST_FILE"
read_key

# Loose sanity check: NetBird setup keys are typically standard UUIDs.
# Don't enforce — operators might use a different format in the future.
case "$KEY_VALUE" in
    [0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*-[0-9a-fA-F]*)
        # looks like a UUID — ok
        ;;
    *)
        echo "netbird-setup-key: WARNING key (${#KEY_VALUE} chars) is not a typical UUID;"
        echo "                   proceeding anyway."
        ;;
esac

printf '%s\n' "$KEY_VALUE" > "$DST_FILE"
chmod 600 "$DST_FILE"
chown 0:0 "$DST_FILE" 2>/dev/null || true
echo "netbird-setup-key: injected setup key (${#KEY_VALUE} chars) into $DST_FILE"
