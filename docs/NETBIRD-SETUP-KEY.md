# NetBird setup key on the boot partition

How a freshly flashed device gets the NetBird setup key it joins the mesh with
(Odoo #1280). This page is the contract between the flasher (producer) and the
OS (consumer, `/usr/libexec/ga-netbird-register`).

## The file

| | |
|---|---|
| Partition | the boot partition (`hassos-boot`, FAT, mounted at `/mnt/boot`), both boards (iHost, DSGW-210) |
| Path on the partition | `/ga-netbird-setup-key` (root of the partition) — on the device `/mnt/boot/ga-netbird-setup-key` |
| Format | text; the first line that is neither blank nor a comment (`#`) is the key, surrounding whitespace ignored — the same rule as the build input `secrets/netbird-setup-key.txt` |
| Written by | the flasher, after writing the image to the card or eMMC |
| Deleted by | `ga-netbird-register`, after a **confirmed** join, never before |

The name follows the other boot-partition switches (`ga-ethernet-force`,
`ga-firewall-off`, `ga-bluetooth`). It has no `.txt` suffix on purpose: the
RAUC `install_boot` hook keeps only `*.txt` and `grubenv` across an OTA, so an
update never carries the file forward.

## Device behaviour (`ga-netbird-register.service`)

1. `netbird status` shows a confirmed join (Management connected and a NetBird
   IP): nothing to register; a leftover key file is deleted. Exit 0.
2. Daemon in `NeedsLogin`: use the boot-partition key; without a usable one,
   the key baked into the image at `/usr/share/ga-netbird/setup-key` (kept as a
   fallback until the image stops baking it, a later step).
3. `netbird up --setup-key …`, then poll `netbird status` for up to 120 s. Only
   a confirmed join deletes the key file; the exit code of `up` alone never
   does. A failed or unconfirmed join keeps the file and exits 1; the unit
   retries every 60 s.
4. No usable key anywhere: two `err`-priority journal lines naming both paths,
   exit 78. `RestartPreventExitStatus=78` leaves the unit failed
   (`systemctl --failed`) instead of restarting it every minute.

Neither the script nor its tests ever print the key; logs show its length and
which file it came from.

## Landing order (owner decision 2026-10-26)

1. OS consumer reads the boot partition, deletes after a confirmed join, keeps
   the baked fallback — **this step**.
2. Flasher writes the file (producer) + seam test.
3. The image stops baking the key; the build gate flips to "the rootfs carries
   no setup key"; NB-REG-05 flips.
4. The station verify asserts that no key file is left on the device.

## Tests

- Host: `tests/ga_tests/netbird_reg/selftest.sh` drives the live script with a
  stub `netbird` (CI `lint.yml` host-suites).
- Build: NB-REG-01..05 in `tests/ga_tests/run_build_tests.sh`.
- Device: `tests/ga_tests/netbird_reg/test.sh`, NB-REG-D-08 asserts no key file
  is left on the boot partition of a joined device.
