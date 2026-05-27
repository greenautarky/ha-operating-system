# Changelog

All notable changes to the GreenAutarky OS (HAOS fork — `ghcr.io/greenautarky/{board}-homeassistant` + the iHost / KIB-SON image).

Versioning follows the upstream HAOS calver (`16.X.Y`) with a GA release
counter appended (`16.3.1.<N>` — `.1` was V1.1 fleet, `.2` is V1.2-clean,
etc.). The image filename `bos_ihost-16.3.1.<N>_<env>_<timestamp>.img.xz`
encodes the same tuple.

Earlier release history (pre-2026-05-27) is in the git log + the
[`ga-ihost-docs/RELEASE-*` docs](https://github.com/greenautarky/ga-ihost-docs).

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
