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
