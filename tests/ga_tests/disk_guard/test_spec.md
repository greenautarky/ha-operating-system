# Disk Guard Tests

## Components
- `/usr/sbin/ga_disk_guard` (cleanup script)
- `ga-disk-guard.service` (oneshot, runs the script)
- `ga-disk-guard.timer` (triggers every 5 min, first run 2 min after boot)
- State file: `/run/ga_disk_guard/state.json`

## Configuration
- Monitor paths: `/`, `/mnt/data`, `/mnt/data/docker`
- Soft threshold: 300 MiB free → soft cleanup
- Hard threshold: 120 MiB free → hard cleanup
- Target recovery: 450 MiB
- Allowlist: `/tmp`, `/var/tmp`, `/var/log`, `/mnt/data/`
- journald vacuum: soft=200M, hard=80M

## Prerequisites
- Device booted with ga-disk-guard timer enabled
- SSH access for manual trigger and monitoring

## Tests

### DG-01: Script and service installed
- **Action**: Verify all disk guard components exist
- **Command**:
  ```
  test -x /usr/sbin/ga_disk_guard && echo "script OK"
  systemctl list-unit-files | grep ga-disk-guard
  ```
- **Expected**: Script executable, both `.service` and `.timer` listed

### DG-02: Timer is active and scheduled
- **Action**: Verify timer is running and has next trigger
- **Command**: `systemctl status ga-disk-guard.timer`
- **Expected**: `active (waiting)`, shows next trigger time (~5 min intervals)

### DG-03: Manual run — idle state (enough space)
- **Action**: Run disk guard manually when disk is healthy
- **Command**:
  ```
  /usr/sbin/ga_disk_guard
  cat /run/ga_disk_guard/state.json
  ```
- **Expected**: `"phase": "idle"`, `worst_free_mib_before` > 300, `"actions": "none"`

### DG-04: State file format valid
- **Action**: Verify state file contains all required fields
- **Command**: `cat /run/ga_disk_guard/state.json`
- **Expected**: JSON with fields: `timestamp`, `phase`, `worst_mountpoint`, `worst_free_mib_before`, `worst_free_mib_after`, `worst_freed_mib`, `actions`

### DG-05: Soft cleanup triggers below 300 MiB
- **Action**: Fill disk to below soft threshold, run guard
- **Command**:
  ```
  # Create large temp file to reduce free space below 300 MiB
  FREE=$(df -Pm /mnt/data | awk 'NR==2{print $4}')
  FILL=$(( FREE - 250 ))
  dd if=/dev/zero of=/mnt/data/test_fill bs=1M count=$FILL 2>/dev/null
  /usr/sbin/ga_disk_guard
  cat /run/ga_disk_guard/state.json
  ```
- **Expected**: `"phase": "soft"`, actions contain cleanup entries
- **Cleanup**: `rm -f /mnt/data/test_fill`

### DG-06: Hard cleanup triggers below 120 MiB
- **Action**: Fill disk to below hard threshold, run guard
- **Command**:
  ```
  FREE=$(df -Pm /mnt/data | awk 'NR==2{print $4}')
  FILL=$(( FREE - 80 ))
  dd if=/dev/zero of=/mnt/data/test_fill bs=1M count=$FILL 2>/dev/null
  /usr/sbin/ga_disk_guard
  cat /run/ga_disk_guard/state.json
  ```
- **Expected**: `"phase": "hard"`, journald vacuum action with 80M
- **Cleanup**: `rm -f /mnt/data/test_fill`

### DG-07: Allowlist enforcement
- **Action**: Verify guard refuses to clean outside allowlist
- **Command**: Check script logic — only `/tmp`, `/var/tmp`, `/var/log`, `/mnt/data/` are cleaned
- **Expected**: No file deletion outside allowlist paths (verify in journal: `journalctl -t ga_disk_guard`)

### DG-08: Old temp files cleaned (del_age_days)
- **Action**: Create old temp files, trigger soft cleanup
- **Command**:
  ```
  touch -d "5 days ago" /tmp/old_test_file.tmp
  touch -d "5 days ago" /var/tmp/old_test_file.tmp
  # Trigger soft cleanup (reduce space below 300 MiB first)
  /usr/sbin/ga_disk_guard
  ls /tmp/old_test_file.tmp /var/tmp/old_test_file.tmp 2>&1
  ```
- **Expected**: Old files deleted (if soft cleanup triggered)

### DG-09: Rotated logs cleaned (del_glob)
- **Action**: Create mock rotated log files, trigger cleanup
- **Command**:
  ```
  touch /var/log/test.log.gz /var/log/test.log.1 /var/log/test.log.old
  # Trigger cleanup
  /usr/sbin/ga_disk_guard
  ls /var/log/test.log.gz /var/log/test.log.1 /var/log/test.log.old 2>&1
  ```
- **Expected**: Rotated log files deleted (if soft cleanup triggered)

### DG-10: Large log truncation (trunc_size_mib)
- **Action**: Create a log file > 20 MiB, trigger cleanup
- **Command**:
  ```
  dd if=/dev/zero of=/var/log/test_large.log bs=1M count=25 2>/dev/null
  ls -lh /var/log/test_large.log
  # Trigger cleanup
  /usr/sbin/ga_disk_guard
  ls -lh /var/log/test_large.log
  ```
- **Expected**: File still exists (inode preserved) but size truncated to 0
- **Cleanup**: `rm -f /var/log/test_large.log`

### DG-11: journald vacuum executed
- **Action**: Verify journald vacuum runs during cleanup
- **Command**: `journalctl -t ga_disk_guard | grep journald`
- **Expected**: Log entry showing journald vacuum action

### DG-12: Concurrent run protection (lock)
- **Action**: Verify only one instance runs at a time
- **Command**:
  ```
  /usr/sbin/ga_disk_guard &
  /usr/sbin/ga_disk_guard &
  wait
  ```
- **Expected**: Second instance exits silently (mkdir lock prevents concurrent runs)

### DG-13: Timer triggers after boot
- **Action**: Reboot and verify timer ran within first 2 minutes
- **Command**: After reboot, wait 3 minutes, then:
  ```
  systemctl status ga-disk-guard.timer
  journalctl -u ga-disk-guard.service --since "3 min ago"
  ```
- **Expected**: Timer active, service ran at least once

### DG-14: Script handles missing paths gracefully
- **Action**: Verify script doesn't fail if a monitored path is unavailable
- **Command**: `/usr/sbin/ga_disk_guard 2>&1; echo "exit=$?"`
- **Expected**: `exit=0` (no errors, missing paths skipped)
