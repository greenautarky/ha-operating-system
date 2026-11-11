# RAUC slots — what a fresh image puts in them, and how a rollback target is proven

Scope: the Sonoff iHost image (`buildroot-ihost`), RAUC 1.13 as pinned by
buildroot, U-Boot bootloader backend. Facts below are read from the build
sources and the pinned RAUC source, not recalled; each section names its file.

## Layout

GPT, 1 MiB aligned (`buildroot-external/genimage/partitions-os-gpt.cfg`,
`hdimage-gpt.cfg`; the `hybrid` layout is a symlink to the gpt one):

| partition          | size  | RAUC slot        | bootname | content in a fresh image      |
|--------------------|-------|------------------|----------|-------------------------------|
| (spl, no entry)    | 16M   | `spl.0`          |          | `u-boot-rockchip.bin`         |
| `hassos-boot`      | 16M   | `boot.0`         |          | `boot.vfat` (boot.scr, dtbs)  |
| `hassos-kernel0`   | 24M   | `kernel.0`       | A        | `kernel.img`                  |
| `hassos-system0`   | 300M  | `rootfs.0`       | (A)      | rootfs image (erofs)          |
| `hassos-kernel1`   | 24M   | `kernel.1`       | B        | `kernel.img` — **same bytes** |
| `hassos-system1`   | 300M  | `rootfs.1`       | (B)      | rootfs image — **same bytes** |
| `hassos-bootstate` | 8M    |                  |          | U-Boot env (empty at flash)   |
| `hassos-overlay`   | 96M   |                  |          | `overlay.ext4`                |
| `hassos-data`      | rest  |                  |          | data image                    |

Slot pairs: `rootfs.N` has `parent=kernel.N`, and the bootname lives on the
kernel slot (`buildroot-external/ota/system.conf.gtpl`).

**Both slot pairs are populated since 2026-08-19 (#349).** The partitions were
always allocated; before that only slot 0 had an `image =`, so a fresh SD flash
left `hassos-kernel1`/`hassos-system1` as zeros. A flashed device now boots slot
A and carries a byte-identical copy of the same OS in slot B. The `.img` and the
flash time are unchanged (the partitions were already sized); only the `.img.xz`
grew, by roughly the compressed size of kernel + rootfs.

**The first OTA overwrites slot B**, exactly as before: RAUC installs into the
inactive slot, marks it active in U-Boot (`BOOT_ORDER`, `BOOT_B_LEFT`) and the
device boots B; the next OTA goes into A.

## What `rauc status` says about a fresh device, and why

`statusfile=/mnt/boot/rauc.db` — one central GKeyFile on the boot partition
(`system.conf.gtpl`). RAUC only writes it on `rauc install` (`status=pending`
before the slot is written, `failed` or `ok` after, plus `installed.timestamp`
and `bundle.version`). A flash writes no `rauc.db` at all; on first boot
`raucdb-update` seeds `bundle.version` from `/etc/os-release` for `boot.0` and
the **booted** slot only, without a timestamp.

So on a fresh device `rauc status --detailed` reports the inactive slot with no
bundle version and no install record even though the bytes are there. That is
RAUC's install ledger being accurate: nothing was installed. It is **not**
pre-populated by the image, deliberately:

* `rauc.db` lives in the boot partition, and the OTA hook (`ota/rauc-hook`,
  `install_boot`) copies the bundle's `boot.vfat` over `/mnt/boot` wholesale.
  Image and bundle share one `boot.vfat`, so a baked-in `rauc.db` would
  overwrite the device's real install history on every OTA.
* `installed.timestamp` means "RAUC wrote and verified this slot on this
  device". The rollback gate below rests on that meaning.
* A record baked at build time attests the image, not the card. A flash that
  stopped half-way through slot B would still carry it.

`boot_status` for slot B is `good` on a fresh device: U-Boot defaults
`BOOT_B_LEFT=3` when the bootstate partition is empty
(`buildroot-ihost/board/sonoff/ihost/uboot-boot.ush`). It is the bootloader's
try counter and says nothing about content — which is why it is not the gate.

`--output-format=json` is not available: `BR2_PACKAGE_RAUC_JSON` is unset in
the iHost defconfigs and RAUC aborts on the option. The shell formatter
(`KEY='value'`) is the machine-readable interface; it is parsed, never
`eval`'d.

## How "is there something to roll back to" is answered

`/usr/libexec/ga-rauc-slots` (timer: 90 s after boot, then every 10 min)
publishes the slot picture to the ga_manager add-on's private data dir. Its
`rollback.possible` is true only when the inactive slot has `boot_status=good`
**and** at least one observed evidence holds:

1. **`ever_installed`** — `installed.timestamp` in the slot group (RAUC wrote
   and verified it on this device).
2. **`booted_ok`** — this slot booted this device and stayed up past 600 s
   (`/mnt/data/ga-slot-boots.json`, written by the collector itself).
3. **`mirror_of_booted`** (since 2026-09-13) — the inactive slot group is
   **byte-identical to the booted one**, measured on the device with `cmp`
   over the partitions (2 x 24M + 2 x 300M, nice 19, idle IO class where the
   scheduler honours it, bounded, and not before 600 s of uptime so the first
   tick after boot stays cheap).
   Cached in `/mnt/data/ga-slot-mirror.json` keyed on the target and the slot
   it was compared with, so the read happens once per device lifetime; a
   reflash wipes `/mnt/data` and the record with it. Consulted only while RAUC
   has never touched the target (no `status`, no timestamp): the moment an
   install starts, finished or not, the identity evidence is discarded. A
   comparison that does not finish leaves **no** verdict (retried next tick).

A fresh flash therefore reports `rollback.possible=true` for slot B with
`installed_version=null`, `ever_installed=false`, `mirror_of_booted=true` — no
version is compared and none is invented. An older image whose slot B is zeros
reports `false` with a reason that says the content differs. The booted slot is
always bootable by demonstration.

## The release floor: which bundles a device will install

Every install goes through the RAUC system `pre-install` handler
`/usr/lib/rauc/ga-release-floor`, declared in `/etc/rauc/system.conf` and so
taken from the **running** rootfs, never from the bundle. It compares the
bundle's `[meta.ga] release=` with `/etc/ga-release`:

| bundle | verdict |
|---|---|
| same release (reinstall) or newer | installed |
| older release | refused, nothing written, no reboot |
| no `[meta.ga] release=` (built before the floor) | refused |
| malformed release, or the device's own release unreadable | refused |

Order: `BOSvX.Y.Z-devN < BOSvX.Y.Z-rcN < BOSvX.Y.Z`, numeric per field, so
`BOSv1.3.0-rc56 < BOSv1.4.0-rc1 < BOSv1.4.0-rc2 < BOSv1.4.0 < BOSv1.4.1-rc1`.
A refusal shows up as `Pre-install handler error` from `rauc install`, as exit
5 from `ga-rauc-install`, and in the journal as `[ga-release-floor] REFUSED: …`.

### Going back to an older release

The fleet path (fleet-manager → ga_manager → `ga-rauc-install`) cannot install
an older bundle on a device that runs the floor, by design. What still works:

1. **Roll forward.** Rebuild the known-good source under a new, higher release
   label and dispatch that. This is the only fleet-scale way back.
2. **Switch slots** when the other slot still holds the previous release (see
   `rollback.possible` above): `rauc status mark-active other && reboot`. No
   bundle is installed, so the floor is not involved.
3. **Per device, by an operator**, as root at a terminal:

   ```sh
   ssh -t root@<device> ga-rauc-install-older /mnt/data/tmp/<bundle>.raucb
   ```

   It shows the running and the bundle release, asks for the bundle release
   (or `none`) to be typed back, writes a one-shot token to
   `/run/ga-rauc-floor/allow-older` (root, 0700) and runs `rauc install`. The
   handler accepts the token for that release only, for 15 minutes, and
   deletes it. It does not reboot. Without a terminal it refuses — it is not a
   path for automation. An environment variable on `rauc install` cannot act
   as an override: the handler runs in the rauc service's environment.

Consequence for release labels: they must only grow. A bake that reuses an
older label produces a bundle that every device above that label refuses.

## The second-slot mirror: no fallback into a 1.5 slot after the 1.6 migration (Odoo #1750)

BOSv1.6 migrates persistent state one way (Supervisor `apps/` data root, `app_`
container names, Core 2026.10). After the 1.5 -> 1.6 OTA the other slot still
holds 1.5, so a bootloader fallback (3 failed boots) or an operator rollback
lands on an OS that cannot read the migrated state: a broken system, not a
rescue. After a soak the OTHER slot is given the release that runs.

**Scope (decision 2026-11-11).** Only when the other slot's `/etc/ga-release`
is on a LOWER major.minor than the booted one (1.5 beside 1.6). A 1.6.x slot is
never overwritten by another 1.6.y: a healthy fallback stays. An unreadable
other slot is skipped, not overwritten.

**Decision: `rauc install` is NOT used.** Measured on a real bundle
(`rauc info` of `bos_ihost-16.3.1.9_prod_20260727083535.raucb`; the manifest
template `manifest.raucm.gtpl` (`buildroot-external/ota/` on the 1.5 line, `haos/buildroot-external/ota/` in the HAOS submodule on the 1.6 line) adds `[image.spl]` and
`[image.boot]` whenever `BOOT_SPL=true`, which the iHost `meta` sets): the
bundle has four images, `boot` (boot.vfat) and `spl` (spl.img) both with an
`install` hook. `rauc install` would therefore rewrite the SPL region of the
boot disk (raw `dd`) and `cp -rf` over the SHARED boot partition
(`rauc-hook install_boot`). On a healthy device a power loss there can brick
BOTH slots. (Checked against the July bundle and the template; the rc12/rc13
bundles on the builder were not unpacked.)

The helper `/usr/sbin/ga-rauc-mirror-slot` (`ga-rauc-mirror-slot.path` ->
`.service`, request file in ga_manager's private data dir, ADR-0041) instead:

1. `rauc extract` the bundle (RAUC verifies signature and verity), then sha256
   of `kernel.img` and `rootfs.img` against the manifest digests;
2. `rauc status mark-bad <other>`: the slot leaves `BOOT_ORDER`, a half-written
   slot can never be booted;
3. `rauc write-slot` for the other kernel slot and the other rootfs slot only
   (raw write, no hooks, no bootloader change, no status update);
4. read the written bytes back, compare with the manifest digests;
5. `mark-good <other>`, `mark-active <other>`, then `mark-active booted`, retried
   with a read-back of `RAUC_BOOT_PRIMARY`; exit 6 only if it still is not the
   booted slot. (`mark-bad` removes a slot from `BOOT_ORDER` and `mark-good` does
   not re-add it, `bootchooser.c`, hence the pair; between the two the other slot
   already holds the same release.)

It never reboots. `rauc.db` is not updated by `write-slot`; the other slot's
release is read from its own `/etc/ga-release` (mounted read-only; a rootfs that
does not mount, or has no usable release, is its own verdict `skipped: other slot
unreadable: ...` with an err-priority log line, never a quiet skip).

**Re-check after the download, and the residual window.** The download can take
up to 15 minutes and `rauc write-slot` does not set RAUC's busy flag. An OTA that
finished meanwhile leaves `BOOT_ORDER` "other booted" with the NEW release in the
other slot; writing then would overwrite it and silently undo that OTA. So the
live gate runs again before `mark-bad`: the slow parts first (journal dump, mount
and read of the other slot), then the decisive ones (`rauc status`: booted slot
unchanged and good, primary still the booted slot; `ga-rauc-install` not
activating; RAUC `Operation` idle), so that only `mark-bad` follows directly after
them.

What this does NOT exclude: an OS install (`ga-rauc-install` OR Supervisor's
InstallBundle) that starts during the 1 to 3 minutes of the `write-slot` window
itself. `ga-rauc-install` is deliberately untouched (no lock: a wait there could
outlast its unit timeout and kill an OTA after the download, and it would not
cover InstallBundle anyway), so the normal OTA path of every device is
byte-identical to the 1.6 branch. Consequence of a collision: two writers on the
other slot's partitions; the read-back fails or the slot is left marked bad by
our `mark-bad`/RAUC's own, and the installing OTA may fail or leave that slot
unusable until the next install. Why it is acceptable: the mirror runs once per
device after the 1.5 to 1.6 OTA, on request after a 24 h soak, so the window is
rare; the bootloader falls back to the booted slot after `BOOT_x_LEFT` reaches 0;
a failed read-back leaves the slot bad and out of `BOOT_ORDER` and is reported
(`failed`, exit 5); and the booted slot is never touched.

One more consequence of that collision: if the OTHER writer is `rauc install`, its
own `mark-active` puts the freshly installed slot into `BOOT_ORDER` as primary
after our read-back failed, so a slot that our write corrupted could be booted.
Nothing in this feature protects against that; only the bootloader's 3-attempt
fallback (`BOOT_x_LEFT` reaches 0, then the other slot) does.

**What ga-rauc-slots reports for a mirrored slot.** rauc.db keeps the older
bundle for it. The helper records the verified write (release, bundle version,
digests, time) in `/mnt/data/ga-slot-written.json`; `ga-rauc-slots` overlays it
as `installed_release` / `installed_version` / `written_verified` and counts it
as a bootable ground, but only while RAUC has not installed into that slot since
(`installed.timestamp` not newer than the record). ga_manager passes
`installed_release` and `written_verified` through to `/info`.

**Preconditions (host, from RAUC's own status; the request cannot lift one).**
Release >= BOSv1.6 (1.5 is never touched); booted slot good; boot primary is
the booted slot; other slot readable and on a lower line; RAUC `Operation` idle
(covers Supervisor's InstallBundle; unreadable = failure, busy = skipped) and no
`ga-rauc-install` activating and no second mirror run (flock); booted slot
activated >= 24 h ago and uptime >= 1 h; free space. The bundle must be signed,
carry the running `[meta.ga] release`, and its manifest hash must equal the
booted rootfs's recorded bundle hash where rauc.db has one. Download: same
pinned endpoint and URL shape as `ga-rauc-install`, with connect/max-time and
speed limits so one download cannot eat the unit's budget; SIGTERM/INT cleans up
and restores the primary if we had touched it. The result file is written via a
root-only work dir and `rename`, so a symlink planted by the add-on is replaced,
never followed. A failed precondition is `skipped` (exit 0); later errors are
`failed` (exit 3..7, error level). Exit 6 reaches the fleet through the
fluent-bit tier-0 and tier-1 filters for the unit (gate fixtures S9/S10).

**Alternatives.**

| alternative | verdict |
|---|---|
| `rauc install` + `mark-active booted` (first version of this change) | rejected after review: rewrites SPL and the shared boot partition; power loss there can brick both slots. |
| `activate-installed=false` in `system.conf` | rejected: global; every normal OTA would stop switching slots (test MIR-53). |
| `dd` of the booted slot pair | rejected: no signature check; copies whatever the running media holds. |
| `rauc extract` + `write-slot` (chosen) | signature checked by RAUC, only the other slot's two partitions are written, bootloader state changes are explicit and read back. Cost: no rauc.db record for the write. |
| fm-only job | rejected as the sole mechanism: soak start and boot order are not visible in the add-on. The fm role is "when", not "whether". |
| autonomous timer | not shipped: it would write a slot with nobody asking. |
| reuse of the OTA bundle (LTE) | not done; the helper downloads again (follow-up). |

**Not done:** the fleet-manager trigger after the soak window; a device proof.

**Needs a device proof on K31 (staging):** (1) OTA 1.5 -> 1.6, wait the soak (or
run the helper by hand with `GA_MIRROR_SOAK_S=60 GA_MIRROR_MIN_UPTIME_S=60`, an
operator-only override a request cannot set); `rauc write-slot` on a real
partition, `rauc status mark-bad/good/active` and `BOOT_ORDER` as the stub
assumes (the stub encodes the source reading, not the device); (2) the other
slot then reads 1.6 and `mark-active other && reboot` boots it; (3) power loss
during the write: the booted slot boots again and the half-written slot is not
selected; (4) a second request is `skipped: same line`; (5) rootfs mount of the
other slot for the release read works on the iHost (erofs, read-only).

## Where it is proven

* `IMG-01` (build suite, `scripts/check-slot-pairs.sh`): the produced `.img.xz`
  has identical, non-blank slot pairs. Red on a pre-#349 bake, green after;
  self-tested on every PR by `tests/gates/slot_pairs/selftest.sh`.
* `SRC-23` (build suite): the layouts declare an image for both pairs.
* `PROV-11` (provisioning suite, device): the inactive kernel slot is not blank.
* `tests/gates/rauc_release_floor/selftest.sh` and `rauc_e2e.sh` (CI): the
  release floor both ways — handler verdicts, the override, build gate
  RFLOOR-01/02, and the handler behind a real `rauc service`.
* `tests/ga_tests/rauc_slots/test.sh`: SLOT-25..28 keep proving an empty slot is
  refused; SLOT-70..83 prove the mirror evidence red and green on fixtures;
  SLOT-46 (device) asserts the live rollback target is bootable; SLOT-61/62
  prove the suite wrote no device record.
* `tests/ga_tests/rauc_mirror_slot/test.sh` (CI): the second-slot mirror: must-skip,
  must-run, must-fail with the exit codes, no `rauc install`, and mutants of the
  LIVE helper that each turn their named guard test red. `tier0_ota_journal`
  carries the unit's log lines (S9/S10) and a no-mirror mutant.
