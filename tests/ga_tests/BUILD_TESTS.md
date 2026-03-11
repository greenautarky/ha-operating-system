# GA OS Test Categories

Tests are organized by where they can run. This determines when they execute
and what infrastructure they need.

## Category 1: Build-time (`build`)
Run automatically by `ga_build.sh` after a successful build.
No device or emulator needed — checks the build output tree directly.

### From config_verify
- CFG-01: telegraf.conf exists on rootfs
- CFG-02: telegraf.conf has device_label global tag
- CFG-03: telegraf.conf has uuid global tag
- CFG-06: telegraf.service has DEVICE_LABEL safe default
- CFG-07: fluent-bit.conf exists on rootfs
- CFG-08: fluent-bit.conf has device_label in record_modifier filter
- CFG-09: fluent-bit.conf has device_label in Loki output labels
- CFG-11: fluent-bit.service has DEVICE_LABEL safe default
- CFG-13: /etc/hosts has influx fallback entry
- CFG-14: /etc/hosts has loki fallback entry
- CFG-15: telegraf.service ordered after netbird
- CFG-16: fluent-bit.service ordered after netbird
- CFG-19: parsers.conf exists on rootfs
- CFG-20: parsers.conf has homeassistant parser
- CFG-21: fluent-bit.conf tail inputs use homeassistant parser
- CFG-22: fluent-bit.conf storage buffer >= 300M

### From environment
- ENV-01: Build-time ga-env.conf exists
- ENV-02: GA_ENV value is valid
- ENV-08: os-release contains build info

### From crash_detection
- CRASH-01: Services enabled (symlinks present)
- CRASH-09: Ordering correct (boot-check before crash-marker)

### From sd_flash
- SD-01: Image file exists after build
- SD-02: Image filename contains build metadata

### From disk_guard
- DG-01: Script and service installed

### Build-specific (in ga_build.sh verify_build_integrity)
- BLD-01: Disk image exists and size sane (200-2048MB)
- BLD-02: RAUC bundle generated
- BLD-03: NetBird binary present with correct version
- BLD-04: Key systemd services enabled
- BLD-05: GA build ID stamped
- BLD-06: GA env config stamped
- BLD-07: version.json references greenautarky core image
- BLD-08: Core image tag is 'latest'
- BLD-09: Data partition generated
- BLD-10: os-release has GA fields

## Category 2: Emulation (`emu`)
Can run in QEMU or container without real hardware.
Needs a booted system image but no physical iHost.

### From environment
- ENV-03: Dev build has correct defaults
- ENV-04: Prod build has correct defaults
- ENV-05: Runtime override takes precedence
- ENV-06: Rootfs config is read-only

### From crash_detection
- CRASH-02: Marker file created at boot
- CRASH-03: Clean shutdown removes marker

### From boot_timing
- BOOT-01: Boot timing script exists and is executable
- BOOT-02: Script produces valid InfluxDB line protocol
- BOOT-10: Script handles missing services gracefully

### From disk_guard
- DG-02: Timer is active and scheduled
- DG-03: Manual run — idle state
- DG-04: State file format valid
- DG-13: Timer triggers after boot
- DG-14: Script handles missing paths gracefully

## Category 3: Device (`device`)
Must run on real iHost hardware. Needs network, Docker, HA running.

### From onboarding (all)
- OB-01 through OB-12

### From telemetry (all)
- TEL-01 through TEL-12

### From network (all)
- NET-01 through NET-06

### From ping (all)
- PING-01 through PING-07

### From tailscale (all)
- TS-01 through TS-05

### From crash_detection (destructive)
- CRASH-04: Kernel panic detected
- CRASH-05: Power loss detected
- CRASH-06: Previous boot logs available
- CRASH-07: Boot list shows multiple boots
- CRASH-08: Crash log rotation

### From boot_timing (needs real boot)
- BOOT-03 through BOOT-09

### From disk_guard (needs real fs)
- DG-05 through DG-12

### From config_verify (needs running services)
- CFG-04, CFG-05, CFG-10, CFG-12, CFG-17, CFG-18

### From stress (all)
- STRESS-01 through STRESS-10

### From ota_update (all)
- OTA-01 through OTA-12

### From sd_flash (needs SD + device)
- SD-03 through SD-14

### From power_cycle (needs host-side control)
- PWR-01 through PWR-10

### From watchdog (needs real hardware)
- WDT-01 through WDT-04

### From hardware (needs real iHost hardware)
- HW-01: WiFi interface wlan0 present
- HW-02: rtw88_8723ds driver loaded without eFuse errors
- HW-03: No SDIO/MMC errors in dmesg
- HW-04: WiFi can scan networks
- HW-05: Ethernet interface eth0 present
- HW-06: Ethernet link state
- HW-07: USB subsystem functional
- HW-08: USB devices enumerated
- HW-08a: USB host port disabled (security)
- HW-08b: USB gadget serial console functional
- HW-09: Zigbee serial device present (internal UART)
- HW-10: eMMC block device present
- HW-11: Root filesystem type
- HW-12: Kernel not tainted
- HW-13: No critical driver probe failures
- HW-15: Watchdog device present
- HW-SUM: dmesg error/fail summary
