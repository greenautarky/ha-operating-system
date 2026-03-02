# Custom Core Image & Onboarding Tests

## Purpose
Verify that the device runs the greenautarky custom HA Core image (not upstream)
and that the version repo configuration is correctly applied. The custom core
image provides German-language onboarding, GDPR consent, and greenautarky
telemetry preferences.

## Prerequisites
- Device booted with current build (post PR #1 merge)
- HA Supervisor running and homeassistant container started
- Network connectivity (for version.json fetch verification)

## Tests

### OB-01: Core image is greenautarky (not upstream)
- **Command**: `docker inspect homeassistant --format '{{.Config.Image}}' | grep -q 'greenautarky'`
- **Expected**: Container image is `ghcr.io/greenautarky/tinker-homeassistant:*`
- **Catches**: Build still using upstream `ghcr.io/home-assistant/tinker-homeassistant`

### OB-02: Core image version is ga-tagged
- **Command**: `docker inspect homeassistant --format '{{.Config.Image}}' | grep -q 'ga\.'`
- **Expected**: Image tag contains `ga.` suffix (e.g., `2025.11.0-ga.1`)
- **Catches**: Accidentally pulling upstream version tag

### OB-03: HA version matches expected ga build
- **Command**: `cat /mnt/data/supervisor/homeassistant/.HA_VERSION`
- **Expected**: Version string contains `-ga.` (e.g., `2025.11.0-ga.1`)

### OB-04: Supervisor version.json references greenautarky image registry
- **Command**: Check version.json on data partition for greenautarky core image
- **Expected**: `images.core` field contains `greenautarky`

### OB-05: Version repo URL points to greenautarky
- **Command**: Verify supervisor fetches from `greenautarky/haos-version`
- **Expected**: Supervisor logs show fetch from `raw.githubusercontent.com/greenautarky/haos-version`

### OB-06: Supervisor is iHost fork (not upstream HA)
- **Command**: `docker inspect hassio_supervisor --format '{{.Config.Image}}' | grep -q 'ihost-open-source-project'`
- **Expected**: Supervisor image is from `ghcr.io/ihost-open-source-project`

### OB-07: All non-core components use upstream registries
- **Command**: Verify dns, audio, cli, multicast, observer containers use `home-assistant` or `homeassistant` registry
- **Expected**: Only the core image should be greenautarky; everything else stays upstream
- **Catches**: Accidental override of non-core components in version repo
