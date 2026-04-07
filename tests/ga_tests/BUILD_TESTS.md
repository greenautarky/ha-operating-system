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
- CFG-13: ga-defaults/hosts has influx fallback entry
- CFG-14: ga-defaults/hosts has loki fallback entry
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

### Device tree verification
- DT-01: Patched device tree matches known-good reference (catches silent patch failures)
- DT-02: Critical SDIO properties present (vmmc-supply, vqmmc-supply, supports-sdio, dr_mode=peripheral)
- DT-03: USB host nodes disabled (u2phy1, u2phy_host, usb_host0_ehci, usb_host0_ohci)

### WiFi configuration
- WIFI-08a: GreenAutarky-Install WiFi SSID configured
- WIFI-08b: Install WiFi low priority (autoconnect-priority=-10)
- WIFI-08c: Install WiFi PSK injected (not placeholder)
- WIFI-08d: Install WiFi file permissions 0600
- WIFI-09: ga-overlay-init copies WiFi config to overlay
- WIFI-10: WiFi config NOT in overlaid /etc/NM/system-connections/
- WIFI-11a: OpenStick WiFi key permissions 0600
- WIFI-11b: OpenStick WiFi key is 64 hex chars (256-bit)
- WIFI-11c: OpenStick WiFi key is valid hex

### HAOS overlay safety
- OVL-01: No GA content in overlaid /etc/hosts
- OVL-02: GA DNS entries in /usr/share/ga-defaults/hosts
- OVL-03: GA timesyncd.conf not in overlaid /etc/systemd/
- OVL-04: timesyncd.conf in /usr/share/ga-defaults/
- OVL-05a: ga-overlay-init.service exists
- OVL-05b: ga-overlay-init.service enabled at boot

### Source verification (cross-repo, runs when repos available)
- SRC-14a: ga-setup-pin.ts component exists
- SRC-14b: wizard STEPS includes pin
- SRC-14c: verifyGASetupPin API function exists
- SRC-14d: Core has verify_pin endpoint
- SRC-14e: Core has PIN rate limiting
- SRC-15a: ga-setup-pin has autoPin property (QR support)
- SRC-15b: wizard parses ?pin= from URL
- SRC-15c: wizard cleans PIN from URL (history.replaceState)
- SRC-15d: QR auto-inject E2E tests exist

### Version chain & freshness
- VER-01: version.json supervisor version is not "latest"
- VER-02: version.json core version is not "latest"
- VER-03: version.json tinker HA version is not "latest"
- VER-04: version.json supervisor image uses greenautarky registry (both image and images)
- VER-05: version.json core image uses greenautarky registry (both image and images)
- VER-06: version.json OTA URL points to greenautarky
- VER-07: Core image digest matches GHCR (not stale cache)
- VER-08: Frontend SHA matches frontend repo HEAD (not stale CI)
- VER-09: Supervisor image digest matches GHCR (not stale cache)
- VER-10: All addon image digests match GHCR (not stale cache)
- VER-11: Core io.hass.version label matches version.json tag
- VER-12: Frontend build date recent (< 7 days old)

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

### From ota_update (needs real device + optional RAUCB_PATH)
- OTA-01..01e: RAUC service available, booted slot, both A/B slots, status good
- OTA-02: RAUC compatible is haos-ihost
- OTA-03..03b: OS version from os-release, CPE version matches
- OTA-04..04b: Data partition mounted, supervisor data present
- OTA-05..05b: RAUC keyring and system.conf present
- OTA-06: Slot B bundle version (if installed)
- OTA-07..07b: Journal boot history survives OTA
- OTA-08: Services active after boot (telegraf, fluent-bit, netbird)
- OTA-09a..f: Full RAUC install test (requires RAUCB_PATH= env var)
- OTA-10: Tampered bundle rejected by RAUC

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

### From openstick (needs OpenStick dongle powered + in range)
- OS-01: Shared secret file exists (`/usr/share/ga-wifi/openstick-wifi.key`)
- OS-02a: Shared secret permissions 600
- OS-02b: Shared secret is 64 hex chars (256-bit)
- OS-03: HMAC-SHA256 derivation produces 16-char PSK
- OS-04a: WiFi interface wlan0 present
- OS-04: WiFi scan completed
- OS-05: OpenStick GA-* SSID detected in range
- OS-06: SSID format valid (GA-XXXX = 4 digits)
- OS-07: PSK derived for detected SSID
- OS-08: WiFi connection with derived PSK
- OS-09: Internet reachable via OpenStick (connectivity check)
- OS-10: Auto-connect script present and executable
- OS-11: Auto-connect service exists
- OS-12a: Auto-connect timer exists
- OS-12b: Auto-connect timer is active
- OS-13: Cooldown respected (future timestamp)
- OS-14: Expired cooldown cleared
- OS-15: Script exits if already connected
- OS-16: Persistent connection created by script
- OS-17a: Connection has autoconnect=yes
- OS-17b: Connection has autoconnect-priority=10
- OS-18: Connection is active on wlan0
- OS-19: Route metric is 500
- OS-20: OpenStick priority > Install WiFi priority

### Network failover chain (host-side, via serial)
- FC-01: Ethernet active (baseline)
- FC-02: OpenStick active on wlan0 (baseline)
- FC-03: Ethernet is default route (metric 100)
- FC-04: OpenStick is secondary route (metric 500)
- FC-05: OpenStick becomes default when Ethernet off
- FC-06: Internet works via OpenStick
- FC-07: Ethernet default again when re-enabled
- FC-08: OpenStick still connected (secondary)
- FC-09: Both Ethernet + OpenStick active simultaneously
- FC-10: OpenStick priority > Install WiFi priority
- FC-11: wlan0 uses openstick-auto (not Install WiFi)
- FC-12: Persistent connection file exists
- FC-13: Connection has autoconnect=yes
