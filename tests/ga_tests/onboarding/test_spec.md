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

### OB-02: Core image tag matches HA version
- **Command**: `docker inspect homeassistant --format '{{.Config.Image}}' | grep -qE ':(2025\.[0-9]+\.[0-9]+|latest)'`
- **Expected**: Image tag is HA version (e.g., `2025.11.3`) or `latest`
- **Catches**: Upstream version tag or missing tag

### OB-03: HA version is displayed
- **Command**: `cat /mnt/data/supervisor/homeassistant/.HA_VERSION`
- **Expected**: Version string is present (informational)

### OB-04: Supervisor version.json references greenautarky image registry
- **Command**: Check version.json on data partition for greenautarky core image
- **Expected**: `images.core` field contains `greenautarky`

### OB-05: Version repo URL points to greenautarky
- **Command**: Verify supervisor fetches from `greenautarky/haos-version`
- **Expected**: Supervisor logs show fetch from `raw.githubusercontent.com/greenautarky/haos-version`

### OB-06: Supervisor is greenautarky fork
- **Command**: `docker inspect hassio_supervisor --format '{{.Config.Image}}' | grep -q 'greenautarky'`
- **Expected**: Supervisor image is from `ghcr.io/greenautarky`

### OB-07: All non-core components use upstream registries
- **Command**: Verify dns, audio, cli, multicast, observer containers use `home-assistant` or `homeassistant` registry
- **Expected**: Only the core image should be greenautarky; everything else stays upstream
- **Catches**: Accidental override of non-core components in version repo

### OB-08: Core image is latest (not stale pinned version)
- **Command**: Compare running image digest with `latest` tag digest on GHCR
- **Expected**: Digests match — the OS build picked up the most recent core image
- **Catches**: Stale cached image, version pinning not using `latest`

### OB-09: Custom onboarding strings present (GDPR step)
- **Command**: `docker exec homeassistant find /usr/src/homeassistant -path '*/onboarding/strings.json' -exec grep -l 'gdpr' {} \;`
- **Expected**: strings.json contains `gdpr` step definition
- **Catches**: Upstream core image used instead of custom fork, or custom strings missing

### OB-10: Custom onboarding strings present (custom_pages step)
- **Command**: `docker exec homeassistant grep -q 'custom_pages' /usr/src/homeassistant/homeassistant/components/onboarding/strings.json`
- **Expected**: strings.json contains `custom_pages` step definition
- **Catches**: Custom onboarding content not included in core build

### OB-11: Frontend wheel is custom build (not upstream)
- **Command**: `docker exec homeassistant pip show home-assistant-frontend 2>/dev/null | grep -i location`
- **Expected**: Frontend package is installed (built from greenautarky/frontend fork)
- **Catches**: Frontend wheel missing or not installed

### OB-12: No frontend-build bloat in core image
- **Command**: `docker exec homeassistant test ! -d /usr/src/homeassistant/frontend-build`
- **Expected**: `frontend-build/` directory does NOT exist inside the container
- **Catches**: .dockerignore fix not applied, 537MB bloat still present
