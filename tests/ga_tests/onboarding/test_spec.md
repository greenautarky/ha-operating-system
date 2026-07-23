# Core Image & Onboarding Tests

## Purpose
Verify the **V1.2-clean model**: the device runs **stock upstream HA Core**
(the Core fork is retired) plus the `greenautarky_site`
**custom_component**, which provides German-language onboarding, GDPR consent,
and greenautarky telemetry preferences. The **Supervisor** stays a greenautarky
fork (iHost hardware + GA version-URL); Core and the frontend are stock.

## Prerequisites
- Device booted on the V1.2-clean OS and converged (`/share/.ga_converged`)
- HA Supervisor running and the `homeassistant` container started
- Network connectivity (for version.json fetch verification)

## Tests

### OB-01: Core image is stock upstream (Core fork retired)
- **Command**: `docker inspect homeassistant --format '{{.Config.Image}}' | grep -q 'ghcr.io/home-assistant/'`
- **Expected**: Container image is `ghcr.io/home-assistant/tinker-homeassistant:*`
- **Catches**: Device still on a `ghcr.io/greenautarky/*` Core fork image (un-fork incomplete)

### OB-02: Core image tag is a pinned HA version
- **Command**: `docker inspect homeassistant --format '{{.Config.Image}}' | grep -qE ':2025\.[0-9]+\.[0-9]+'`
- **Expected**: Image tag is a pinned HA version (e.g., `2025.11.3.2`)
- **Catches**: `latest` tag or a missing/upstream version tag

### OB-03: HA version is displayed
- **Command**: `cat /mnt/data/supervisor/homeassistant/.HA_VERSION`
- **Expected**: Version string is present (informational)

### OB-04: Supervisor version.json references a STOCK core image
- **Command**: Check version.json on the data partition for the core image
- **Expected**: `images.core` field contains `home-assistant` (stock), NOT `greenautarky`
- **Catches**: Release manifest still pinning a Core fork image (T2b incomplete)

### OB-05: Version repo URL points to greenautarky
- **Command**: Verify supervisor fetches from `greenautarky/haos-version`
- **Expected**: Supervisor logs show fetch from `raw.githubusercontent.com/greenautarky/haos-version`

### OB-06: Supervisor is greenautarky fork
- **Command**: `docker inspect hassio_supervisor --format '{{.Config.Image}}' | grep -q 'greenautarky'`
- **Expected**: Supervisor image is from `ghcr.io/greenautarky` (the one permanent GA fork)

### OB-07: All non-core components use upstream registries
- **Command**: Verify dns, audio, cli, multicast, observer containers use `home-assistant`/`homeassistant`
- **Expected**: In V1.2-clean **only the Supervisor** is greenautarky; Core, frontend and all plugins are upstream
- **Catches**: Accidental override of a non-supervisor component in the version repo

### OB-08: Core image is not stale
- **Command**: Show the running core image digest (informational freshness check)
- **Expected**: A digest is present — the OS build picked up the pinned core image
- **Catches**: Stale cached image

### OB-09: greenautarky_site custom_component placed
- **Command**: `[ -f /mnt/data/supervisor/homeassistant/custom_components/greenautarky_site/manifest.json ]`
- **Expected**: The custom_component is present (placed by ga_manager converge step 2)
- **Catches**: Converge didn't place the component → no GA onboarding/GDPR/telemetry UI

### OB-10: greenautarky_site manifest declares its domain
- **Command**: `grep -q 'greenautarky_site' /mnt/data/supervisor/homeassistant/custom_components/greenautarky_site/manifest.json`
- **Expected**: manifest.json declares `domain: greenautarky_site`
- **Catches**: A stray/empty component directory. Runtime registration is further proven by OB-13/PW-* (the component's HTTP views).

### OB-11: Stock frontend wheel installed
- **Command**: `docker exec homeassistant pip show home-assistant-frontend`
- **Expected**: The stock `home-assistant-frontend` package is installed (ships inside the stock Core image)
- **Catches**: Frontend wheel missing or not installed

### OB-12: No frontend-build bloat in core image
- **Command**: `docker exec homeassistant test ! -d /usr/src/homeassistant/frontend-build`
- **Expected**: `frontend-build/` directory does NOT exist inside the container
- **Catches**: Frontend source-build bloat leaking into the image
