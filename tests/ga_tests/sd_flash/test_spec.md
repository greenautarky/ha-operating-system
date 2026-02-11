# SD Card / eMMC Flashing Tests

## Components
- Disk image (`.img.xz`) — full partition layout (boot, rootfs A/B, data)
- Provisioning image (`_provisioning.img.xz`) — factory image with embedded update bundle
- `ga_build.sh` build artifacts
- RAUC slot layout and partition table

## Prerequisites
- Built image: `ga_output/images/gaos_*.img.xz`
- SD card (16GB+ recommended)
- Card reader or USB adapter on build host
- `xz`, `dd` or `balenaEtcher` available

## Tests

### SD-01: Image file exists after build
- **Action**: Verify build produces expected artifacts
- **Command**: `ls -lh ga_output/images/gaos_*.img.xz ga_output/images/gaos_*.raucb`
- **Expected**: Both `.img.xz` (disk image) and `.raucb` (OTA bundle) present

### SD-02: Image filename contains build metadata
- **Action**: Verify filename follows naming convention
- **Command**: `ls ga_output/images/gaos_*.img.xz`
- **Expected**: Filename format: `gaos_ihost_<variant>-<version>_<env>_<timestamp>.img.xz`
  - Example: `gaos_ihost_CoreBox-16.3_dev_20260211143022.img.xz`

### SD-03: Flash to SD card (full procedure)
- **Action**: Write image to SD card
- **Procedure**:
  1. Identify SD card device: `lsblk` (e.g., `/dev/sdX`)
  2. Decompress and write:
     ```
     xz -dc ga_output/images/gaos_*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
     ```
  3. Sync: `sync`
- **Expected**: Write completes without errors

### SD-04: Partition layout correct after flash
- **Action**: Verify partition table on flashed SD card
- **Command**: `sudo fdisk -l /dev/sdX` or `lsblk /dev/sdX`
- **Expected**: Partitions present:
  - Boot partition (FAT32)
  - Rootfs A (squashfs/EROFS)
  - Rootfs B (squashfs/EROFS)
  - Data partition (ext4)

### SD-05: First boot from SD card
- **Action**: Insert SD card into device, power on, verify boot
- **Procedure**:
  1. Insert flashed SD card into iHost
  2. Power on device
  3. Wait for boot (LED indicators or SSH availability)
  4. SSH into device: `ssh root@<device-ip>`
- **Expected**: Device boots to login prompt, SSH accessible

### SD-06: os-release contains build info
- **Action**: Verify GA build metadata after first boot
- **Command**: `grep GA_ /etc/os-release`
- **Expected**: `GA_BUILD_ID`, `GA_BUILD_TIMESTAMP`, `GA_ENV` present and match the build

### SD-07: RAUC slots healthy after fresh flash
- **Action**: Verify RAUC sees both slots
- **Command**: `rauc status`
- **Expected**:
  - One slot marked as `booted`
  - Both slots listed (rootfs.0, rootfs.1)
  - No errors or missing slots

### SD-08: Data partition mounted and writable
- **Action**: Verify /mnt/data is available on first boot
- **Command**: `mount | grep /mnt/data && touch /mnt/data/test_write && rm /mnt/data/test_write`
- **Expected**: Partition mounted (ext4), write succeeds

### SD-09: All GA services start on first boot
- **Action**: Verify all custom services are running after fresh flash
- **Command**:
  ```
  systemctl is-active telegraf
  systemctl is-active fluent-bit
  systemctl is-enabled ga-crash-marker
  systemctl is-enabled ga-boot-check
  ```
- **Expected**: telegraf/fluent-bit `active`, crash detection `enabled`

### SD-10: Env files created on first boot (no prior data)
- **Action**: Verify ExecStartPre populates env files from scratch
- **Command**:
  ```
  cat /mnt/data/telegraf/env
  cat /mnt/data/fluent-bit/env
  ```
- **Expected**:
  - `GA_ENV=dev` (or `prod` depending on build)
  - `DEVICE_UUID=unknown` (HA not configured yet, will populate after HA setup)
  - `GATEWAY_IP=<detected-ip>` (in telegraf env)

### SD-11: Network connectivity after fresh flash
- **Action**: Verify device has network access
- **Command**:
  ```
  ip route | grep "^default"
  ping -c 1 -W 5 1.1.1.1
  ```
- **Expected**: Default route present, ping succeeds

### SD-12: Provisioning image exists after build
- **Action**: Verify factory provisioning image is generated
- **Command**: `ls -lh ga_output/images/gaos_*_provisioning.img.xz`
- **Expected**: Provisioning image present (larger than base image — contains embedded .img.xz)

### SD-13: Provisioning image boots and self-updates
- **Action**: Flash provisioning image, verify it boots and has embedded bundle
- **Procedure**:
  1. Flash provisioning image to SD card (same as SD-03)
  2. Boot device
  3. Check for embedded bundle: `ls /mnt/data/images/`
- **Expected**: Device boots, `/mnt/data/images/` contains the RAUC bundle for self-provisioning

### SD-14: Re-flash over existing installation
- **Action**: Flash a new image over a device with existing data
- **Procedure**:
  1. Write marker: `echo "should-be-gone" > /mnt/data/reflash_test`
  2. Power off, re-flash SD card with new image
  3. Boot and check: `cat /mnt/data/reflash_test 2>/dev/null`
- **Expected**: Data partition is reformatted — marker file should NOT exist
  (full flash replaces entire partition layout)
