# Vendored ga_zigbee2mqtt local-addon metadata

This directory holds the **Supervisor local-addon metadata** for the GA
Zigbee2MQTT addon, baked into the V1.2-clean OS image so the Supervisor can
install the addon **offline** on first boot.

`ga_manager`'s `converge` worker installs this addon as part of its step 1
(baked local addons). The Supervisor slug of a local addon is
`local_<config-slug>` — the `slug` field *inside* `config.json`, **not** the
directory name (Supervisor `store/data.py`: `addon_slug = f"{repository}_{addon[ATTR_SLUG]}"`).
With `"slug": "ga_zigbee2mqtt"` the Supervisor registers this as
**`local_ga_zigbee2mqtt`**.

## What is vendored vs. not

- **Vendored here:** `config.json` — the addon *metadata* the Supervisor needs
  to register a local addon. The upstream `vibe_addons/zigbee2mqtt` directory
  carries only `config.json` (no DOCS.md / icons), so nothing else is vendored.
- **NOT vendored:** the addon `rootfs/` / `Dockerfile`. Those live *inside* the
  pre-baked container image `ghcr.io/zigbee2mqtt/zigbee2mqtt-{arch}:2.6.3-1`
  (baked into the data partition's docker store via `addon-images.json`). The
  `image:` field in `config.json` makes the Supervisor install **from that
  baked image** instead of building from a Dockerfile — fully offline.

NB: `config.json` is JSON, which cannot carry comments — the `image:`-field
explanation that the YAML configs carry inline lives only in this file.

## Pin

| Field | Value |
|---|---|
| Source repo | `greenautarky/vibe_addons` (path `zigbee2mqtt/`) |
| Vendored ref | `main` @ `59e605c` (commit `59e605c451c724d0c958bb42fb870430e78e48e5`) |
| Addon version | `2.6.3-1` |
| Image | `ghcr.io/zigbee2mqtt/zigbee2mqtt-{arch}:2.6.3-1` |
| Supervisor slug | `local_ga_zigbee2mqtt` |

**FLAG for human review:** `vibe_addons` is vendored at a *branch HEAD*, not a
release tag. Re-pin to a proper tag once `vibe_addons` cuts one, and bump the
version strings in lockstep (this `config.json` and `addon-images.json`).

## Refresh procedure

```sh
REPO=greenautarky/vibe_addons
DST=buildroot-external/rootfs-overlay/usr/share/ga/local-addons/ga_zigbee2mqtt
gh api "repos/$REPO/contents/zigbee2mqtt/config.json" --jq '.content' | base64 -d > "$DST/config.json"
# config.json already carries the `image:` field — no edit needed.
# Then bump `version` in addon-images.json and update the Pin table above.
```
