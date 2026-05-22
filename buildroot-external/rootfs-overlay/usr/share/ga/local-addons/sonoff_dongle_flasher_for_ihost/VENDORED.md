# Vendored sonoff_dongle_flasher_for_ihost local-addon metadata

This directory holds the **Supervisor local-addon metadata** for the SONOFF
Dongle Flasher addon, baked into the V1.2-clean OS image so the Supervisor can
install the addon **offline** on first boot.

`ga_manager`'s `converge` worker installs this addon as part of its step 1
(baked local addons) and its `zigbee-firmware-update` / `zigbee_coordinator`
worker `docker exec`s into the running container to flash the Zigbee
coordinator. The Supervisor slug of a local addon is `local_<config-slug>` —
the `slug` field *inside* `config.json`, **not** the directory name (Supervisor
`store/data.py`: `addon_slug = f"{repository}_{addon[ATTR_SLUG]}"`). With
`"slug": "sonoff_dongle_flasher_for_ihost"` the Supervisor registers this as
**`local_sonoff_dongle_flasher_for_ihost`**.

## What is vendored vs. not

- **Vendored here:** `config.json`, `DOCS.md`, `icon.png`, `logo.png` — the
  addon *metadata* the Supervisor needs to register a local addon. The
  upstream `images/` directory (DOCS screenshots only) is **not** vendored —
  it is not needed to register or install the addon.
- **NOT vendored:** the addon `rootfs/` / `Dockerfile`. Those live *inside* the
  pre-baked container image
  `ghcr.io/ihost-open-source-project/hassio-ihost-sonoff-dongle-flasher-{arch}:1.2.3`
  (baked into the data partition's docker store via `addon-images.json`). The
  `image:` field in `config.json` makes the Supervisor install **from that
  baked image** instead of building from a Dockerfile — fully offline.

NB: `config.json` is JSON, which cannot carry comments — the `image:`-field
explanation that the YAML configs carry inline lives only in this file.

## Pin

| Field | Value |
|---|---|
| Source repo | `greenautarky/vibe_addons` (path `hassio-ihost-sonoff-dongle-flasher/`) |
| Vendored ref | `main` @ `59e605c` (commit `59e605c451c724d0c958bb42fb870430e78e48e5`) |
| Addon version | `1.2.3` |
| Image | `ghcr.io/ihost-open-source-project/hassio-ihost-sonoff-dongle-flasher-{arch}:1.2.3` |
| Supervisor slug | `local_sonoff_dongle_flasher_for_ihost` |

**FLAG for human review:** `vibe_addons` is vendored at a *branch HEAD*, not a
release tag. Re-pin to a proper tag once `vibe_addons` cuts one, and bump the
version strings in lockstep (this `config.json` and `addon-images.json`). The
`image:` line points at the upstream iHost-Open-Source-Project image — it
matches `addon-images.json` and is intentional (this is an upstream addon).

## Refresh procedure

```sh
REPO=greenautarky/vibe_addons
DST=buildroot-external/rootfs-overlay/usr/share/ga/local-addons/sonoff_dongle_flasher_for_ihost
for f in config.json DOCS.md icon.png logo.png; do
  gh api "repos/$REPO/contents/hassio-ihost-sonoff-dongle-flasher/$f" --jq '.content' | base64 -d > "$DST/$f"
done
# config.json already carries the `image:` field — no edit needed.
# Then bump `version` in addon-images.json and update the Pin table above.
```
