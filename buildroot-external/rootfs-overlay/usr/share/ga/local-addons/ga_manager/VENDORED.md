# Vendored ga_manager local-addon metadata

This directory holds the **Supervisor local-addon metadata** for the
`ga_manager` addon, baked into the V1.2-clean OS image so the Supervisor can
install the addon **offline** on first boot.

## What is vendored vs. not

- **Vendored here:** `config.yaml`, `DOCS.md`, `icon.png`, `logo.png` — the
  addon *metadata* the Supervisor needs to register a local addon.
- **NOT vendored:** the addon `rootfs/`, `Dockerfile`, `requirements.txt`.
  Those live *inside* the pre-baked container image
  `ghcr.io/greenautarky/ga_manager-{arch}:0.21.0` (baked into the data
  partition's docker store via `addon-images.json`). The `image:` field added
  to `config.yaml` makes the Supervisor install **from that baked image**
  instead of building from a Dockerfile — so no Dockerfile is needed and the
  install is fully offline.

## Pin

| Field | Value |
|---|---|
| Source repo | `greenautarky/ga_manager` |
| Vendored ref | `feat/t4-reconciliation` @ `2ab9dc8` (commit `2ab9dc80dbf372c1fd9590bab0ac8e25777032b5`) |
| Addon version | `0.21.0` |
| Image | `ghcr.io/greenautarky/ga_manager-{arch}:0.21.0` |

**FLAG for human review:** `feat/t4-reconciliation` is a *branch HEAD*, not a
release tag — `ga_manager` PR #21 (the `converge` worker) is not yet merged /
tagged. Re-pin this to a proper release tag (and bump the three version
strings in lockstep: this `config.yaml`, `addon-images.json`, and the GHCR
tag) once `ga_manager` cuts the V1.2 release tag.

## Refresh procedure

To bump the vendored metadata after a `ga_manager` release:

```sh
GA_MGR=/path/to/ga_manager/checkout      # at the new tag
DST=buildroot-external/rootfs-overlay/usr/share/ga/local-addons/ga_manager
cp "$GA_MGR/ga_manager/config.yaml" "$GA_MGR/ga_manager/DOCS.md" \
   "$GA_MGR/ga_manager/icon.png"   "$GA_MGR/ga_manager/logo.png"  "$DST/"
# then re-add the `image:` field to config.yaml (see the comment there),
# bump `version:` in addon-images.json, and update the Pin table above.
```
