# Crash Detection Tests

## Components
- `ga-crash-marker.service` (creates/removes shutdown marker)
- `ga-boot-check.service` (detects unclean shutdown, logs crash events)
- `/usr/libexec/ga-boot-check` (crash detection script)
- Persistent journald logging (`Storage=persistent`)

## Prerequisites
- Both services enabled via `sysinit.target.wants`
- `/mnt/data` partition mounted and writable
- journald configured with `Storage=persistent`

## Tests

### CRASH-01: Services enabled and running
- **Action**: Verify both crash detection services are active
- **Command**: `systemctl is-enabled ga-crash-marker && systemctl is-enabled ga-boot-check`
- **Expected**: Both `enabled`

### CRASH-02: Marker file created at boot
- **Action**: Check marker file exists during normal operation
- **Command**: `test -f /mnt/data/.ga_unclean_shutdown`
- **Expected**: Exit code 0 (file exists while system is running)

### CRASH-03: Clean shutdown removes marker
- **Action**: Reboot cleanly, check marker state
- **Command**: `reboot` then after boot: `journalctl -u ga-boot-check -b 0`
- **Expected**: Output contains "Clean boot - previous shutdown was graceful"

### CRASH-04: Kernel panic detected
- **Action**: Trigger kernel panic, verify crash detection after reboot
- **Command**: `echo c > /proc/sysrq-trigger` then after reboot:
  - `journalctl -u ga-boot-check -b 0`
  - `cat /mnt/data/crash_history.log`
- **Expected**:
  - Journal: "UNCLEAN SHUTDOWN DETECTED"
  - crash_history.log: New entry with timestamp and boot ID

### CRASH-05: Power loss detected
- **Action**: Pull power during operation, verify crash detection
- **Command**: Physical power disconnect, then after boot:
  - `journalctl -u ga-boot-check -b 0`
  - `cat /mnt/data/crash_history.log`
- **Expected**: Same as CRASH-04

### CRASH-06: Previous boot logs available
- **Action**: After crash, verify previous boot logs are accessible
- **Command**: `journalctl -b -1 | head -20`
- **Expected**: Non-empty output showing previous boot's log entries

### CRASH-07: Boot list shows multiple boots
- **Action**: Verify journald tracks boot history
- **Command**: `journalctl --list-boots`
- **Expected**: At least 2 boot entries listed

### CRASH-08: Crash log rotation
- **Action**: Verify crash log doesn't grow unbounded
- **Command**: `stat -c%s /mnt/data/crash_history.log`
- **Expected**: Size < 102400 bytes (100KB limit)

### CRASH-09: Ordering correct (boot-check before crash-marker)
- **Action**: Verify ga-boot-check runs before ga-crash-marker
- **Command**: `systemd-analyze critical-chain ga-crash-marker.service`
- **Expected**: ga-boot-check.service completes before ga-crash-marker starts
