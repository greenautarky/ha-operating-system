# TODO

## High Priority

### Fluent-Bit Configuration
- [ ] Configure Loki endpoint (currently hardcoded to `loki.greenautarky.com` in `buildroot-external/package/fluent-bit-config/fluent-bit.conf`)
- [ ] Implement per-device UUID generation (currently placeholder `XXX`)
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
- [ ] Integrate `collect_crash_bundle.sh` with automated upload/reporting
- [ ] Document watchdog test procedures using `ga_test_wdt`

### Disk Guard
- [ ] Tune disk guard thresholds for production (currently: 300 MiB soft, 120 MiB hard)

### Image Flasher
- [ ] Add error recovery / rollback logic to `ga_flasher` for failed flashes

### Build Script (`scripts/ga_build.sh`)
- [ ] Make NetBird version (`v0.62.0`) and Go version (`1.24.10`) easier to bump
- [ ] Make Fluent-Bit output endpoints configurable via environment variables
- [ ] Validate genimage.cfg path resolution (multiple fallback searches, lines ~1389-1421)

## Low Priority

### Fluent-Bit Inputs
- [ ] Consider enabling kernel/syslog input (currently commented out)

### Documentation
- [ ] Build environment setup guide
- [ ] Development workflow / contributing guide
- [ ] Build validation checklist
- [ ] How to add new packages to the build

### CI/CD
- [ ] Define CI/CD integration strategy (if planned)
- [ ] Create integration tests for build artifacts

## Completed
- [x] Add disk guard service + timer (`ga-disk-guard.service`, `ga-disk-guard.timer`)
- [x] Add crash bundle collector (`collect_crash_bundle.sh`)
- [x] Add watchdog test helper (`ga_test_wdt`)
- [x] Add eMMC flasher (`ga_flasher`)
- [x] Optimize journald config
- [x] Add container import script for build setup
- [x] Generate SBOM in build script
- [x] Archive legal-info / licenses in build
- [x] Add `.gitignore` entries for image tarballs, build secrets, build output dirs
