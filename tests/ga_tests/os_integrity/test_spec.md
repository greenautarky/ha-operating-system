# os_integrity — declared vs flashed

Compares the flashed system against the repo's PINNED declarations. Born
2026-08-20: rc3 shipped OpenSSL 3.4.4 against a declared 3.5.7 (stale buildroot
submodule on the builder, ga-ops#38), found only by a human on the device.

| ID | asserts | declaration source |
|---|---|---|
| OSI-00 | expected.env present + complete (fail closed, never skip) | gen_expected.sh |
| OSI-01 | /etc/ga-release | version.yaml `gaos_release` |
| OSI-02 | `uname -r` | defconfig `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` |
| OSI-03 | `openssl version` | buildroot submodule pointer → libopenssl.mk |
| OSI-04 | HA Core container image tag | version.yaml `homeassistant_core` |
| OSI-10+ | every baked add-on image present at its exact tag | addon-images.json |
| OSI-99 | coverage: ≥6 add-ons checked | — |

Expectations are generated REPO-SIDE by `gen_expected.sh` (N2: never derived
from the artefact under test). Runs on unprovisioned devices — everything here
is baked state.

**Red proof (2026-08-20, K31 on rc3 vs master@rc4):** OSI-01 red (rc3≠rc4) and
OSI-03 red (3.4.4≠3.5.7) — the second is the live defect this suite was built
for. Green proof: after the rc4 reflash, all green (recorded in the PR).
