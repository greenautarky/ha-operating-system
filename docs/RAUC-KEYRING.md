# RAUC keyring — what a device trusts, and how to change it

`/etc/rauc/keyring.pem` is the complete list of certificates a device will
accept an OS update from. It is the only thing between a device and an
attacker-signed OTA. This document describes how it is assembled, why it cannot
be repaired in the field, and the one ordering that makes a key rotation
survivable.

Guarded by `scripts/verify-rauc-keyring.sh` (`KEYRING-01..05`), which runs
fail-closed on every prod build, plus `SRC-17a..d` and `RAUC-KEYRING-01` in
`tests/ga_tests/run_build_tests.sh`.

## How the keyring is assembled

`install_rauc_certs()` in `buildroot-external/scripts/rauc.sh` writes it from
three independent sources:

| # | Source | Condition |
|---|--------|-----------|
| 1 | `buildroot-external/ota/rel-ca.pem` (or `dev-ca.pem`) | always; `DEPLOYMENT` in `buildroot-external/meta` selects which |
| 2 | the local signing cert `/build/cert.pem` | **appended silently** whenever it does not verify against `dev-ca.pem` |
| 3 | `buildroot-external/ota/legacy-signing-cert.pem` | when `GA_LEGACY_CA_BRIDGE="true"` |

Source 2 is the one to watch. On any machine that lacks the real signing key,
`prepare_rauc_signing()` generates a throwaway self-signed certificate and
source 2 promotes it to a fleet trust anchor — with no warning in the build log
beyond one line. `rel-ca.pem` is gitignored and lives only on the build server,
so "did the real key get used" is not answerable from the repository.

`rel-ca.pem` / `dev-ca.pem` are not in git (`.gitignore`: `*.pem`, with an
explicit exception for `legacy-signing-cert.pem`). They are staged on
ga-builder; `docs/REPRODUCIBILITY.md` documents the copy step.

## The keyring cannot be fixed over SSH

The running rootfs is a **read-only squashfs/erofs**, one half of the A/B pair
(`hassos-system0` / `hassos-system1`). Writable paths come from an explicit
*allowlist* of bind mounts seeded by `usr/libexec/hassos-overlay` — `/etc/hostname`,
`/etc/hosts`, `/etc/dropbear`, `/etc/modprobe.d`, `/etc/NetworkManager/system-connections`,
`/root/.ssh` and a handful more. **`/etc/rauc` is not one of them.**

Consequences:

- `echo … > /etc/rauc/keyring.pem` over SSH fails; the filesystem is read-only,
  and remounting rw is not possible on squashfs/erofs.
- A runtime `mount --bind` over the file works until reboot, but the unit that
  would re-establish it would itself have to live on the read-only rootfs.
- The trust set therefore changes only by installing a **new rootfs**.

### …but "new rootfs" does not have to mean OTA or physical reflash

`rauc install` verifies the bundle signature against the running slot's keyring
and cannot be told to skip it — so the *supported* update path (including
`usr/sbin/ga-rauc-install`) is blocked by a keyring the device does not trust.
Writing the inactive slot directly is not:

```bash
# on the laptop: unpack the bundle (verity format = squashfs at offset 0,
# the signature only covers the verity root hash, so unpacking needs no trust)
unsquashfs -d bundle/ gaos.raucb          # -> rootfs.img, kernel.img, boot.vfat, hook

# stream onto the INACTIVE slot (/tmp is a 15 MB zram disk — never stage there)
ssh <device> 'dd of=/dev/disk/by-partlabel/hassos-system1 bs=4M conv=fsync' < bundle/rootfs.img
ssh <device> 'dd of=/dev/disk/by-partlabel/hassos-kernel1 bs=4M conv=fsync' < bundle/kernel.img
ssh <device> 'rauc status mark-active other && reboot'
```

This bypasses signature verification entirely, because RAUC is never asked to
verify anything. It is the fallback that keeps a botched key rotation from
being a fleet-wide truck roll.

What it costs, and what it does not cover:

- **The running slot is untouched**, so a bad write falls back on the next boot.
  That bound matters more since `CONFIG_BOOTDELAY=-2` (rc38) removed the U-Boot
  escape hatch: RAUC rollback and reflash are the only recoveries left.
- **`/mnt/boot` is shared, not A/B.** `boot.vfat` is installed by the
  `install_boot` hook in `buildroot-external/ota/rauc-hook`, which preserves
  `*.txt` and `grubenv`. Replicating it by hand touches state both slots boot
  from. For a keyring-only change the kernel and bootloader are unchanged, so
  skip that step — write rootfs (and kernel) only.
- **It needs the device to be reachable.** A keyring mistake is a *soft*
  failure — devices keep running and stay on the mesh, they just refuse
  updates — so in that scenario reachability holds. It does not hold for the 56
  devices that are live but not in the fleet-manager (Odoo #534).
- **It is manual, per device, and moves a full rootfs over each uplink.**
  Bounded-cost recovery, not a rollout mechanism.

Security consequence, stated plainly: **root SSH on a device can install an
unsigned OS image.** The RAUC signature protects the OTA *channel*; it is not a
boundary against whoever holds root on the box. With a fleet-shared root SSH
key that is a fleet-wide arbitrary-image path, and it belongs in the threat
model alongside the rc38 U-Boot lockdown.

## Rotating the signing key

The trap: a device verifies a bundle against the keyring **in the slot it is
running now**, not the one inside the bundle. So the new keyring has to arrive
*inside* an update the old keyring already accepts.

Correct order:

1. **Bridge release.** Build an image whose keyring contains **old CA + new CA**.
   Sign the bundle with the **old** key. Every device in the field accepts it,
   and afterwards trusts both.
2. **Prove adoption.** Confirm *every* device is running the bridge image —
   by enumerating devices, not by sampling. Until then, step 3 is unsafe.
3. **Cut over.** Start signing with the new key. Devices accept it because of
   step 1. Build an image whose keyring contains the **new CA only**, ship it,
   and delete the old CA from the tree.

Skipping step 1 — signing with a new key the field does not trust yet — leaves
every existing device unable to verify any future bundle. Recovery is then the
manual raw-slot write above, once per device, for every device still in the
field: laborious and reachability-dependent, but not a truck roll. This has
already happened once here; the `GA_LEGACY_CA_BRIDGE` flag is the patch for it,
and it re-trusts a retired CA fleet-wide as the price.

Devices that will be **physically swapped out** do not need step 1 — but they
do need to be *identified* first, and any device that stays in the field does
need it. "Swap the old ones" is a plan only once the inventory can name them.

## Inspecting a keyring

A build output, or a keyring pulled off a device:

```bash
./scripts/verify-rauc-keyring.sh ga_output          # audit a build
./scripts/verify-rauc-keyring.sh --print /path/to/keyring.pem
scp <device>:/etc/rauc/keyring.pem /tmp/dev.pem && \
  ./scripts/verify-rauc-keyring.sh --print /tmp/dev.pem
```

`--print` lists every certificate with its SHA-256 fingerprint, subject and
expiry. Compare fingerprints, never subjects: the retired CA and a freshly
generated development key share the subject
`O=HassOS, CN=HassOS Self-signed Development Certificate`, because both come
out of `scripts/generate-signing-key.sh`.

Do not use `openssl x509 -in keyring.pem`: the bundle is written with
`openssl x509 -text`, so readable blocks sit between the PEM armour and that
command reads only the **first** certificate — and reports success. That is how
an extra anchor stays invisible.

## Current state (2026-07-29)

- `GA_LEGACY_CA_BRIDGE="true"` in `buildroot-external/meta` — every production
  image still trusts the retired pre-2026-03-27 CA, fingerprint
  `01:E7:CE:81:…:BC:F7`, valid until 2035-09-18, `CA:TRUE`, no `check-crl` in
  `system.conf` and therefore **no revocation path**.
- Flipping it to `"false"` requires proving no pre-rotation device remains in
  the field. That is blocked on the fleet inventory gap (Odoo #534): 65 live
  devices, 9 in the fleet-manager. An audit cannot clear devices it cannot
  enumerate.
- The audit script accepts the current state (the bridge is declared, so it is
  expected) and accepts the post-migration state (`false`, legacy absent). It
  fails on the divergence between them — which is the case nothing covered
  before.
