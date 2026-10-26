#!/bin/sh
# Crash detection test suite - runs ON the device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Crash Detection"

run_test "CRASH-01a" "ga-crash-marker service enabled" \
  "systemctl is-enabled ga-crash-marker"

run_test "CRASH-01b" "ga-boot-check service enabled" \
  "systemctl is-enabled ga-boot-check"

run_test "CRASH-02" "Crash marker file exists (active boot)" \
  "test -f /mnt/data/.ga_unclean_shutdown"

# The journal is RAM-only since BOSv1.5.2 / BOSv1.6.0 (Storage=volatile, Odoo #1256), so
# `journalctl -b -1` no longer exists. The previous boot's evidence is the
# bounded dump ga-journal-dump wrote (clean shutdown / rauc install / unclean
# boot detected). CRASH-06 therefore needs a dump from an EARLIER boot.
# Judged by what journald has OPEN, not by a config file: on HAOS 18.x the
# value comes from a drop-in and a later-sorting board drop-in can set it
# back, which a grep of one file cannot see.
run_test "JD-01" "Journal is volatile (journald writes only under /run/log/journal)" \
  "p=\$(pidof systemd-journald); [ -n \"\$p\" ] && ls -l /proc/\$p/fd 2>/dev/null | grep -q '/run/log/journal/.*\\.journal' && ! ls -l /proc/\$p/fd 2>/dev/null | grep -qE '(/var/log/journal|/mnt/data/logs)/.*\\.journal'"

run_test "JD-02" "Journal dump unit enabled" \
  "systemctl is-enabled ga-journal-dump-shutdown.service && systemctl is-active ga-journal-dump-shutdown.service"

run_test "JD-03" "Manual dump is written, readable and under 2 MiB" \
  "/usr/libexec/ga-journal-dump jd-test >/dev/null 2>&1; f=\$(ls -1 /mnt/data/journal-dump/dump-*-jd-test.log.gz | tail -1); [ -n \"\$f\" ] && [ \$(zcat \"\$f\" | wc -c) -gt 0 ] && [ \$(zcat \"\$f\" | wc -c) -le 2097152 ]; rc=\$?; rm -f /mnt/data/journal-dump/dump-*-jd-test.log.gz; exit \$rc"

run_test "JD-04" "At most 5 dumps kept" \
  "[ \$(ls -1 /mnt/data/journal-dump/dump-*.log.gz 2>/dev/null | wc -l) -le 5 ]"

_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d - | head -c 8)
if ls /mnt/data/journal-dump/dump-*.log.gz 2>/dev/null | grep -qv -- "-${_boot_id}-"; then
  run_test "CRASH-06" "Previous boot evidence readable (dump from an earlier boot)" \
    "f=\$(ls -1 /mnt/data/journal-dump/dump-*.log.gz | grep -v -- '-${_boot_id}-' | tail -1); zcat \"\$f\" | head -1 | grep -q ."
else
  skip_test "CRASH-06" "Previous boot evidence readable (no dump from an earlier boot yet: first boot after flash, or no clean shutdown since)"
fi

run_test "CRASH-08" "Crash log under 100KB limit" \
  "[ ! -f /mnt/data/crash_history.log ] || [ \$(stat -c%s /mnt/data/crash_history.log 2>/dev/null || echo 0) -lt 102400 ]"

run_test "CRASH-09" "Boot-check runs before crash-marker" \
  "systemctl show -p After ga-crash-marker.service 2>/dev/null | grep -q ga-boot-check"

run_test_show "CRASH-RES" "Boot check result this boot" \
  "journalctl -u ga-boot-check -b 0 --no-pager -q 2>/dev/null | tail -1"

skip_test "CRASH-03" "Clean shutdown removes marker" "requires reboot"
skip_test "CRASH-04" "Kernel panic detection" "host-side: run with crash_panic suite"
skip_test "CRASH-05" "Power loss detection" "requires physical action"

suite_end
