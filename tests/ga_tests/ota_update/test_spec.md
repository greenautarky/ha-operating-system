# OTA / RAUC Update Tests

## Components
- RAUC update system (A/B slot redundancy)
- Rootfs config delivery (telegraf, fluent-bit, crash detection)
- Persistent data partition preservation

## Prerequisites
- Device with dual boot slots (A/B)
- RAUC bundle (`.raucb`) available
- Signed with valid CA certificate

## Tests

### OTA-01: RAUC status shows healthy
- **Action**: Check RAUC slot status
- **Command**: `rauc status`
- **Expected**: One slot marked as booted, both slots present

### OTA-02: Config files updated after OTA
- **Action**: Flash new image with config changes, verify configs updated
- **Command**: After RAUC update + reboot:
  - `cat /etc/telegraf/telegraf.conf | head -5`
  - `cat /etc/fluent-bit/fluent-bit.conf | head -5`
- **Expected**: Configs match the new build (rootfs is replaced)

### OTA-03: Service files updated after OTA
- **Action**: Verify systemd service files are from new build
- **Command**: `systemctl cat telegraf | grep ExecStart`
- **Expected**: Matches new service file content

### OTA-04: Persistent data survives OTA
- **Action**: Write marker to /mnt/data before OTA, verify after
- **Command**:
  - Before: `echo "ota-test" > /mnt/data/ota_test_marker`
  - After OTA + reboot: `cat /mnt/data/ota_test_marker`
- **Expected**: `ota-test`
- **Cleanup**: `rm /mnt/data/ota_test_marker`

### OTA-05: Crash detection services present after OTA
- **Action**: Verify new services are installed and enabled
- **Command**: `systemctl is-enabled ga-crash-marker ga-boot-check`
- **Expected**: Both `enabled`

### OTA-06: Stale data partition configs ignored
- **Action**: Verify old /mnt/data configs don't interfere
- **Command**: Check that services read from /etc/, not /mnt/data/
  - `systemctl cat telegraf | grep "config /etc/"`
- **Expected**: Config path is `/etc/telegraf/telegraf.conf`

### OTA-07: Rollback to previous slot
- **Action**: Switch to alternate boot slot
- **Command**: `rauc status mark-active other && reboot`
- **Expected**: Device boots from other slot with previous version

### OTA-08: journald logs survive OTA
- **Action**: Verify journal history persists across update
- **Command**: `journalctl --list-boots`
- **Expected**: Boots from before and after OTA visible
