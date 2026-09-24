# RAUC keyring — what a device trusts, and how to change it

`/etc/rauc/keyring.pem` is the complete list of certificates a device will
accept an OS update from. It is the only thing between a device and an
attacker-signed OTA. This document describes how it is assembled, why it cannot
be repaired in the field, and the one ordering that makes a key rotation
survivable.

Guarded by `scripts/verify-rauc-keyring.sh` (`KEYRING-02`, `-03`, `-05`, `-06`),
which runs fail-closed on every build, plus `SRC-17a/b`, `SRC-21` and
`RAUC-KEYRING-01` in `tests/ga_tests/run_build_tests.sh`. The audit's verdicts
are proven red and green on every pull request by
`tests/gates/rauc_keyring/selftest.sh`; what a *device* does with a foreign
signature is asked by the `ota_trust` device suite (`KEYRING-NEG-*`).

> **Updated 2026-09-24 — one key, one build mode (ADR-0027 Amendment 1, D9).**
> There is no dev CA, no dev signing key and no `GA_ENV=dev|prod` build mode any
> more. Every build ships a keyring holding exactly one certificate — the OTA
> root, whose SHA-256 fingerprint is pinned as a constant in the audit — and
> signs with the one signing certificate issued under it. See
> [One key, one build mode](#one-key-one-build-mode-adr-0027-d9) below.

> **Updated 2026-07-30 — the retired-CA bridge is GONE, not switched off.**
> `GA_LEGACY_CA_BRIDGE`, `ota/legacy-signing-cert.pem` and
> `add_legacy_ca_if_enabled()` were all deleted (OS#309). `KEYRING-01`,
> `KEYRING-04` and `SRC-17c` went with them — they existed only to audit the
> bridge. `KEYRING-06` and `SRC-21` replace them and assert the bridge's
> **absence**, which is a stronger property than "the flag says false".
> Passages below that describe the bridge as live are historical; they are kept
> because the reasoning that led to the cut is worth reading, and marked where
> they are no longer current.

## How the keyring is assembled

`install_rauc_certs()` in `buildroot-external/scripts/rauc.sh` writes it from
two sources:

| # | Source | Condition |
|---|--------|-----------|
| 1 | `buildroot-external/ota/rel-ca.pem` — the OTA root | always; the only intended anchor |
| 2 | the signing cert `/secrets/cert.pem` | appended only if it does **not** chain to the root — which `KEYRING-02` then fails, because the keyring may hold exactly one certificate |
| ~~3~~ | ~~`buildroot-external/ota/legacy-signing-cert.pem`~~ | **removed 2026-07-30** — source, flag and bake function all deleted |

Signing material (`key.pem`, `cert.pem`) is read from the read-only secrets
mount `/secrets` **only** (`GA_SECRETS_DIR`). The fallback to the source
checkout and the on-the-fly generation of a self-signed key are gone (D9): a
missing mount fails the pre-flight in `ga_build.sh` and `prepare_rauc_signing()`.

`rel-ca.pem` is not in git (`.gitignore`: `*.pem`); it is staged on the build
server, and `docs/REPRODUCIBILITY.md` documents the copy step. Because the
repository cannot hold it, the repository holds its **fingerprint** instead:
`ga_build.sh` refuses to start unless `rel-ca.pem` is that certificate
(`verify-rauc-keyring.sh --check-root`), and the audit refuses to pass a keyring
that holds anything else.

## One key, one build mode (ADR-0027 D9)

Decided 2026-09-14 and implemented 2026-09-24. Measured before the decision:
every v1.3 device trusts exactly the one OTA root; the dev CA was in no device
keyring, and the last dev bake was on 2026-08-31. The dev key protected nothing
in the fleet and needed four guards to keep apart from the real one.

- `ga_build.sh [full|partial|kernel|update]` — no environment argument. A
  leftover `prod` (argument or `GA_ENV=prod`) is accepted and ignored with a
  deprecation banner so in-flight callers keep working; `dev`/`test` are
  refused. Every build requires `ROOT_PW_HASH` and runs SBOM, CVE gate
  (`scan-cves.sh --strict`), keyring audit and build tests.
- The on-device `GA_ENV` in `/etc/ga-env.conf` and `/etc/os-release` is now a
  constant `prod` **runtime label** for telemetry; D10 replaces it with
  `fleet_env`. It selects nothing at build time.
- `verify-rauc-keyring.sh` pins the root fingerprint as a constant
  (`GA_OTA_ROOT_FP`). It no longer reads `rel-ca.pem` to decide what to expect:
  an audit must never derive its expectation from the artefact it audits.
- The checks, each stricter than before D9:

| Check | Asserts | Stricter since D9 |
|---|---|---|
| `KEYRING-02` | nothing but the pinned root; exactly one certificate block; every block parses | no tolerated "locally generated dev cert"; duplicates and unparseable blocks fail |
| `KEYRING-03` | the pinned root is present and is `CA:TRUE` | pinned constant instead of the declared input; CA flag checked |
| `KEYRING-05` | the root is not expired (warn inside 365 days) | an unreadable expiry is a finding, not a silent skip |
| `KEYRING-06` | retired signing paths are absent from the tree | also the dev-key selector, the dev CA and the checkout fallback in `rauc.sh` / `hdd-image.sh` |

`KEYRING-07` (dev vs prod pin) is gone: with one anchor there is no pair to
keep apart; `KEYRING-02`/`-03` cover it. The symlink / byte-identity /
pair-selection guards in `ga_build.sh` went for the same reason.

### Negative test on a device

The KEYRING checks inspect the build. Whether a device actually *refuses* a
foreign signature is a separate question, asked by
`tests/ga_tests/ota_trust/test.sh` (device-only, on demand):

```bash
tests/ga_tests/ota_trust/make-throwaway-bundle.sh /tmp/trust   # host: key is deleted after signing
scp /tmp/trust/throwaway.raucb /tmp/trust/throwaway-cert.pem <device>:/tmp/
# on the device, with the test tree staged by run_device_tests.sh:
THROWAWAY_RAUCB=/tmp/throwaway.raucb THROWAWAY_CERT=/tmp/throwaway-cert.pem \
  sh /tmp/ga_tests/ota_trust/test.sh
```

`KEYRING-NEG-01` proves the bundle is well-formed (it verifies against its own
cert), `-02` that `rauc info` rejects it with a signature error, `-03` that
`rauc install` does, `-04` that the slot status did not move. If the device
accepts the signature at `-02`, the install is never attempted, and the bundle's
only image targets a slot class no GA system defines. Its verdict logic runs in
CI against a stub `rauc` (`ota_trust/selftest.sh`). **Not yet run on hardware.**

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

There are two shapes, and which one you need depends entirely on whether
existing devices are migrated over the air or replaced.

**Clean cut** — chosen 2026-07-29. Existing devices are swapped or reflashed by
hand, so nothing has to be delivered to a device holding the old keyring. The
new anchor and the new signing material land in a single edit; no bundle is
ever signed with the old key. Simplest, and the risk is contained to bench
devices you physically hold: only freshly flashed units carry the new keyring,
so a rejected chain costs a reflash, not a fleet event.

**Bridge-forward** — needed if devices in the field must migrate over the air.
The load-bearing detail there: *the keyring inside a bundle and the signature on
that bundle are independent.* The signature decides who can install it; the
keyring decides what the device trusts afterwards. So you build an image whose
keyring holds the new root CA only, and sign **that bundle with the old key** —
field devices accept it, and afterwards trust exactly one anchor. Every later
bundle is signed with the new cert. A softer variant keeps new CA **+** old cert
in the keyring for one release, which lets one bundle serve a mixed fleet at the
cost of a temporary second anchor.

**Hard precondition for either:** prove on real hardware that RAUC accepts the
new signing chain *before* an image whose keyring drops the old anchor reaches
anything you cannot physically touch. Afterwards such a device trusts only the
new root; if the chain is rejected, nothing you can sign will install and
recovery is the manual raw slot write, once per device.

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
expiry. `--print` marks the pinned OTA root. Compare fingerprints, never subjects: the
retired CA and a freshly generated development key share the subject
`O=HassOS, CN=HassOS Self-signed Development Certificate`, because both come
out of `scripts/generate-signing-key.sh`.

Do not use `openssl x509 -in keyring.pem`: the bundle is written with
`openssl x509 -text`, so readable blocks sit between the PEM armour and that
command reads only the **first** certificate — and reports success. That is how
an extra anchor stays invisible.

## The 2026 CA (generated 2026-07-29) — the OTA root the audit pins

`scripts/ops/gen-ota-ca.sh` mints the replacement hierarchy. Run on ga-builder
as root; it refuses to overwrite existing key material.

```bash
scp scripts/ops/gen-ota-ca.sh ga-builder:/tmp/
ssh ga-builder 'bash /tmp/gen-ota-ca.sh'      # -> /root/ga-ota-ca-<date>/
```

| Artefact | Role | SHA-256 | Valid to |
|---|---|---|---|
| `ga-ota-root-ca.pem` | keyring anchor → `ota/rel-ca.pem` | `C1:B7:57:33:1C:AE:F8:C1:36:40:81:C3:39:CE:34:80:FD:C6:9E:42:D0:ED:73:2F:CA:C0:AA:9F:0F:6A:83:17` | 2041-07-28 |
| `ga-ota-signing.pem` | signs bundles → `cert.pem` | `AF:E9:CE:76:AA:18:C7:6D:21:19:E9:B3:80:52:D9:FA:70:88:F9:8D:30:A2:1E:B7:DC:AB:8A:AC:F8:E9:CD:35` | 2029-07-28 |

Both RSA-4096/SHA-256. The signing cert **chains to the root** — that is the
change that matters, and `install_rauc_certs()` therefore stops appending it to
the keyring. The root key belongs in the password manager, **not** on the
builder; it is only needed to issue the next signing cert.

Why two tiers: until now the trust anchor *was* the signing certificate, so
rotating the signing key meant migrating the fleet's trust anchor — which is
the hole `GA_LEGACY_CA_BRIDGE` exists to patch. With a root CA in the keyring,
a signing-key rotation is a build-server change the fleet never sees.

## Historical state before the clean cut (2026-07-29)

Measured on the last prod build output on ga-builder (2026-07-29 16:20), the
shipped keyring holds **three** anchors — one of them undeclared:

| SHA-256 | Subject | How it got there |
|---|---|---|
| `FE:4E:81:…:92:06` | `CN = iHost RAUC Dev CA` | `ota/rel-ca.pem` — declared. Signs nothing; **inert** |
| `5E:D6:AF:…:FD:00` | `O=HassOS, CN=HassOS Self-signed Development Certificate` | `/build/cert.pem`, appended by source 2. **Undeclared — and it is what actually signs the bundles** |
| `01:E7:CE:…:BC:F7` | `O=HassOS, CN=HassOS Self-signed Development Certificate` | retired F13 CA, declared via the gate |

So the effective trust anchor in production today is a self-signed certificate
straight out of `generate-signing-key.sh`, and the CA that is supposed to be
the anchor validates nothing. `KEYRING-02` reports exactly this against a real
build; it is the reason the 2026 CA above exists.

- ~~`GA_LEGACY_CA_BRIDGE="true"`~~ (**historical** — deleted 2026-07-30) in `buildroot-external/meta` — every production
  image still trusts the retired pre-2026-03-27 CA, fingerprint
  `01:E7:CE:81:…:BC:F7`, valid until 2035-09-18, `CA:TRUE`, no `check-crl` in
  `system.conf` and therefore **no revocation path**.

### The F13 bridge cannot do what it was added to do

Checked on ga-builder 2026-07-29 by comparing public-key hashes of every
`*.pem`/`*.key` under `/home/builder` and `/root` against each certificate.
Positive control: `key.pem` matches `cert.pem`, so the comparison does detect a
match when one exists.

| Certificate | Private key on the builder? |
|---|---|
| `cert.pem` (`5E:D6:AF…`) | **yes** — `key.pem` |
| `rel-ca.pem` (`FE:4E:81…`, iHost RAUC Dev CA) | **no** |
| `legacy-signing-cert.pem` (`01:E7:CE…`, F13) | **no** |

The bridge exists so that pre-rotation devices can still verify OTAs. Doing so
requires signing a bundle **with the F13 key** — which the build pipeline does
not have. Baking F13 into new images therefore delivers nothing to *us*.

And it is worse than dead weight. Per Odoo KB #171 (2026-07-27) the retired
key's custody is loose: it was extracted from a device snapshot and a copy is
recorded as sitting unencrypted in local checkouts. If that holds, removing F13
is not hygiene — it closes a signing path that someone else can still walk while
we cannot. Either way the action is the same, but the reason is stronger than
"unused cert". The custody claim predates this work and has not been
re-verified here; the fingerprints on ga-builder do not match it (`cert.pem`
there is `5E:D6:AF…`, not F13), so treat the two records as inconsistent and
worth reconciling.

Consequence for the earlier reasoning, which was wrong: dropping the bridge does
**not** depend on proving the field free of pre-rotation devices. Whether such
devices exist changes nothing about the value of F13 in a new image — it is
zero either way. **Outcome 2026-07-30: the flag did not go to `"false"` — it was
deleted outright, together with the certificate and the bake function, because
keeping the material next to its own switch left the fleet one line away from
re-trusting it.** Odoo #534 still
blocks the separate question of how pre-rotation devices get recovered at all
(reflash, or the raw slot write above), which is not a keyring question.

Caveat: only ga-builder was searched. The key could exist on an old build host
or a backup. That would not change the conclusion — a key absent from the
machine that builds and signs cannot be part of any delivery path — but it does
mean "destroyed" is unproven, so treat F13 as *retired and unusable by us*, not
as *provably gone*.

Likewise `rel-ca.pem`'s own key is absent, so the current "CA" could never issue
anything even if someone wanted it to. It is inert in the strongest sense.
- The audit script accepts the current state (the bridge is declared, so it is
  expected) and accepts the post-migration state (`false`, legacy absent). It
  fails on the divergence between them — which is the case nothing covered
  before.
