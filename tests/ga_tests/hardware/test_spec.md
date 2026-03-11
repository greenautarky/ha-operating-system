# Hardware Driver Integration Tests

## Purpose

Verify that all critical hardware drivers on the Sonoff iHost (RV1126) probe
successfully and that hardware peripherals are functional. These tests catch
regressions from kernel updates, device tree changes, and firmware issues.

## Category

`device` — requires real iHost hardware. Cannot run in QEMU.

## Test IDs

| ID | Description | What it checks |
|----|-------------|----------------|
| HW-01 | WiFi interface present | `ip link show wlan0` — RTL8723DS SDIO driver probed |
| HW-02 | WiFi driver loaded cleanly | `dmesg` has `rtw_8723ds` without `failed to dump efuse` |
| HW-03 | No SDIO/MMC errors | No `error`, `failed`, `timeout` on `mmc1` in dmesg |
| HW-04 | WiFi can scan | `nmcli dev wifi list` returns results (skipped if wlan0 absent) |
| HW-05 | Ethernet interface present | `ip link show eth0` |
| HW-06 | Ethernet link state | Reports `operstate` (up/down) |
| HW-07 | USB subsystem functional | `/sys/bus/usb/devices/` is populated |
| HW-08 | USB devices enumerated | Lists USB devices via `lsusb` or sysfs fallback |
| HW-08a | USB host port disabled | No EHCI/OHCI host controller registered (security) |
| HW-08b | USB gadget functional | Serial console gadget (dwc3 peripheral mode) working |
| HW-09 | Zigbee serial device | Internal UART `/dev/ttyS3` (EFR32 at ff580000) |
| HW-10 | eMMC block device | `/dev/mmcblk*` present |
| HW-11 | Root filesystem type | Reports mount type (squashfs/erofs expected) |
| HW-12 | Kernel not tainted | `/proc/sys/kernel/tainted` == 0 |
| HW-13 | No critical driver errors | No `probe.*failed` or `driver.*error` in dmesg (excl. known) |
| HW-15 | Watchdog device present | `/dev/watchdog*` exists |
| HW-SUM | dmesg error summary | Count of `error`/`fail` lines in dmesg (informational) |

## Running

```bash
# Via SSH (device must be network-reachable):
./tests/run_device_tests.sh --ssh root@<IP> --port 22222 --suites hardware

# Via serial (preferred — works even if network is broken):
./tests/run_device_tests.sh --serial <N> --suites hardware

# Via runner:
./tests/run_device_tests.sh --runner <N> --suites hardware

# Via Claude Code skill:
/device-test ssh <IP> --suites hardware
/device-test serial <N> --suites hardware
```

## Serial mode notes

Serial is the recommended transport for hardware tests because:
- Works even when WiFi/Ethernet drivers are broken
- Available immediately after boot (no SSH/network dependency)
- Captures early boot dmesg output

## When to run

- After every kernel version bump
- After device tree patch changes (especially SDIO, PMU, USB nodes)
- After firmware package updates (linux-firmware, rtl8723ds-bt)
- As part of post-flash validation before provisioning

## Known issues

- HW-04 (WiFi scan) may fail if no APs are nearby or if WiFi regulatory domain is not set
- HW-09 (Zigbee) checks internal UART `/dev/ttyS3` only (EFR32 on iHost)
- HW-13 excludes `rtw_8723ds` from the error grep to avoid false positives from the eFuse
  error that may appear briefly during driver retry
