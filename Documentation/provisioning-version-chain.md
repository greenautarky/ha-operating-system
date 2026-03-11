# Provisioning Version Chain

## Version Chain Architecture

The GA OS build system produces a `version.json` file that gets baked into the
disk image at build time. This file lives at
`ga_output/build/hassio-*/version.json` during the build and ends up on the
device's data partition.

At runtime, the HA Supervisor fetches `stable.json` from GitHub:

    https://raw.githubusercontent.com/greenautarky/haos-version/main/stable.json

The Supervisor uses **both** files to determine which container image versions
to run and whether updates (or rollbacks) are needed. When the two files
disagree on versions, registries, or version-string formats, the Supervisor
enters an unhealthy state and provisioning stalls.

## Root Causes of Provisioning Failure (2026-03-11)

### 1. Supervisor `update_rollback`

The pre-baked Supervisor image was version **2025.11.4.1** (our GA patch
release), but `stable.json` advertised **2025.11.4** as the current version.
The Supervisor interpreted this as a rollback (higher installed version than the
"stable" version), marked itself unhealthy, and blocked all automatic recovery
actions.

### 2. "latest" as version string

The `stable.json` entry for `tinker/core` (the HA Core image for iHost) was set
to `"latest"` instead of a pinned version like `2025.11.3`. HA Core rejects
`"latest"` as a version string, causing the Supervisor to enter a
remove-and-re-download loop where it would pull the image, fail to validate the
version, remove it, and start again.

### 3. Wrong registry URLs

`stable.json` pointed the Supervisor image to
`ghcr.io/ihost-open-source-project/` instead of the correct
`ghcr.io/greenautarky/` registry. The Supervisor could not pull updates or
validate its own image against the wrong registry path.

### 4. No GA addon repositories on device

Flasher-py provisioning stages 60+ (install-addons) expect the device to
already have addon repositories configured (`vibe_addons`, `ga_default_addon`,
`ga_hmvapp_addon`). These repositories were not present on freshly flashed
devices, so addon installation failed silently or errored out.

## Files Involved

| Context | File | Purpose |
|---------|------|---------|
| Build | `ga_output/build/hassio-*/version.json` | Baked into the disk image at build time |
| Runtime | `https://raw.githubusercontent.com/greenautarky/haos-version/main/stable.json` | Fetched by Supervisor to check for updates |
| Device | `/mnt/data/supervisor/config.json` | Supervisor configuration (includes version fields) |
| Device | `/mnt/data/supervisor/updater.json` | Cached update information from last fetch |

## Fix Applied

1. Updated `stable.json` in the `haos-version` repo to match the build's
   `version.json` — correct versions, correct registries, no `"latest"` strings.
2. Added build tests `VER-01` through `VER-06` to catch mismatches between the
   baked `version.json` and `stable.json` before images ship.
3. Manual device fix for already-flashed units: stop the Supervisor, edit
   `config.json` to correct the version string, then restart.

## Prevention

- Build tests (`VER-01..06`) verify that `version.json` does not contain
  `"latest"` and that all image references use `ghcr.io/greenautarky/`.
- The `stable.json` in the `haos-version` repository **must** be updated
  whenever the build's `version.json` changes. A mismatch between the two will
  cause rollback detection or version-string rejection on every newly
  provisioned device.
