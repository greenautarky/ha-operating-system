#!/bin/sh
# NetBird auto-registration test suite — runs ON the device.
# Verifies the OS-baked `ga-netbird-register` service brought the
# NetBird daemon out of `NeedsLogin` and into a real tunnel.
#
# Counterpart build tests: NB-REG-01..05 in run_build_tests.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "NetBird auto-registration"

# NB-REG-D-01: script + unit baked into rootfs.
run_test "NB-REG-D-01" "ga-netbird-register script present + executable" \
  "test -x /usr/libexec/ga-netbird-register"

run_test "NB-REG-D-02" "ga-netbird-register.service unit present" \
  "test -f /usr/lib/systemd/system/ga-netbird-register.service"

# NB-REG-D-03: setup key was baked into image.
run_test "NB-REG-D-03" "/usr/share/ga-netbird/setup-key baked (0600)" \
  "test -f /usr/share/ga-netbird/setup-key && test \"\$(stat -c '%a' /usr/share/ga-netbird/setup-key)\" = '600'"

# NB-REG-D-04: service ran successfully (exited 0 after registration).
# `oneshot` + `RemainAfterExit=yes` means `is-active` returns active
# after success. On a slow first boot with Restart=on-failure pending,
# it may show `activating` — wait briefly.
run_test "NB-REG-D-04" "ga-netbird-register.service is active" \
  "systemctl is-active ga-netbird-register.service >/dev/null"

# NB-REG-D-05: daemon is past NeedsLogin (the whole point of the bake).
run_test "NB-REG-D-05" "netbird daemon NOT in NeedsLogin state" \
  "! /usr/bin/netbird --daemon-addr unix:///var/run/netbird.sock status 2>&1 | grep -q NeedsLogin"

# NB-REG-D-06: daemon has assigned a NetBird IP (proves mgmt-plane round-trip).
run_test "NB-REG-D-06" "netbird daemon has a NetBird IP" \
  "/usr/bin/netbird --daemon-addr unix:///var/run/netbird.sock status 2>&1 | grep -qE 'NetBird IP:[[:space:]]+[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+'"

# NB-REG-D-07: tunnel actually established (Management connected).
run_test "NB-REG-D-07" "Management plane connected" \
  "/usr/bin/netbird --daemon-addr unix:///var/run/netbird.sock status 2>&1 | grep -qE 'Management:[[:space:]]+Connected'"

suite_end
