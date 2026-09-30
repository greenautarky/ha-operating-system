# Changelog

All notable changes to the GreenAutarky OS (HAOS fork — `ghcr.io/greenautarky/{board}-homeassistant` + the iHost / KIB-SON image).

Versioning follows the upstream HAOS calver (`16.X.Y`) with a GA release
counter appended (`16.3.1.<N>` — `.1` was V1.1 fleet, `.2` is V1.2-clean,
etc.). The image filename `bos_ihost-16.3.1.<N>_<env>_<timestamp>.img.xz`
encodes the same tuple.

Earlier release history (pre-2026-05-27) is in the git log + the
[`ga-ihost-docs/RELEASE-*` docs](https://github.com/greenautarky/ga-ihost-docs).

---

## Unreleased — the SSH certificate plane and the USB host lock hold on devices updated over the air

A device that reaches a BOSv1.4.0+ image by an OTA update keeps two files its
first image wrote: the overlay `/root/.ssh/authorized_keys` (seeded only when
absent) and `/mnt/boot/cmdline.txt` (restored by the RAUC boot-slot hook). Both
are now enforced by files the update replaces, on every boot, with no
migration step.

### Changed — sshd reads the baked break-glass key first and refuses the pre-cut key

`post-build.d/87-ssh-cert-plane.sh` (BOSv1.4.0+ only) now also bakes:

- `AuthorizedKeysFile /usr/share/ga-ssh/authorized_keys /root/.ssh/authorized_keys`
  in `50-ga-cert-plane.conf` — the read-only break-glass file is read first, so
  break-glass works whatever the overlay holds; overlay entries stay valid.
- `RevokedKeys /etc/ssh/ga_revoked_keys`, installed from the committed
  `buildroot-ihost/board/sonoff/ihost/ssh-revoked-keys` (public keys only). It
  holds the pre-cut fleet-wide key; sshd refuses it in any authorized_keys
  file. The hook fails the build if the list lacks that key (pinned
  fingerprint), holds a non-key line, or lists the break-glass key.
- `sshd.service.d/zz-ga-cert-plane.conf`, which resets the unit's
  `ConditionFileNotEmpty` to the baked break-glass file.

The overlay file is not modified, so a fallback to an older slot keeps the
access that image was built with.

`ga-ssh-posture` judges the EFFECTIVE sshd configuration (first value wins,
`Include`s in place, `Match` blocks excluded): `ca` needs a trusted CA and the
pre-cut key either absent from every `AuthorizedKeysFile` or listed by
`RevokedKeys`. An `AuthorizedKeysCommand` or an unreadable revocation list
reads `shared`. The `GA_SSHD_CONFIG_DIR` and `GA_AUTHORIZED_KEYS` test
overrides are gone (`GA_SSH_ROOT_HOME` replaces the latter).

### Changed — the USB host lock is appended by boot.scr

`uboot-boot.ush` appends `usbcore.authorized_default=0` after `${cmdline}` for
both slots (set after `haos-config.txt` is imported). The kernel keeps the last
value, so a device `cmdline.txt` without the flag, or with `=1`, still boots
with the host port closed. The allowlist (`/usr/share/ga-usb-allowlist` +
`80-ga-usb-authorize.rules`) is unchanged. `boot.scr` lives on the shared boot
partition, so a fallback slot boots with the lock as well.

### Gates

- Build: new `SSH-10` (first `AuthorizedKeysFile` is the baked file, the
  revocation list holds the pre-cut key and not break-glass, unit condition
  names the same file).
- `tests/gates/ssh_cert_plane/sshd_dryrun.sh` now models an OTA-updated
  overlay (pre-cut seed, no break-glass): break-glass accepted from the baked
  file, a listed key refused by reason `revoked by file`, `sshd -T` values,
  posture `ca` with a no-`RevokedKeys` control reading `shared`, and no
  revocation-list parse errors in the sshd log.
- `tests/gates/ssh_cert_plane/selftest.sh`: `SSH-10` both ways; the hook
  refuses a broken revocation list.
- `tests/gates/ssh_posture/selftest.sh`: effective-config cases both ways.
- New `tests/gates/ota_usb_lock/selftest.sh`: the live `rauc-hook` on a
  pre-lock `/mnt/boot`, then the kernel command line evaluated from the live
  boot script (CI: lint workflow).
- Device: `SSH-D-24` redefined (sshd reads the baked break-glass file first),
  new `SSH-D-27/28/29`, new `HW-08a3` (`/proc/cmdline`); `SSH-D-06` is
  shared-plane only. These are meant for OTA-updated canaries as well as
  clean flashes.

---

## Unreleased — OS updates refuse a bundle older than the running GA release

### Added — a release floor for every OS install, enforced on the device

Every bundle now carries the GA release of the rootfs inside it in its
manifest (`[meta.ga] release=BOSv1.4.0-rc2`, taken from the same
`/etc/ga-release` that ships in the bundle). The image declares a RAUC system
`pre-install` handler, `/usr/lib/rauc/ga-release-floor`, which runs from the
*running* rootfs for every install path (Supervisor, `ga-rauc-install`, a
manual `rauc install`) after the signature check and before any slot is
written. It refuses a bundle whose release is older than `/etc/ga-release`,
and a bundle that carries no release at all (everything built before this
change). Equal and newer install as before.

Order: `BOSvX.Y.Z-devN < BOSvX.Y.Z-rcN < BOSvX.Y.Z`, numeric per field — a
final release sorts after its candidates, which `sort -V` gets wrong. The HAOS
version cannot serve here: it has been `16.3.1.9` for every bundle since
BOSv1.2.15.

An operator can install one older bundle on purpose, as root at a terminal on
the device: `ga-rauc-install-older <bundle.raucb>`. It asks for the bundle's
release to be typed back and leaves a one-shot token in a root-only directory
under `/run`, bound to that release and valid for 15 minutes. There is no
other override; the fleet dispatch path cannot carry one.

`ga-rauc-install` now accepts only `BOSvX.Y.Z` or `BOSvX.Y.Z-rcN` as a
release label (or none, for the version-only slot) and refuses anything else
instead of silently falling back to the version-only slot.

### Transition and rollback

- The first bundle with the release installs on every current device: their
  images have no handler, and RAUC (1.13 in every image since 2025-07)
  ignores `meta.*` groups it has no use for.
- From then on a device accepts the same or a newer release only. **Going
  back to an older release through the fleet (`rollback.yml`) is refused on
  such a device** — roll forward with a new, higher release, switch back to
  the other slot (`rauc status mark-active other`), or install per device with
  `ga-rauc-install-older`. See `docs/RAUC-SLOTS.md`.
- Release labels must only grow: a bake that reuses an older label produces a
  bundle every device above it refuses.

### Tests

`tests/gates/rauc_release_floor/selftest.sh` (78 checks, CI): handler verdicts
against manifests rendered from the live template, under the host shell and
busybox; the override in every shape it must refuse and the one it must honour;
build gate RFLOOR-01/02 over fixture outputs; the `ga-rauc-install` label.
`rauc_e2e.sh` (CI): the live handler behind a real `rauc service` — refused
installs abort before a slot is written, a handler-less system installs a
release-carrying bundle, and a real RAUC loads the live `system.conf`.

## Unreleased — ADR-0019 step 2: the SSH certificate plane (BOSv1.4.0+ only)

### Added — a BOSv1.4.0+ image trusts an offline user CA instead of a shared key

Selected by the image's release marker alone: **below BOSv1.4.0 nothing
changes** (no CA directive, no principals, the shared plane exactly as rc47
shipped it), even if CA keys are present in the build's secrets mount.

At or above the cut, `post-build.d/87-ssh-cert-plane.sh` reads two PUBLIC keys
from the read-only secrets mount (`${GA_SECRETS_DIR}/ssh/ga_user_ca.pub`, 1–2
lines — one per hardware token — and `ga_breakglass.pub`, exactly one) and
bakes: the CA public key, `sshd_config.d/50-ga-cert-plane.conf`
(`TrustedUserCAKeys` + `AuthorizedPrincipalsFile /etc/ssh/principals/%u`), and
an `authorized_keys` holding only the break-glass key. `sshd_config` now
`Include`s `sshd_config.d/*.conf` first. A missing, placeholder, duplicated or
unparseable key fails the build — in the preflight (`ga_build.sh`, seconds) and
again in the hook.

Principals: `ga-sshd-prepare` writes the hardware serial as the anchor (never
`/etc/machine-id`); `ga-ssh-principal-label` (path unit on ga_manager's own
data directory, pinned slug:
`/mnt/data/supervisor/addons/data/99f1cad4_ga_manager/ga-ssh-principal-label`)
applies the fleet label `KIB-SON-XXXXXXXX` written by ga_manager's REST-only
`ssh-principals-write` worker (ga_manager ≥ 0.217.0); `ga-ssh-principals`
validates both and rebuilds the file atomically. The principals bind mount is *wanted*, not required: if it
fails, sshd still starts for break-glass. `ga-enroll` publishes the host public
key in the enrol-state bridge (certificate plane only) for the fleet-manager
host-key register.

Label hardening (before the first BOSv1.4.0 rc): the principals label is read
from ga_manager's own data directory and must match this device. The host
requires a regular file (no symlink), reads at most 32 bytes, validates the
shape, and — when `/mnt/data/ga-device-label` exists — requires the label to
equal it (without that file it accepts a shape-valid label and logs why).
Refused values are logged by length only, never echoed. The oneshot has a
`TimeoutStartSec`. The `/share/ga-ssh-principal-label` path is no longer read.

Ops: `scripts/ops/ga-sign-ssh-cert.sh` (YubiKey PIV via PKCS#11; file CAs only
for tests; label + anchor principals; ≤24 h; ledger + fleet-manager mirror) and
`scripts/ops/ga-ssh-cert-plane-verify.sh` (the login matrix against a device).

Gates: `SSH-05/06` read the drop-ins sshd actually includes; new `SSH-09`
(exactly one static key, principals plumbing present). Self-tests:
`tests/gates/ssh_principals`, `tests/gates/ssh_cert_plane/selftest.sh` (the
hook, both ways, through the live build gate) and
`tests/gates/ssh_cert_plane/sshd_dryrun.sh` (a real sshd with throwaway CAs:
accept/refuse asserted by the reason sshd logs). Device: `SSH-D-19..26`.

---
## Unreleased — Core 2026.8.2 from the GA armv7 build (planned BOSv1.3.0-rc53)

### Changed — Core moves from the frozen upstream armv7 image to the GA armv7 build

Upstream stopped building Home Assistant Core for armv7 in late 2025; the
fleet's stock image stayed at 2025.11.3. Core now comes from
`ghcr.io/greenautarky/home-assistant-armv7` (greenautarky/ga-core-armv7),
unmodified upstream source built for armv7, pinned at `2026.8.2`.

- `version.yaml` `homeassistant_core` 2025.11.3 → 2026.8.2; `expected.env` regenerated.
- `hassio.mk` refuses, at configure time: the upstream Core image, a Core tag
  older than 2026, an image without `io.hass.version`/`io.hass.machine` or the
  s6 `/init` entrypoint (`check-core-image.sh`, fixtures in
  `tests/gates/core_image/`), and a channel Core that differs from the
  `version.yaml` pin.
- The bake seeds the Core image into `updater.json`, so a fresh device's
  Supervisor names the right image before it has read the channel.
- Build tests: REG-02/VER-05/XVER-03 expect the GA image, BLD-CORE-FLOOR
  refuses pre-2026 tags, VER-07/VER-11 find the Core tar by name + tag (the
  old glob never matched the GA name and skipped). On-device OB-01/OB-02 follow.

rc53 is a **dev-channel canary image**: the defconfig switches to
`BR2_PACKAGE_HASSIO_CHANNEL_DEV`, and the bake reads haos-version `dev.json`
(beta plus Core 2026.8.2 and Supervisor 2025.11.5.4, whose default Core image
follows the channel). No fleet device polls dev; `beta.json` is unchanged.
Switching this line back to beta is a separate change once 2026.x is proven
and promoted.

## Unreleased — rides in the next rc after rc29

### Fixed — a cut-off weekly digest no longer reaches the team as if complete

`scripts/ops/weekly_digest.py` returned whatever text the model sent, without
checking why it stopped. An answer cut at the token limit (HTML ending mid-list)
or a refusal (no text) was posted to Odoo chatter and the run exited 0. It now
treats any stop other than a normal end, and any empty answer, as a failure, so
the existing fallback posts the raw PR list with a WARN line. The token cap goes
from 1800 to 16000 so a normal week does not hit it. `release.sh` commit
trailers name the current model. Test: `scripts/ops/test_weekly_digest.py`.

### Added — the device declares its fleet environment on enrolment (ADR-0027 D4)

Two fleet-managers now run on the services host, production and staging, one
port apart. Which one a device belongs to is provisioned data: `GA_FLEET_ENV`
in `ga-services.conf` (normally in the `/mnt/data` override, next to the
staging port). **Absent means production**, so the baked file does not set it.

`ga-enroll` resolves it and sends `fleet_env` in the `/api/enroll` payload and
in the `/share` enrol-state bridge (next to `ga_env`, the build mode — a
different fact). The fleet-manager accepts the field since 0.125.0, compares it
with its own environment, badges or refuses a misrouted device, and never
releases one. A value that is neither `prod` nor `staging` is refused on the
device, before any request — a typo in the override must not quietly enrol a
device into the wrong fleet.

Tests: `tests/ga_tests/enroll_env/test.sh` (host-side, CI) drives the real
script with a stub `curl` and asserts the payload, the bridge and the refusal;
red-proven against the pre-field script. `CFG-53` checks the shipped script on
the device.

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-06-24 (edge-buffered telemetry + iHost LED bake)

Telemetry-survivability session (PRs #100–#108 on master; the telegraf 1.38
revert PR #109 is the companion fix). Pairs with ga_manager 0.50→0.53,
fleet-manager `influx_creds` autopush, and ga-bootstrap 1.2.8. See
[ADR-0001 / ADR-0002] and the
[session note](https://github.com/greenautarky/ga-ihost-docs) for the full
write-up.

### Added — host-firewall control plane (prepared, DEFAULT OFF) (Odoo #581 / #225)

A boot-time nftables gate that can keep blocked services off the customer LAN
while the NetBird mesh + loopback stay reachable — **prepared, default OFF,
inert until enabled.** Pairs with ga_manager 0.94.0 (`firewall` config option →
`/share` markers) and fleet-manager 0.71.0 (status surfacing).

- `usr/libexec/ga-firewall-gate` + `ga-firewall.service` (enabled via the
  multi-user wants symlink), modelled on the `ga-bluetooth-gate` marker pattern.
  Enable sources: the fleet marker `/mnt/data/supervisor/share/ga-firewall-enabled`
  (+ `ga-firewall-policy.json`) or the manual `/mnt/boot/ga-firewall`. **With
  neither present the table is flushed → every port stays exposed as before.**
- `BR2_PACKAGE_NFTABLES=y` (both iHost defconfigs) ships the `nft` CLI for the
  atomic `nft -f` ruleset load. Adds the tool without changing behavior.
- Two-chain ruleset: `input` filters HOST services (dropbear SSH :22222);
  `forward` filters DNAT'd published container ports (HA Core :8123,
  ga_manager :8099, observer :4357, Mosquitto :1883, InfluxDB :8086) — an
  input-only filter would silently miss the container ports.
- **Fail-safe by design:** `policy accept` (targeted-deny — only services set
  `false` in the policy get a drop); loopback + `wt0`/`tailscale0` mesh accepted
  FIRST in every chain as a hard invariant (never lock out the recovery path,
  even if the policy blocks everything); `nft -f` failure deletes the table
  (fail-open). Verified locally against nftables v1.1.3 + a sandbox logic run.
- On-device test suite `tests/ga_tests/firewall/test.sh` (control-plane always;
  ruleset-generation opt-in via `GA_FW_ENFORCE_TEST=1` on a BENCH device;
  reachability permutations documented as E2E). The hardening flip (block SSH +
  observer from the LAN) is then a per-device config change, not a code change.

### Added — edge-buffered telemetry (signal survives outage + reboot) (#100)

On-device telegraf now disk-buffers metrics so a network or InfluxDB outage —
or a reboot — no longer drops the signal.

- **Disk store-and-forward** — `buffer_strategy = "disk_write_through"` with an
  on-`/mnt/data` buffer directory (ext4 persistent partition, survives the
  ZRAM `/var` wipe across reboot). Native to telegraf since 1.35.
- **SD-friendly flush** — 300 s flush interval to keep eMMC/SD write
  amplification low while still bounding worst-case data loss.
- **`inputs.temp`** — adds CPU/SoC temperature to the metric set.
- **`inputs.file` signal file-drop** — telegraf tails the ga_manager
  network-signal file drop (RSSI / link state), so radio health rides the same
  buffered pipeline. Pairs with ga_manager 0.51.0 (#102).

### Added — per-device InfluxDB write credential (ADR-0002) (#103, #106)

Closes the
[InfluxDB write-password gap](https://github.com/greenautarky/ga-ihost-docs)
(the shared `device_writer` password was never provisioned by the OS or the
flasher and was lost on every telegraf restart → 401 → dropped metrics).

- `telegraf.service` `ExecStartPre` now **reads the fleet-delivered per-device
  write credential** (`dev_<KIB-SON>`, identity-derived per ADR-0002) and
  exports it into the telegraf runtime env, so the write user survives
  restart/reboot.
- **`skip_database_creation = true`** — the per-device user is write-only and
  cannot create the database; this stops telegraf from erroring on the DDL it
  isn't authorised to run.
- CFG-29 build test switched to `grep -qF` for the literal `${INFLUX_USER}`
  needle (BRE choked on `${}`) (#104).

### Changed — baked addon / component pins

- **ga_manager → 0.53.0** (#107) — iHost LED state driver (also picks up
  0.50–0.52: influx-creds-write, signal file-drop, edge-telemetry support).
- **greenautarky-onboarding → 1.0.4** (#108) — customer-facing LED on/off
  endpoint (`GALedConfigView`), so the customer can disable the iHost status
  LED.
- **ga-bootstrap 1.2.8** — released this session (force `protected=false` /
  docker_api self-heal; see ga-bootstrap CHANGELOG).

### Fixed — telegraf pinned back to 1.38.0 (Go toolchain gap) (#109)

The 1.38→1.39 bump (#101) does not build: telegraf 1.38.4 / 1.39.x set
`go 1.26.0` in `go.mod`, but the buildroot host Go is 1.25.7 with
`GOTOOLCHAIN=local`, so the go-mod vendor stage fails at `.stamp_downloaded`
(`requires go >= 1.26.0`). 1.38.0 keeps `go 1.25.7`, builds, and still has the
`disk_write_through` buffer (since 1.35) — the revert loses nothing. Added a
`telegraf.mk` guard note: **do not bump to ≥ 1.38.4 until buildroot Go ≥ 1.26.0**.

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-28 ninth update

### Changed — ga-ha-init sheds watchdog + weather (ownership moved/dropped)

Pairs with ga_manager 0.23.0 (converge now owns the on-device provisioning
steps). `ga-ha-init` now owns only DNS-off + timezone + auto_update.

- **Watchdog loop removed** — it always no-op'd: `ga-ha-init` runs at
  boot+~85s, *before* ga_manager's converge installs the addons, so there was
  nothing to set the flag on (the long-standing HA-INIT-D-09 skip). Watchdog
  is now enforced by ga_manager converge step 8 (after the addons exist) and
  verified by the `addon.options_drift` healthcheck.
- **Weather/location block removed (dropped, not migrated)** — the
  `ha core options '{"location":…}'` call always failed here (needs the HA
  owner account, created later by converge), a guaranteed WARN no-op. The
  customer sets their real location in the onboarding wizard, so a generic
  Berlin fleet-default is low-value and not worth a fragile Core write.
- Build test HA-INIT-02 needles trimmed to what ga-ha-init still owns
  (`ha dns options`, `fallback=false`, `Europe/Berlin`, `auto_update`);
  device HA-INIT-D-09 reframed as an END-state check (ga_manager fills it in).
  Verified live KIB-SON-31: ha_init 10/0/1, emmc_erase 7/0/0.

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-28 eighth update

Provisioning-gap cleanup, following a full survey of ga-flasher-py stages
vs. what the V1.2-clean OS + ga_manager actually do
(`ga-ihost-docs/PROVISIONING-SELF-MIGRATION.md`).

### Removed — redundant `ga-emmc-erase` (single-source-of-truth)

`ga-emmc-erase{,.service}` + its `multi-user.target.wants` symlink deleted.
It duplicated `ga-bootstrap-disk`, which already does the eMMC wipe ~1s
earlier (sysinit, pre-Supervisor) with **3 guards** (iHost device-tree +
`mmcblk0boot0` present + root-on-`mmcblk2`) vs the duplicate's 1, and writes
the same `/mnt/data/.ga_emmc_erased` marker. Live evidence (KIB-SON-31,
2026-05-27): ga-bootstrap-disk won the marker every boot; ga-emmc-erase
detected it and idempotent-exited — harmless but pure redundancy.

### Changed — eMMC tests now cover ga-bootstrap-disk's erase LOGIC (closes a gap)

- Build EMMC-ERASE-01..05 repointed at `ga-bootstrap-disk`: script present,
  **all 3 erase guards**, marker, **blkdiscard + dd zero-fill fallback**,
  sysinit enablement. Previously only GAOS-05/06 (unit exists/enabled) —
  the erase *logic* (guards/wipe method) had no build test at all.
- Device `emmc_erase/` D-01..03 repointed at ga-bootstrap-disk; the wipe-truth
  tests (marker + 64 KiB-zeros md5) unchanged. Verified live KIB-SON-31: 7/7.

Build #8 reflash: the timer-based fix WORKS — host tz auto-corrected to
`Europe/Berlin (CEST)` unattended at boot+240s, no manual intervention.
But the `ga-ha-init-tz-reapply.service` reported `failed` because its
own self-confirmation mis-read the tz. Functional success, cosmetic
failure-state. Fixed.

### Fixed — tz self-check readlink resolution (2-hop symlink + posix subdir)

`/etc/localtime` is a 2-hop symlink on this image:
`/etc/localtime → /mnt/overlay/etc/localtime → /usr/share/zoneinfo/posix/<TZ>`.
The scripts used `readlink /etc/localtime | sed 's|.*/zoneinfo/||'` which:
1. stopped at the intermediate `/mnt/overlay/etc/localtime` (no
   "zoneinfo" substring) — so the value never matched, and
2. even with `readlink -f`, the canonical path goes through a `posix/`
   subdir (`…/zoneinfo/posix/Europe/Berlin`), so a plain zoneinfo-strip
   yields `posix/Europe/Berlin` ≠ `Europe/Berlin`.

Result: ga-ha-init-tz-reapply applied the tz correctly (`timedatectl`
confirmed CEST) but its confirmation step read `/mnt/overlay/etc/
localtime`, logged a WARNING and `exit 1` → systemd marked the unit
`failed`.

Fix: both ga-ha-init and ga-ha-init-tz-reapply now resolve with
`readlink -f … | sed -E 's#.*/zoneinfo/(posix/|right/)?##'`, handling
the 2-hop chain AND the optional `posix/`/`right/` zoneinfo subdir.
Verified live: all three path forms (`posix/Europe/Berlin`,
`Europe/Berlin`, `UTC`) extract correctly.

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-28 sixth update

Build #7 reflash KIB-SON-31 (checked next morning, device up overnight)
still showed `Time zone: UTC` — and `journalctl -t ga-ha-init-late` had
NO entries. The update-5 forked-child workaround never ran.

### Fixed — late tz re-apply via dedicated timer (real fix, take 3)

Root cause of the update-5 failure: `ga-ha-init.service` is
`Type=oneshot` with the default `KillMode=control-group`. When the main
script exits, systemd tears down the unit's entire cgroup — killing the
backgrounded `sleep 180` child before it could re-apply. The parent
logged "forked late-tz-reapply…" at boot but the child was reaped
immediately. A forked sleeper can NEVER survive a oneshot unit.

**Fix**: move the late re-apply into its OWN unit so it gets its own
cgroup:
- `/usr/libexec/ga-ha-init-tz-reapply` — idempotent script: if host tz
  != Europe/Berlin, run `timedatectl set-timezone Europe/Berlin` and
  confirm. No-op if already correct.
- `ga-ha-init-tz-reapply.service` (Type=oneshot) — runs that script.
- `ga-ha-init-tz-reapply.timer` (`OnBootSec=240s`, `AccuracySec=10s`) —
  fires once per boot, comfortably past Supervisor's host-sync revert
  at ~boot+120s. Enabled via `timers.target.wants` symlink.

ga-ha-init itself keeps its early dual-call (Supervisor API +
timedatectl) for the t~85s baseline; the timer is the safety net that
wins the final write. Verified live KIB-SON-31: tz was stuck UTC
overnight, manual `timedatectl set-timezone Europe/Berlin` set CEST and
held — which is exactly what the timer service runs.

New tests:
- Build: HA-INIT-07 (script present), HA-INIT-08 (timer OnBootSec>=180s),
  HA-INIT-09 (timer enabled + service present).
- Device: HA-INIT-D-08 now skip-aware (SKIP if uptime<270s, since the
  timer fires at 240s), HA-INIT-D-08b (timer loaded/scheduled).

**Long-term fix still tracked** (todo_v12_bake_followups item #7):
pre-seed `/mnt/overlay/etc/localtime → Berlin` so Supervisor's cached
startup snapshot is Berlin and the revert no-ops — would let us drop
the timer entirely.

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-27 fifth update

Build #6 reflash KIB-SON-31 still failed HA-INIT-D-08 despite the dual-call
fix from update 4. Root-caused live: Supervisor itself reverts the host
tz at boot+~120s during its `host.control` startup sync. Even though
config.json already records `Europe/Berlin` (our API call persisted), the
sync apparently uses a cached snapshot taken at Supervisor dbus-init
time (t~80s, BEFORE ga-ha-init runs).

### Fixed — defensive late re-apply against Supervisor host-sync revert

Workaround: ga-ha-init's tz block now forks a child that sleeps 180s
(safely past Supervisor's host-sync at ~120s), then re-runs
`timedatectl set-timezone Europe/Berlin` if the host tz has drifted.
Verified live KIB-SON-31 at boot+8min: re-apply sets CEST, holds (no
further Supervisor sync after the boot one). Idempotent if already Berlin.

The parent process exits normally so systemd doesn't wait. Child logs
via `logger -t ga-ha-init-late` so the re-apply is visible in journalctl.

**Long-term fix (deferred to tomorrow)**: pre-seed
`/mnt/overlay/etc/localtime → /usr/share/zoneinfo/Europe/Berlin` in the
rootfs build (post-build.d hook), so Supervisor's cached startup snapshot
IS Berlin from the start and the revert becomes a no-op. Tracked in
`todo_v12_bake_followups_2026_05_27.md` item #7.

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-27 fourth update

Build #5 flashed + retested KIB-SON-31. New HA-INIT-D-08 result: still
FAIL but with a different root cause than update 3. Investigated live;
the API-only fix is necessary but not sufficient. Final fix below.

### Fixed — ga-ha-init timezone needs DUAL call (real bug, take 2)

Update 3 switched ga-ha-init from `timedatectl set-timezone` →
`ha supervisor options --timezone`. The API call succeeds, Supervisor's
recorded tz becomes `Europe/Berlin`, but on a fresh boot Supervisor
DOES NOT propagate that to systemd-timedated for several minutes —
its info-API fields read `null` during this startup window. Result:
host stays `UTC` even though Supervisor's intent is correct.

Observed Build #5 KIB-SON-31 (FQDN kibu-140-131):
- t=80s: ga-ha-init runs API call → "OK"
- t=5min: `ha supervisor info | jq .timezone` = `Europe/Berlin`,
  `timedatectl status` = `UTC`
- t=20min: same — Supervisor never auto-syncs to host without a kick

**Fix**: call BOTH in order:
1. `ha supervisor options --timezone Europe/Berlin` — sets Supervisor's
   recorded intent (required so Supervisor doesn't revert host later).
2. `timedatectl set-timezone Europe/Berlin` — sets the host immediately
   (required because Supervisor won't sync host for several minutes).

Order matters — API first so Supervisor's intent is `Berlin` BEFORE we
mutate the host; otherwise Supervisor's next sync wins. Verified live
on KIB-SON-31 between Build #5 and Build #6.

HA-INIT-02b restructured to assert BOTH calls are present (single-call
of either form is a regression).

---

## 16.3.1.2 (V1.2-clean) — in flight, 2026-05-27 third update

Post-flash device-test fallout from the second update. Build #3 flashed
KIB-SON-31 cleanly and proved NetBird auto-reg unattended (7s from
`Starting` → `Connected`), but the 37-test device suite turned up one real
bug + four test-calibration issues. Fixed all five; verified on the live
device before rebuild.

### Fixed — ga-ha-init timezone silent no-op (REAL bug)

- `ga-ha-init` was setting tz via `timedatectl set-timezone Europe/Berlin`.
  The call returned 0 and the journal said "Changed time zone to Europe/
  Berlin (CEST)" — but ~90s later Supervisor re-synced the host tz from
  ITS OWN in-memory state and reverted (observed live KIB-SON-31 first
  boot 2026-05-27: 18:28:55 set → 18:30:19 reverted to UTC). End state
  was `Time zone: UTC` despite ga-ha-init "succeeding".
- **Fix**: switch to `ha supervisor options --timezone Europe/Berlin` —
  same pattern as the `auto_update` fix in update 2. Supervisor accepts
  it as authoritative, propagates to the host, and the change sticks.
- Verified live on KIB-SON-31 with the patched script before bake: tz
  state went `Europe/Luxembourg` → `Europe/Berlin` and held.
- New build test **HA-INIT-02b** asserts the script uses the API path
  AND does NOT call `timedatectl set-timezone` (catches regression).

### Fixed — device test calibration (4 tests)

These were test bugs, not bake bugs. Stock V1.2-clean image behaviour was
correct; the tests had wrong expectations.

- **HA-INIT-D-09** (`addon watchdog`): script's watchdog loop runs at
  t~80s, BEFORE ga_manager step 5 installs addons (`version_installed:
  null` for all 4 GA addons during this window). Test now `SKIP`s when 0
  truly-installed addons present; ga_manager step 8 late re-apply owns
  the steady-state assertion. Tracked: `todo_v12_bake_followups_2026_05_27`
  item #1 (DNS/watchdog dedup).
- **HA-INIT-D-10** (`marker short-circuit`): grep pattern `'marker
  present'` didn't match script's actual comment `'Marker short-circuit'`.
  Loosened the regex to match either phrasing.
- **EMMC-ERASE-D-05** (`marker SHAPE`): on stock images,
  `ga-bootstrap-disk.service` writes the marker ~1s before
  `ga-emmc-erase.service` runs (= the redundancy in todo_v12_… item #2);
  our service correctly detects the marker and idempotent-exits, so the
  marker reads `"erased by ga-bootstrap-disk"` not `method=blkdiscard`.
  Test now accepts either format (both producers leave the eMMC zeroed,
  D-06 is the wipe-truth test).
- **EMMC-ERASE-D-06** (`mmcblk0 first 64 KiB md5`): test had three
  hardcoded zero-md5 candidates, none of them the actual md5 of 64 KiB
  of zeros (`fcd6bcb56c1689fcef28b57c22475bad`, verified live on device
  via `head -c 65536 /dev/zero | md5sum`).
- **SSH-D-13** (`port 22222 banner exchange`): used `nc` which BusyBox
  iHost doesn't have (no `bash`-`/dev/tcp` or `ssh-keyscan` either).
  Dropped — the test runner's own SSH connection (used to push and
  invoke this script) is already proof the banner half works
  end-to-end. D-09 + D-11 + D-12 cover service state.

### Test verification

Re-ran the full 4-suite device test on the live KIB-SON-31 (with
the patched test files + the live-applied tz fix) before rebuild:

```
Suite               Pass  Fail  Skip
netbird_reg            7     0     0
ha_init                9     0     1   (D-09 skipped — addons not installed)
emmc_erase             7     0     0
ssh_access            12     0     0
TOTAL                 35     0     1   (ALL PASS, 36 tests)
```

Build #4 will re-prove the tz fix from a cold-boot perspective.

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
