# TODO

## High Priority

### Dev/Prod Configuration Strategy (needs discussion)
- [ ] Define which configs/behaviors differ between dev and prod builds
  - Telegraf: endpoints, collection intervals, verbosity?
  - Fluent-Bit: log level, output targets, retention?
  - journald: log retention, max size?
  - ga-env.conf: which values drive which behavior?
- [ ] Decide: build-time baking vs runtime override strategy
- [ ] Document the dev vs prod matrix for all services

### Fluent-Bit Configuration
- [x] Populate `buildroot-external/package/fluent-bit-config/parsers.conf` (HA log + JSON parsers)
- [x] Increase store-and-forward buffer to 300M (handles Loki outages via persistent filesystem storage)

### OTA / RAUC
- [x] Point `stable.json` OTA URL to `greenautarky/ha-operating-system` (was upstream iHost repo)
- [ ] Publish first RAUC bundle as GitHub Release on `greenautarky/ha-operating-system`
  - Release tag must match `{version}` in OTA URL pattern
  - Asset filename: `{os_name}_{board}-{version}.raucb`
  - Consider CI workflow to auto-publish `.raucb` from `ga_build.sh prod` output
- [ ] Test full OTA update flow with signed RAUC bundles
- [ ] Verify CA certificates in `buildroot-external/ota/` are non-expired
- [ ] Document key rotation procedure

### Build System
- [ ] Document how to reproduce a build from archived configs
- [ ] Add pre-build validation for required files (CA certs, defconfig, etc.)

## Medium Priority

### GA Device Management Addon (`ga-device-manager`) (needs discussion)
A new HA addon for remote fleet management, accessible over NetBird.
Runs as a container with Supervisor API access (`hassio` role).

**Core features:**
- [ ] Remote OS/addon/core updates via Supervisor API
  - `POST /api/os/update`, `/api/addons/{slug}/update`
  - Staged rollout support (update one device, verify, then fleet-wide)
- [ ] Backup management
  - Trigger full/partial backups: `POST /api/backups/new/full`
  - Upload backups to remote storage (S3/NFS/NetBird peer)
  - Schedule automated backups via cron
- [ ] Addon lifecycle control
  - Start/stop/restart addons: `POST /api/addons/{slug}/start|stop|restart`
  - Install/uninstall addons remotely
  - Push addon config changes: `POST /api/addons/{slug}/options`
- [ ] Config management
  - Push GA environment changes (`ga-env.conf`)
  - Update device label, network config
  - Read/write files on `/mnt/data/` via mapped volume
- [ ] Health & fallback
  - Periodic health checks (supervisor, core, addons, disk, network)
  - Auto-restart failed services
  - Rollback to previous backup on repeated boot failures
  - Watchdog integration (reboot if management agent loses contact)
- [ ] External API
  - REST API on a NetBird-accessible port (e.g., 9100)
  - Auth: API key or mTLS over NetBird
  - Endpoints: `/status`, `/update`, `/backup`, `/addons`, `/config`, `/reboot`
  - Webhook support for fleet orchestration tools

**Architecture:**
- Language: Python (reuse HA patterns) or Go (small binary, low memory)
- Repo: `greenautarky/ga-device-manager`
- Image: `ghcr.io/greenautarky/ga-device-manager`
- Pre-baked into OS image (see "Pre-bake Add-on Container Images")
- Supervisor access: `hassio_role: manager` in addon config
- Network: host network or dedicated port mapping
- Replaces: ad-hoc SSH scripts, manual flasher interventions

### Crash & Diagnostics
- [ ] Test crash detection on device:
  - **Test 1 - Kernel panic:** `echo c > /proc/sysrq-trigger`, reboot, verify:
    - `journalctl -t ga-crash-detect -b 0` → "UNCLEAN SHUTDOWN DETECTED"
    - `cat /mnt/data/crash_history.log` → new entry with timestamp
    - `journalctl -b -1` → previous boot logs visible
  - **Test 2 - Clean reboot (control):** `reboot`, verify:
    - `journalctl -t ga-crash-detect -b 0` → "Clean boot"
    - `crash_history.log` → no new entry
  - **Test 3 - Power pull:** unplug power, verify same as Test 1
- [ ] Integrate `collect_crash_bundle.sh` with automated upload/reporting
- [ ] Document watchdog test procedures using `ga_test_wdt`

### Disk Guard
- [ ] Tune disk guard thresholds for production (currently: 300 MiB soft, 120 MiB hard)

### Image Flasher
- [ ] Add error recovery / rollback logic to `ga_flasher` for failed flashes

### DNS Entries & Handling
- [ ] **Configure NetBird DNS** in management UI:
  - Add `influx.greenautarky.com` → ga-tools NetBird IP
  - Add `loki.greenautarky.com` → ga-tools NetBird IP
  - Assign nameserver group to device peer groups
- [ ] Test NetBird DNS resolution on device after configuration (`nslookup influx.greenautarky.com`)
- [ ] Verify `/etc/hosts` fallback works when NetBird DNS is down
- [ ] Make DNS entries configurable per environment (dev vs prod endpoints)
- [ ] Consider adding health-check/retry logic for DNS-dependent services (telegraf, fluent-bit)

### Custom Core Image / Onboarding
- [x] Rebuild with `greenautarky/haos-version` URL (PR #1 merged) and verify `version.json` references `ghcr.io/greenautarky/tinker-homeassistant`
- [x] GA calver versioning scheme: use `.N` suffix (e.g. `2025.11.3.1`) — stays CALVER for AwesomeVersion
  - Do NOT use `-ga.N` (triggers SEMVER strategy, breaks comparisons)
  - Version bump checklist: ha-core workflow, haos-version/stable.json, dind-import-containers.sh
  - See `memory/registry-chain.md` for full details
- [ ] Flash and boot on iHost, verify custom onboarding appears:
  - German-language onboarding flow (Willkommen, Datenschutz, Benutzerkonto)
  - GDPR consent step
  - greenautarky telemetry preferences (Fehlerberichte, Metriken)
  - Custom info/help pages
- [ ] Write tests to verify custom core image is active on device (check container image, version string)
- [ ] Update `greenautarky/haos-version` README with stable.json field mapping documentation
- [x] **Slim down GA Core Docker image** — fixed in ha-core `66414a54` (.dockerignore for frontend-build)

### Onboarding Reset (`ga-reset-onboarding`)
- [x] Script at `buildroot-external/rootfs-overlay/usr/sbin/ga-reset-onboarding`
  - Removes ALL non-system users (including admin) from `.storage/auth`
  - Clears all entries from `.storage/auth_provider.homeassistant`
  - Deletes `.storage/onboarding` to re-trigger onboarding wizard
  - Supports `--dry-run` and `--keep-onboarding` flags
  - New tenant onboards as owner/admin (stock HA behavior)
- [x] Fork change: `homeassisant_core/homeassistant/components/onboarding/views.py`
  - Custom onboarding steps (GDPR, custom pages, analytics)
  - User creation uses stock `_user_should_be_owner()` — first user becomes owner
- [ ] Deploy updated core image with fork change to test device
- [ ] Verify full reset → re-onboarding flow end-to-end
- [ ] Clean `.storage/person` during reset — stale person entities remain after user removal
  - `ga-reset-onboarding` removes users from `auth` and `auth_provider.homeassistant` but not from `person` registry
  - HA auto-creates person entries for new users, so stale entries don't break anything, but they clutter the UI

### Tailscale Hostname Persistence
- [ ] Implement hostname persistence in addon startup (read from options or `/mnt/data/ga-device-label`)
- [ ] Update provisioning (Stage 70) to write hostname into addon `options.json`
- [ ] Update addon `DOCS.md` with hostname configuration documentation
- [ ] Deploy updated addon to devices and verify hostname survives container recreate
- [ ] Migrate devices from `vibe_addons` image (`ghcr.io/hassio-addons/tailscale`) to `ga_tailscale` image (`ghcr.io/greenautarky/ga_tailscale`)

### Build Script (`scripts/ga_build.sh`)
- [ ] Validate genimage.cfg path resolution (multiple fallback searches)
- [x] ~~Remove standalone Go toolchain workaround~~ — done, NetBird now built via Buildroot golang-package

### Pre-bake Add-on Container Images (needs discussion)
- [ ] Pre-pull add-on Docker images into the OS build (same mechanism as core/supervisor)
  - Candidates: Mosquitto, Zigbee2MQTT, iHost Hardware Control, ga_tailscale
  - Images are pre-built on GHCR — no compilation needed, just fetch + import
  - Flasher would "install" addons via HA API instantly (layers already local)
  - Needs: bump `BR2_PACKAGE_HASSIO_DATA_IMAGE_SIZE` to fit extra images
  - Needs: add addon entries to `fetch-container-image.sh` / `hassio.mk` or separate fetch step
  - Consider: pre-writing Supervisor addon config (`/mnt/data/supervisor/addons/`) to skip API step entirely

### Pre-configure GA Add-on Repository (needs discussion)
- [ ] Pre-write `/mnt/data/supervisor/store.json` with greenautarky addon repo URL
  - Supervisor auto-merges with built-in defaults (core, community, ESPHome, Music Assistant)
  - GA addons appear in store from first boot — no manual repo add needed
  - Format: `{"repositories": ["https://github.com/greenautarky/hassio-addon-repo"]}`
  - Implementation: add file to data partition during `create-data-partition.sh` or `dind-import-containers.sh`
  - Add-on store connection stays fully functional (browsing, installing, updating)

### Image Size Optimization
- [x] ~~Exclude `frontend-build/` from ha-core Docker image (-537MB)~~ — fixed in ha-core `66414a54`
- [ ] Remove unused integrations/components from custom ha-core build to reduce image size
- [ ] Review if all bundled container images (audio, multicast, etc.) are needed for iHost

### Package Updates (next major / Buildroot Go bump)
- [x] ~~Bump Buildroot Go from 1.23.12 to 1.25+~~ — done via buildroot submodule update (Go 1.25.7)
- [x] ~~Telegraf 1.30.0 → 1.38.0~~ — bumped in telegraf.mk (strict env var handling is safe, all GA env vars are strings)
- [ ] OS-Agent 1.7.2 → 1.8.x (needs Go 1.25+, Docker storage driver API, minor fixes)
- [ ] Fluent-Bit 3.2.10 → 4.x (major version, check config compat)

## Low Priority

### Fluent-Bit Inputs
- [ ] Consider enabling kernel/syslog input (currently commented out)

### Testing
- [ ] Implement automated tests from `tests/ga_tests/` test specs:
  - `crash_detection/` (9 tests) - crash marker, journald persistence, log rotation
  - `ping/` (7 tests) - native ICMP, gateway auto-detect, InfluxDB delivery
  - `telemetry/` (12 tests) - telegraf/fluent-bit env vars, UUID, rootfs configs
  - `network/` (6 tests) - static DNS, endpoint reachability, gateway detection
  - `environment/` (8 tests) - dev/prod settings, runtime override, os-release
  - `ota_update/` (12 tests) - RAUC end-to-end procedure, signature validation, config delivery, rollback
  - `sd_flash/` (14 tests) - image flashing, partition layout, first boot, provisioning image
  - `boot_timing/` (10 tests) - boot milestones, systemd-analyze, telegraf exec integration
  - `stress/` (10 tests) - CPU, memory, I/O, thermal, combined, 24h soak (stress-ng)
  - `disk_guard/` (14 tests) - thresholds, allowlist, cleanup rules, journald vacuum, lock, timer
  - `watchdog/` (4 tests) - device presence, timeout, trigger, normal operation
  - `config_verify/` (22 tests) - rootfs config content assertions, DEVICE_LABEL/UUID, DNS fallback, NetBird service ordering, parsers, storage buffer
  - `onboarding/` (7 tests) - custom core image registry, ga-tagged version, version repo URL, non-core upstream
  - `tailscale/` (5 tests) - addon running, connected, hostname matches device label, IP assigned, image registry
  - `power_cycle/` (10 tests) - HOST-SIDE: N-cycle power-off/on endurance, boot time stats, hang detection, filesystem integrity
- [ ] Test power-cycle stress test script (`power_cycle/test.sh`):
  - [ ] Validate with `--cycles 2 --off-time 3` in manual mode (basic loop)
  - [ ] Verify CSV output format and boot timing accuracy
  - [ ] Test two-phase boot detection (no false positive from stale serial buffer)
  - [ ] Test Ctrl-C produces valid partial summary
  - [ ] Test `--post-boot-check` runs PWR-04..07 via serial
  - [ ] Test `--power-api` with host-power-service.py (uhubctl)
  - [ ] Test `--power-cmd-off/on` with Tasmota or smart plug
  - [ ] Run full 100-cycle endurance test and review results
- [ ] Run `config_verify` suite on device after next RAUC OTA update to confirm deployment
- [ ] Implement `hardware/` device test suite — integration tests for hardware drivers:
  - WiFi: `wlan0` interface present, `rtw88_8723ds` probe clean (no eFuse errors in dmesg)
  - WiFi scan: `nmcli dev wifi list` returns results
  - Ethernet: `eth0` present and link up
  - USB: `lsusb` lists expected devices (Zigbee dongle, etc.)
  - eMMC: `/dev/mmcblk*` present, SMART/health check
  - Zigbee dongle: `/dev/ttyUSB0` or `/dev/ttyACM0` present
  - Kernel taint: `/proc/sys/kernel/tainted` == 0 (no tainted modules)
  - dmesg errors: no `failed`, `error`, `timeout` from critical drivers
  - Thermal: `/sys/class/thermal/thermal_zone0/temp` readable and in range
  - Watchdog: `/dev/watchdog` device present
  - SDIO: no mmc errors in dmesg (voltage sequencing OK)
  - LED control: `/sys/class/leds/` entries present (iHost-specific)
- [ ] Build-time config manifest: generate `/etc/ga-config-manifest.json` with sha256 checksums
  of critical config files (telegraf.conf, fluent-bit.conf, service files) during post-build
- [ ] Runtime manifest verification test (CFG-13+): compare deployed file hashes against manifest
- [ ] RAUC slot content verification: after RAUC install, verify inactive slot before rebooting
- [ ] Automated post-OTA smoke test: run `config_verify` suite on first boot after OTA
- [ ] Integrate ga_tests with existing labgrid/QEMU test framework

### Documentation
- [ ] Build environment setup guide
- [ ] Development workflow / contributing guide
- [ ] Build validation checklist
- [ ] How to add new packages to the build

### CI/CD
- [ ] Define CI/CD integration strategy (if planned)
- [ ] Create integration tests for build artifacts

## Completed
- [x] Bump NetBird to v0.64.4, Go to 1.25.6 (verified ARMv7 cross-compile)
- [x] Replace custom SBOM with Buildroot CycloneDX + lean container inventory
- [x] Make provisioning image opt-in (`GA_PROVISIONING=true`)
- [x] Make legal-info archive opt-in (`GA_LEGAL_INFO=true`)
- [x] Fix build log wiped by `rm -rf $OUT` in full mode
- [x] Add build success banner with version/artifact summary
- [x] Add disk guard service + timer (`ga-disk-guard.service`, `ga-disk-guard.timer`)
- [x] Add crash bundle collector (`collect_crash_bundle.sh`)
- [x] Add watchdog test helper (`ga_test_wdt`)
- [x] Add eMMC flasher (`ga_flasher`) with `--secure-erase` full wipe mode
- [x] Add SFTP support via `gesftpserver` (Dropbear has no built-in SFTP)
- [x] Add dev/prod environment flag (`/etc/ga-env.conf` + `/mnt/data/ga-env.conf` override)
- [x] Add dev/prod tag to image filenames (`ga_build.sh [mode] [dev|prod]`, default: dev)
- [x] Skip post-build artifacts for dev builds (SBOMs, config archive) — faster iteration
- [x] Fluent-bit and Telegraf use `${GA_ENV}` from ga-env.conf instead of hardcoded `prod`
- [x] Fix CycloneDX SBOM error handling (split pipe, log errors)
- [x] Fix CycloneDX SBOM empty output: clear stale `MAKEFLAGS` (jobserver FDs) before `make show-info`
- [x] Fix banner Buildroot version showing literal `$(BR2_VERSION)` (grep pattern fix)
- [x] Fix `local` keyword outside function in build banner
- [x] Pipe SBOM generation output to build log for post-build diagnostics
- [x] Optimize journald config
- [x] Add container import script for build setup
- [x] Add `.gitignore` entries for image tarballs, build secrets, build output dirs
- [x] Clean up repo: removed accidental `:56:` file, duplicate copy scripts
- [x] Add crash detection services (`ga-crash-marker.service`, `ga-boot-check.service`)
- [x] Configure journald for persistent multi-boot storage (`Storage=persistent`, 7-day retention)
- [x] Loki endpoint configured (`loki.greenautarky.com` with static DNS)
- [x] Per-device UUID loaded from HA `core.uuid` via env vars (Telegraf + Fluent-Bit)
- [x] Configs run from rootfs `/etc/` (OTA-updatable), per-device values via environment
- [x] Fix telegraf influxdb password (stray `^`)
- [x] Fix fluent-bit UUID parsing (same `grep -o` fix as telegraf)
- [x] Use local time instead of UTC for build timestamps
- [x] Add network connectivity monitoring (`inputs.ping` with auto-detected gateway)
- [x] Fluent-Bit endpoints configurable via env vars (removed from build script TODO)
