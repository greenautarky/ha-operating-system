#!/bin/sh
# Environment (dev/prod) test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Environment"

run_test "ENV-01" "ga-env.conf exists on rootfs" \
  "test -f /etc/ga-env.conf"

run_test "ENV-02" "GA_ENV value is valid (dev or prod)" \
  ". /etc/ga-env.conf 2>/dev/null && echo \$GA_ENV | grep -qE '^(dev|prod)$'"

run_test "ENV-06" "Rootfs is read-only" \
  "! echo test >> /etc/ga-env.conf 2>/dev/null"

run_test "ENV-08" "os-release contains GA build info" \
  "grep -q 'GA_BUILD_ID=' /etc/os-release 2>/dev/null"

run_test_show "ENV-08b" "GA build fields" \
  "grep GA_ /etc/os-release 2>/dev/null"

# ENV-09..11 (ADR-0055): the human-facing label on the device. The expected
# string is built from /etc/ga-release (the source of truth) and VERSION_ID,
# NOT from the files under test. Technical IDs stay: VERSION_ID and CPE_NAME
# still carry the plain HAOS version (Supervisor reads them).
run_test "ENV-09" "PRETTY_NAME is 'GreenAutarky <ga_release> (HAOS <osver>)'" \
  'rel="$(head -n 1 /etc/ga-release | tr -d "\r\n")"; [ -n "$rel" ] && . /etc/os-release && [ "$PRETTY_NAME" = "GreenAutarky $rel (HAOS $VERSION_ID)" ]'

run_test "ENV-10" "/etc/motd carries the ga_release" \
  'rel="$(head -n 1 /etc/ga-release | tr -d "\r\n")"; [ -n "$rel" ] && grep -qF "$rel" /etc/motd'

run_test "ENV-11" "/etc/issue (console banner) carries the ga_release" \
  'rel="$(head -n 1 /etc/ga-release | tr -d "\r\n")"; [ -n "$rel" ] && grep -qF "$rel" /etc/issue'

run_test "ENV-12" "VERSION_ID / CPE_NAME still carry the plain HAOS version (technical IDs unchanged)" \
  '. /etc/os-release && echo "$VERSION_ID" | grep -qE "^[0-9]+(\.[0-9]+)+$" && echo "$CPE_NAME" | grep -q ":haos:$VERSION_ID"'

# Test runtime override (non-destructive: only if override already exists)
if [ -f /mnt/data/ga-env.conf ]; then
  run_test "ENV-05" "Runtime override exists on data partition" \
    "test -f /mnt/data/ga-env.conf"
else
  skip_test "ENV-05" "Runtime override" "no /mnt/data/ga-env.conf present"
fi

skip_test "ENV-03" "Dev defaults" "depends on build type"
skip_test "ENV-04" "Prod defaults" "depends on build type"
skip_test "ENV-07" "Image filename contains env tag" "build-time property, not verifiable on device"

suite_end
