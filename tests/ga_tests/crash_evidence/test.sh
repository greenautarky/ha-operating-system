#!/bin/sh
# Crash evidence suite - runs ON the device, non-destructive.
#
# Proves the MECHANISMS are present on the running kernel. Whether they really
# preserve a panic across a reset is proven by the host-side drills
# (run_device_tests.sh --suites crash_panic / crash_clean_reboot), because the
# device dies mid-test.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Crash Evidence"

# Fail closed: a config we cannot read is a failure, not a pass.
run_test "CE-01" "running kernel config is readable (/proc/config.gz)" \
  "[ -r /proc/config.gz ] && [ \$(zcat /proc/config.gz | wc -l) -gt 100 ]"

for kv in CONFIG_PSTORE=y CONFIG_PSTORE_CONSOLE=y CONFIG_PSTORE_RAM=y \
          CONFIG_SOFTLOCKUP_DETECTOR=y CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC=y \
          CONFIG_HARDLOCKUP_DETECTOR=y CONFIG_BOOTPARAM_HARDLOCKUP_PANIC=y \
          CONFIG_DETECT_HUNG_TASK=y CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y \
          CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=300; do
  run_test "CE-02-${kv%%=*}" "kernel built with $kv" \
    "zcat /proc/config.gz | grep -qx '$kv'"
done

run_test "CE-03a" "softlockup panics (kernel.softlockup_panic=1)" \
  "[ \"\$(cat /proc/sys/kernel/softlockup_panic)\" = 1 ]"
run_test "CE-03b" "hardlockup panics (kernel.hardlockup_panic=1)" \
  "[ \"\$(cat /proc/sys/kernel/hardlockup_panic)\" = 1 ]"
run_test "CE-03c" "hung task panics (kernel.hung_task_panic=1)" \
  "[ \"\$(cat /proc/sys/kernel/hung_task_panic)\" = 1 ]"
run_test "CE-03d" "hung task timeout is 300 s (slow-SD tolerance)" \
  "[ \"\$(cat /proc/sys/kernel/hung_task_timeout_secs)\" = 300 ]"
run_test "CE-03e" "systemd RuntimeWatchdog untouched: kernel panic timeout still 5 s" \
  "[ \"\$(cat /proc/sys/kernel/panic)\" = 5 ]"

# The ramoops backend must be REGISTERED, not merely compiled in: without the
# DT region the driver is silent and /sys/fs/pstore stays empty forever.
run_test "CE-04" "ramoops registered as pstore backend (DT region present)" \
  "dmesg | grep -q 'pstore: Registered ramoops as persistent store backend'"
run_test "CE-04b" "pstore filesystem mounted at /sys/fs/pstore" \
  "grep -q ' /sys/fs/pstore pstore ' /proc/mounts"

# Thermal: OPEN. mainline 6.12 has no RV1126 tsadc (no compatible, no DT node);
# this is a WARN until a tsadc driver/DT lands, then it must go PASS.
warn_test "CE-05" "OPEN: >=1 thermal zone with a plausible temperature (0..110 C)" \
  "n=0; for z in /sys/class/thermal/thermal_zone*; do [ -r \"\$z/temp\" ] || continue; t=\$(cat \"\$z/temp\"); [ \"\$t\" -gt 0 ] && [ \"\$t\" -lt 110000 ] && n=\$((n+1)); done; [ \"\$n\" -ge 1 ]"

# The SoC reset-status register must be readable (ga-boot-check logs it).
run_test "CE-06" "CRU_GLB_RST_ST readable via devmem (mmap; read() on /dev/mem fails for MMIO)" \
  "v=\$(devmem 0xff490404 32) && echo \"\$v\" | grep -Eq '^0x[0-9a-fA-F]{8}\$'"

suite_end
