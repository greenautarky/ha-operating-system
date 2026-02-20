# Power-Cycle Restart Stress Tests

## Components
- Host-side stress test runner (`power_cycle/test.sh`)
- `serial-tmux.sh` serial console (send/capture/wait)
- External power control hook (uhubctl REST API, custom command, or manual)
- Boot completion detection via serial console prompt

## Purpose
Verify device reliability under repeated hard power-cycle conditions:
cold-boot timing consistency, filesystem integrity, service recovery,
and absence of boot hangs across N consecutive power-off/power-on cycles.

## Prerequisites
- Serial console session active (via `serial-tmux.sh`)
- Power control method available (uhubctl, smart plug, or manual)
- Device hostname visible in serial prompt (e.g. "KiBu")
- Host has `bash`, `date`, `awk`

## Architecture
Unlike other test suites, this is a **HOST-SIDE** script. It does NOT run
on the device. It orchestrates power control and serial monitoring from the
development machine.

## Tests

### PWR-01: Single power-cycle with boot-time measurement
- **Action**: Power off device, wait, power on, measure time to shell prompt
- **Procedure**:
  1. Power off via configured hook
  2. Wait configurable off-time (default 5s)
  3. Record timestamp T0
  4. Power on via configured hook
  5. Wait for U-Boot/kernel signature on serial (proves actual reboot)
  6. Wait for shell prompt (`#` or `login:`)
  7. Record timestamp T1, boot_time = T1 - T0
- **Expected**: Device reaches shell prompt within timeout (default 120s)

### PWR-02: N-cycle endurance run (default 100 cycles)
- **Action**: Repeat PWR-01 for N consecutive cycles
- **Expected**:
  - 100% success rate (all cycles reach prompt)
  - Boot time variance < 30% of mean
  - No hangs (cycles exceeding timeout)

### PWR-03: Boot time consistency across cycles
- **Action**: Analyze boot times from PWR-02 CSV log
- **Expected**:
  - Mean boot time within expected range (30-60s for iHost)
  - Standard deviation < 10s
  - No outliers > 2x mean (would indicate partial hang)

### PWR-04: Filesystem integrity after power-cycle storm
- **Action**: After all cycles complete, verify device health via serial
- **Command**:
  ```
  dmesg | grep -ciE 'error|fault|corrupt|readonly'
  mount | grep '/mnt/data'
  touch /mnt/data/pwr_test_marker && rm /mnt/data/pwr_test_marker
  ```
- **Expected**: No filesystem errors, /mnt/data writable

### PWR-05: Crash detection log after power-cycle storm
- **Action**: Verify crash detection system logged unclean shutdowns
- **Command**:
  ```
  journalctl -u ga-boot-check -b 0 --no-pager -q
  ```
- **Expected**: Last boot shows unclean shutdown detected

### PWR-06: Services running after power-cycle storm
- **Action**: Verify critical services recovered after final boot
- **Command**:
  ```
  systemctl is-active telegraf ga-disk-guard.timer
  ```
- **Expected**: All services active

### PWR-07: Journal boot history matches cycle count
- **Action**: Check journald recorded boot events
- **Command**: `journalctl --list-boots | wc -l`
- **Expected**: Boot count >= N (may be higher with prior boots)

### PWR-08: Rapid power-cycle (short off-time stress)
- **Action**: Run 10 cycles with only 1s off-time (brown-out simulation)
- **Expected**: Device recovers from all rapid cycles without bricking

### PWR-09: Hang detection and recovery
- **Action**: If a cycle exceeds boot timeout, log as HANG and continue
- **Expected**: Script detects hang, logs it, and continues with next cycle
  via hard power-cycle recovery

### PWR-10: Summary report generation
- **Action**: Generate CSV log and statistical summary after run
- **Expected**: CSV with columns: cycle, boot_time_s, result, timestamp, notes.
  Summary: total/pass/hang/error, min/max/avg/median/stddev/p95 boot time
