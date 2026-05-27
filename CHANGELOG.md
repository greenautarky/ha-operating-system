# Changelog

All notable changes to the GreenAutarky OS (HAOS fork — `ghcr.io/greenautarky/{board}-homeassistant` + the iHost / KIB-SON image).

Versioning follows the upstream HAOS calver (`16.X.Y`) with a GA release
counter appended (`16.3.1.<N>` — `.1` was V1.1 fleet, `.2` is V1.2-clean,
etc.). The image filename `bos_ihost-16.3.1.<N>_<env>_<timestamp>.img.xz`
encodes the same tuple.

Earlier release history (pre-2026-05-27) is in the git log + the
[`ga-ihost-docs/RELEASE-*` docs](https://github.com/greenautarky/ga-ihost-docs).

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-27 second update

Second sweep today: bake more of the ga-flasher-py provisioning chain into the
OS image so fresh-flashed devices come up self-sufficient. Pairs with the
morning's SSH bake.

### Added — NetBird auto-registration on first boot (stage 40 → baked)

- `secrets/netbird-setup-key.txt` (gitignored) → injected into rootfs at
  `/usr/share/ga-netbird/setup-key` (mode 0600) by new post-build hook
  `buildroot-ihost/board/sonoff/ihost/post-build.d/88-netbird-setup-key.sh`.
- New first-boot service `ga-netbird-register.service` runs
  `/usr/libexec/ga-netbird-register` after netbird.service comes up. Calls
  `netbird up --setup-key …` once; idempotent (skips when daemon is already
  past NeedsLogin). `Restart=on-failure` covers the case where first boot
  comes up before WiFi associates.
- `ConditionPathExists=/usr/share/ga-netbird/setup-key` guard means the
  unit cleanly no-ops on devices built without the key (build still
  succeeds, just devices need manual `netbird up` later).
- **Replaces ga-flasher-py stage 40** for the fleet-default path. Stage 40
  can be deleted once we've validated on a few canaries.

### Added — `ga-ha-init`: HA fleet-default configuration on first boot (stage 69 most + 92)

New `/usr/libexec/ga-ha-init` (run via `ga-ha-init.service`) applies the
fleet-wide deterministic parts of HA configuration on first boot, gated
by an idempotency marker at `/share/.ga-ha-init-applied`:

- **DNS**: `fallback=false`, explicit servers `1.1.1.1` + `1.0.0.1` —
  prevents the DoT-on-RFC1918-PTR 180% CPU spike on captive WiFi.
- **Addon watchdog**: enabled for installed GA addons (`ga_manager`,
  `ga_zigbee2mqtt`, `ga_mosquitto`, …) — auto-restart on crash.
- **Timezone**: `Europe/Berlin`. Operator override at runtime persists
  via the `/etc/localtime` bind mount.
- **Weather location**: Met.no, Berlin (52.5200, 13.4050). UI override
  always wins.
- **`updater.json`**: `auto_update=false` — fleet OTA is operator-driven
  via push-ota.sh + RAUC, never automatic. Prevents incidents like
  `incident_ga1_hang_2026_05_06.md`.

**Replaces** the fleet-wide deterministic parts of `ga-flasher-py` stages
69 + 92. The per-device parts of stage 69 (admin password) stay in the
provisioner because they're per-device by definition.

### Added — `ga-emmc-erase`: forced SD-only boot (stage 35 → baked)

New `/usr/libexec/ga-emmc-erase` (run via `ga-emmc-erase.service` BEFORE
`hassos-supervisor.service` to avoid I/O contention) wipes the eMMC on
first boot. Forces the iHost to always boot from SD on subsequent
power-cycles (the bootrom can intermittently chain to eMMC factory firmware
when SD has a transient I/O glitch).

Safety:

- Refuses to run if root is NOT on `mmcblk2` (SD) — prevents bricking
  a device that's somehow booted off eMMC.
- `blkdiscard` first (fast hardware TRIM); falls back to `dd` zero-fill
  of the first 16 MiB if blkdiscard fails (corrupts partition tables,
  same effect).
- Idempotency marker `/mnt/data/.ga_emmc_erased` with method + epoch +
  device — one-shot per device lifetime.

**Replaces ga-flasher-py stage 35.**

### Removed (still need a ga-flasher-py PR to drop the stages)

These stages are now redundant — the responsible feature lives elsewhere.
Tracking removal as a follow-up PR to ga-flasher-py (not in this commit
since it touches a different repo):

- **Stage 91 (reset-onboarding)** — redundant with `ga_manager` converge
  step 9 ("Arm the onboarding wizard — only if HA onboarding is still
  pending"). The custom_component `greenautarky_onboarding` is already
  baked into the OS overlay; ga_manager re-arms on every converge.
- **Stage 62 (update-zigbee-dongle)** — redundant with `ga_manager`
  converge step 5 (tiered pre-check shipped today as 0.22.3). Wins via
  Tier-0 MQTT bridge/info read = zero outage on devices already at
  baseline firmware.
- **Stage 45 (setup-wifi)** — was a TODO stub; the `GreenAutarky-Install`
  install/factory WiFi fallback is baked via `ga-overlay-init`. Customer
  home-WiFi mechanism is a separate design problem (`/share/customer-wifi.*`?)
  — filed as a memory todo for later.

### Tests — new build-time and device-time coverage

Build tests (`tests/ga_tests/run_build_tests.sh`):

- **NB-REG-01..05** — register script + unit + ConditionPathExists guard +
  Restart=on-failure + key file perms (when secret was baked).
- **HA-INIT-01..06** — ga-ha-init script + unit + DNS/watchdog/tz/weather/
  auto-update content checks + marker logic + ordering after supervisor +
  enabled at boot.
- **EMMC-ERASE-01..05** — script + unit + safety-check-present +
  marker-guarded + ordering before supervisor + enabled at boot.

Device tests (new categories under `tests/ga_tests/`):

- **`netbird_reg/test.sh`** (NB-REG-D-01..07) — script present, service
  active, daemon NOT NeedsLogin, NetBird IP assigned, Management plane
  connected.
- **`ha_init/test.sh`** (HA-INIT-D-01..10) — service active, marker written,
  DNS `fallback=false`, Cloudflare servers present, auto-update OFF,
  timezone Europe/Berlin, addon watchdog enabled, idempotent re-run guard.
- **`emmc_erase/test.sh`** (EMMC-ERASE-D-01..07) — service active, marker
  with method= field, /dev/mmcblk0 first 64 KiB is zeros, root still on
  mmcblk2 (SD).

### Provisioner shrinkage

After this commit + the morning SSH bake + tomorrow's planned bakes (50,
61, 65, 70 Tailscale), ga-flasher-py's 43 stages collapse to ~21
irreducible per-device + infrastructure stages. Audit in
`memory/feedback_*` and the V1.2-CLEAN-REBUILD doc.

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-27 update

This release is being iterated on the `ga/v1.2-clean-rebuild` branch and
ships as `bos_ihost-16.3.1.2_prod_<timestamp>.img.xz`. Two earlier
build-iteration tracks (the bake-vibe_addons + ga-bootstrap chain
2026-05-22..26) are documented in their commits — entries here cover the
deltas since the last commit on this branch (`6c7b71c62`, 2026-05-26).

### Added — operator SSH key baked into the image

- **`buildroot-external/rootfs-overlay/usr/share/ga-ssh/authorized_keys`** —
  new file on the rootfs containing the GA operator's SSH pubkey
  (`HomeassistantGreen0.pem`). Source of truth for keys that should reach
  every freshly-flashed device. Multi-line; lines starting with `#` are
  comments, one OpenSSH pubkey per line.
- **`buildroot-external/rootfs-overlay/usr/libexec/hassos-overlay`** —
  extended to seed `/mnt/overlay/root/.ssh/authorized_keys` from the
  baked file on first boot. Guarded by `[ ! -f ]` so operator-added keys
  persist across reboots and slot swaps. Script header was also
  expanded with an architecture comment block explaining the
  rootfs / overlay / bind-mount split — the why-this-script-exists
  background that wasn't documented anywhere else.

**Why:** HAOS dropbear has `ConditionFileNotEmpty=/root/.ssh/authorized_keys`.
`/root/.ssh` is bind-mounted from `/mnt/overlay/root/.ssh` (the overlay
partition, sdc7 on iHost), which is empty on a freshly-flashed device.
Without the seed step, dropbear NEVER starts on first boot and the device
is unreachable except via serial console. Discovered live on KIB-SON-31
2026-05-27 — device looked healthy (`.ga_os = v1.2-clean`, `.ga_converged`
present, supervisor up, addons running) but port 22222 was always refused.

See [[serial-login-v12-clean]] memory for the broader serial-vs-SSH
context this fills.

### Tests — new build-time + device-time coverage

Build tests in [`tests/ga_tests/run_build_tests.sh`](tests/ga_tests/run_build_tests.sh):

- **SSH-01..05** — operator SSH key baked + correctly seeded:
  - SSH-01: `/usr/share/ga-ssh/authorized_keys` baked on rootfs
  - SSH-02: file contains ≥ 1 valid OpenSSH pubkey line
  - SSH-03: file perms are safe (0644 / 0640 / 0600 / 0400)
  - SSH-04: hassos-overlay references both source + destination paths
  - SSH-04b: hassos-overlay seed is guarded with `[ ! -f ]`
  - SSH-05: dropbear unit's `ConditionFileNotEmpty` invariant unchanged
- **BS-RETRY-01..02** — ga-bootstrap exponential-backoff retry for
  `ha store add` (regression guard for commit `9b6c28198`):
  - BS-RETRY-01: exact backoff sequence (`0 10 30 60 120 240`)
  - BS-RETRY-02: `addon_repo_present` verification after `ha store add`
- **BS-JQ-01..02** — ga-bootstrap `addon_installed` checks version VALUE
  not KEY (regression guard for commit `feba8fa12`):
  - BS-JQ-01: jq pattern `.data.version // .version` present
  - BS-JQ-02: broken `grep -q '"version"'` pattern absent
- **NB-INT-01..02** — NetBird binary integrity (regression guard for
  commit `11038a1ef`):
  - NB-INT-01: NetBird rootfs binary embeds expected `NETBIRD_TAG`
  - NB-INT-02: `scripts/ga_build.sh` uses `grep -a` (not the broken
    `strings | grep` pipe that silently misses non-loadable ELF sections)

Device tests in [`tests/ga_tests/ssh_access/test.sh`](tests/ga_tests/ssh_access/test.sh):

- **SSH-D-01..13** — operator SSH actually works on the running device:
  source-of-truth on rootfs, overlay seed presence + perms, content
  match between rootfs and overlay, bind-mount active, dropbear up,
  `ConditionResult` SAT, listener on port 22222, banner exchange.

### Fixed — root-cause of "fresh-flash device unreachable via SSH"

Devices flashed prior to this commit boot fine, converge fine, register
with NetBird, but dropbear never starts → port 22222 closed forever.
**Operator-side mitigation for already-deployed devices**: manually
seed `/mnt/overlay/root/.ssh/authorized_keys` via SD-mux + a `sudo install`
write. From this build forward, no manual seed is needed.

### Changed — NetBird bumped 0.66.2 → 0.71.4

Five minor versions, ~60 days of upstream changes. The only release in
the window with non-empty release notes was **0.68.0**:

- Added **NAT-PMP/UPnP support** (`pull/5202`) — material win for
  residential NAT'd iHost devices; clients can now punch holes
  themselves instead of always going through `relay.netbird.io`.
- `[client] Add TCP DNS support for local listener` — only matters
  if NetBird's local DNS is in use.
- Various daemon stability fixes (SSH server deadlock, network
  collection on down interfaces, etc.) — not directly used by us.

0.69.0, 0.70.0, 0.71.0, 0.71.4 have empty release notes; we're
trusting the version number. Bump motivated specifically by
KIB-SON-31's "NetBird stuck Connecting" failure observed today —
hypothesis is that one of the daemon-stability fixes between 0.66
and 0.71 may improve handshake reliability. Will be re-tested
against KIB-SON-31 on this image's first flash.

Updated in three places, all kept in lock-step by `ga_build.sh`'s
NetBird version-consistency check (which would fail the build if any
of them drift):
- `scripts/ga_build.sh` — `NETBIRD_TAG="${NETBIRD_TAG:-v0.71.4}"`
- `buildroot-external/package/netbird/netbird.mk` — `NETBIRD_VERSION = refs/tags/v0.71.4` + the embedded `-X version.version=0.71.4` ldflag
- `scripts/ga_build.sh` comment block (default-value documentation)

NB-INT-01 (added above) auto-tracks the bump — it sources the
`NETBIRD_TAG` line through bash and `grep -qaF`s the result against
the rootfs binary, so any future bump that fails to update one
of the three places will fail NB-INT-01 too.

### Notes

- The pubkey baked in is the existing `HomeassistantGreen0.pub`. To add
  another operator's key, edit
  `buildroot-external/rootfs-overlay/usr/share/ga-ssh/authorized_keys`
  (one pubkey per line) and rebuild — already-deployed devices keep their
  existing `authorized_keys` (the seed is non-destructive).
- This is a **rootfs-only change** — no Core / Supervisor / addon image
  bumps. RAUC OTA from any V1.2-clean device to this build is in-place
  (NetBird binary swap survives a RAUC slot-flip; daemon restart
  automatic via systemd unit re-enable on first boot of the new slot).
