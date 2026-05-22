# Vendored ga_mosquitto local-addon metadata

This directory holds the **Supervisor local-addon metadata** for the GA
Mosquitto broker addon, baked into the V1.2-clean OS image so the Supervisor
can install the addon **offline** on first boot.

`ga_manager`'s `converge` worker installs this addon as part of its step 1
(baked local addons). The Supervisor slug of a local addon is
`local_<config-slug>` — the `slug:` field *inside* `config.yaml`, **not** the
directory name (Supervisor `store/data.py`: `addon_slug = f"{repository}_{addon[ATTR_SLUG]}"`).
With `slug: ga_mosquitto` the Supervisor registers this as **`local_ga_mosquitto`**.

## What is vendored vs. not

- **Vendored here:** `config.yaml`, `DOCS.md`, `icon.png`, `logo.png` — the
  addon *metadata* the Supervisor needs to register a local addon.
- **NOT vendored:** the addon `rootfs/` / `Dockerfile`. Those live *inside*
  the pre-baked container image `homeassistant/{arch}-addon-mosquitto:6.5.2`
  (baked into the data partition's docker store via `addon-images.json`). The
  `image:` field in `config.yaml` makes the Supervisor install **from that
  baked image** instead of building from a Dockerfile — fully offline.

## Pin

| Field | Value |
|---|---|
| Source repo | `greenautarky/vibe_addons` (path `mosquitto/`) |
| Vendored ref | `main` @ `59e605c` (commit `59e605c451c724d0c958bb42fb870430e78e48e5`) |
| Addon version | `6.5.2` |
| Image | `homeassistant/{arch}-addon-mosquitto:6.5.2` |
| Supervisor slug | `local_ga_mosquitto` |

**FLAG for human review:** `vibe_addons` is vendored at a *branch HEAD*, not a
release tag. Re-pin to a proper tag once `vibe_addons` cuts one, and bump the
three version strings in lockstep (this `config.yaml`, `addon-images.json`, and
the image tag). The `image:` line points at the upstream Home Assistant addon
image (`homeassistant/...`) — this is the one baked GA addon image that is not
under `ghcr.io/greenautarky/`; it matches `addon-images.json` and is
intentional (the GA Mosquitto addon is a thin wrapper over the HA addon).

## Refresh procedure

```sh
REPO=greenautarky/vibe_addons
DST=buildroot-external/rootfs-overlay/usr/share/ga/local-addons/ga_mosquitto
for f in config.yaml DOCS.md icon.png logo.png; do
  gh api "repos/$REPO/contents/mosquitto/$f" --jq '.content' | base64 -d > "$DST/$f"
done
# then re-add the `image:` comment block to config.yaml (see the comment there),
# bump `version` in addon-images.json, and update the Pin table above.
```
