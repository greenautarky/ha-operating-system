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

### OTA-09: Full RAUC update procedure (end-to-end)
- **Action**: Transfer bundle to device and install via RAUC
- **Procedure**:
  1. Build image: `./scripts/ga_build.sh update` (on build host)
  2. Locate bundle: `ls ga_output/images/*.raucb`
  3. Transfer to device: `scp ga_output/images/*.raucb root@<device>:/tmp/`
  4. Pre-flight checks on device:
     ```
     rauc status
     echo "pre-ota-marker" > /mnt/data/ota_test_marker
     cat /etc/os-release | grep GA_
     ```
  5. Install bundle:
     ```
     rauc install /tmp/*.raucb
     ```
  6. Verify installation:
     ```
     rauc status   # inactive slot should show "good"
     ```
  7. Reboot: `reboot`
  8. Post-update verification:
     ```
     rauc status                          # booted from new slot
     cat /etc/os-release | grep GA_       # new build info
     cat /mnt/data/ota_test_marker        # persistent data intact
     systemctl is-active telegraf fluent-bit  # services running
     cat /mnt/data/telegraf/env           # UUID + GA_ENV populated
     journalctl --list-boots              # previous boots visible
     ```
- **Expected**: All checks pass, device runs new image with persistent data intact
- **Cleanup**: `rm /mnt/data/ota_test_marker && rm /tmp/*.raucb`

### OTA-10: RAUC bundle signature validation
- **Action**: Attempt to install an unsigned/tampered bundle
- **Command**: `cp /tmp/valid.raucb /tmp/tampered.raucb && echo "x" >> /tmp/tampered.raucb && rauc install /tmp/tampered.raucb 2>&1`
- **Expected**: Installation fails with signature verification error

### OTA-11: RAUC update with insufficient space
- **Action**: Verify RAUC handles full disk gracefully
- **Command**: `rauc install /tmp/*.raucb` (monitor with `df -h`)
- **Expected**: RAUC reports clear error if space insufficient, does not corrupt current slot

### OTA-12: Services auto-populate env files after OTA
- **Action**: Delete env files before OTA, verify they're recreated on first boot
- **Command**:
  - Before OTA: `rm -f /mnt/data/telegraf/env /mnt/data/fluent-bit/env`
  - After OTA + reboot:
    ```
    cat /mnt/data/telegraf/env
    cat /mnt/data/fluent-bit/env
    ```
- **Expected**: Both env files recreated with GA_ENV and DEVICE_UUID values
