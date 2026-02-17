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
- [ ] Populate `buildroot-external/package/fluent-bit-config/parsers.conf` (currently empty)
- [ ] Add fallback output if Loki is unreachable

### OTA / RAUC
- [ ] Test full OTA update flow with signed RAUC bundles
- [ ] Verify CA certificates in `buildroot-external/ota/` are non-expired
- [ ] Document key rotation procedure

### Build System
- [ ] Document how to reproduce a build from archived configs
- [ ] Add pre-build validation for required files (CA certs, defconfig, etc.)

## Medium Priority

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

### Build Script (`scripts/ga_build.sh`)
- [ ] Validate genimage.cfg path resolution (multiple fallback searches)

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
