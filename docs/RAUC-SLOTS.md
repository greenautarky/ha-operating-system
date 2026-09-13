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
   over the partitions (2 x 24M + 2 x 300M, idle IO class, nice 19, bounded).
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

## Where it is proven

* `IMG-01` (build suite, `scripts/check-slot-pairs.sh`): the produced `.img.xz`
  has identical, non-blank slot pairs. Red on a pre-#349 bake, green after;
  self-tested on every PR by `tests/gates/slot_pairs/selftest.sh`.
* `SRC-23` (build suite): the layouts declare an image for both pairs.
* `PROV-11` (provisioning suite, device): the inactive kernel slot is not blank.
* `tests/ga_tests/rauc_slots/test.sh`: SLOT-25..28 keep proving an empty slot is
  refused; SLOT-70..82 prove the mirror evidence red and green on fixtures;
  SLOT-46 (device) asserts the live rollback target is bootable; SLOT-61/62
  prove the suite wrote no device record.
