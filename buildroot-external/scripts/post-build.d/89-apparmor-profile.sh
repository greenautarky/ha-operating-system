#!/bin/bash
# Install the Supervisor AppArmor profile into the rootfs, pinned.
#
# Usage: 89-apparmor-profile.sh <TARGET_DIR>   post-build hook (buildroot)
#
# Source buildroot-external/apparmor/hassio-supervisor, checked against its one
# pin (hassio-supervisor.sha256) by verify-apparmor-profile.sh BEFORE it is
# copied; the copy in the image is checked again. Any mismatch FAILS THE BUILD.
# haos-apparmor (patch 0132) loads /usr/share/ga-apparmor/hassio-supervisor on
# every boot; nothing is downloaded at build or boot time.
# AA-PIN-01 in tests/ga_tests/run_build_tests.sh checks the image.
# Self-test: tests/gates/apparmor_pin/selftest.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$HERE/../verify-apparmor-profile.sh"
SRC="${GA_APPARMOR_PROFILE_SRC:-$HERE/../../apparmor/hassio-supervisor}"   # override: self-tests only

TARGET_DIR="${1:-}"
if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    echo "apparmor-profile: FAIL: TARGET_DIR not provided or invalid" >&2
    exit 1
fi
DST="$TARGET_DIR/usr/share/ga-apparmor/hassio-supervisor"

# Never let a profile from a previous build survive a failed check.
rm -f "$DST"
"$VERIFY" "$SRC"
install -D -m 0644 "$SRC" "$DST"
"$VERIFY" "$DST"
echo "apparmor-profile: installed the pinned Supervisor profile at /usr/share/ga-apparmor/hassio-supervisor"
