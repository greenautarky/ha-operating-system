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

### OB-01: Core image is the GA armv7 build
- **Command**: `docker inspect homeassistant --format '{{.Config.Image}}' | grep -q '^ghcr.io/greenautarky/home-assistant-armv7:'`
- **Expected**: Container image is `ghcr.io/greenautarky/home-assistant-armv7:*`
- **Catches**: Device still on the frozen upstream armv7 image (`ghcr.io/home-assistant/tinker-homeassistant`)

### OB-02: Core image tag is a pinned HA version
- **Command**: `docker inspect homeassistant --format '{{.Config.Image}}' | grep -qE ':20(2[6-9]|[3-9][0-9])\.[0-9]+\.[0-9]+(\.[0-9]+)?$'`
- **Expected**: Image tag is a pinned HA version from 2026 on (e.g., `2026.8.2`), optionally with the GA rebuild counter as a fourth component (`2026.8.2.1`). The exact pin is OSI-04.
- **Catches**: `latest` tag or a missing/upstream version tag

### OB-03: HA version is displayed
- **Command**: `cat /mnt/data/supervisor/homeassistant/.HA_VERSION`
- **Expected**: Version string is present (informational)

### OB-04: Supervisor version.json references the GA armv7 Core image
- **Command**: Check version.json on the data partition for the core image
- **Expected**: `images.core` is `ghcr.io/greenautarky/home-assistant-armv7`
- **Catches**: Release manifest still pinning the frozen upstream armv7 image

### OB-05: Version repo URL points to greenautarky
- **Command**: Verify supervisor fetches from `greenautarky/haos-version`
- **Expected**: Supervisor logs show fetch from `raw.githubusercontent.com/greenautarky/haos-version`

### OB-06: Supervisor is greenautarky fork
- **Command**: `docker inspect hassio_supervisor --format '{{.Config.Image}}' | grep -q 'greenautarky'`
- **Expected**: Supervisor image is from `ghcr.io/greenautarky` (the one permanent GA fork)

### OB-07: Supervisor plugins come from the declared origin
- **Command**: for each `slug=image:tag` in `EXPECTED_PLUGINS` of `../os_integrity/expected.env`, the repository of `docker inspect hassio_<slug>` (tag stripped) equals the declared repository; then a coverage row asserts five plugins were checked
- **Expected**: Every plugin runs from the repository the release declares. Which plugins GA builds is read from the pinned expectation, not written into the test (since BOSv1.4.0-rc3 all five are GA builds). The exact tag is OSI-20..24.
- **Catches**: A plugin pulled from a registry the release does not declare. A missing `expected.env` or a plugin that does not run is a FAIL, not a skip.

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

### OB-10a/b/c: Onboarding PIN present, 0600, six digits
- **Command**: first of `.storage/greenautarky_secrets/onboarding_pin` (canonical, Core-private) and `ga-onboarding-pin` (compat) under `/mnt/data/supervisor/homeassistant/` — the order ga_manager's `auth.get_onboarding_pin()` reads them; `stat -c %a`, `grep -qE '^[0-9]{6}$'`
- **Expected**: file present, mode 600, content is six digits. The PIN is never printed.
- **Catches**: A provisioned device without a PIN, a world-readable PIN, a malformed PIN. SKIP only when neither file exists.

### OB-14: Ethernet default is OFF without consent or override
- **Command**: `GA_ENV_FILE=… GA_FORCE_BOOT=… GA_GM_DATA_DIR=… GA_LABEL_FILE=…` (all pointing at a nonexistent path) `/usr/sbin/ga-manage-ethernet status`
- **Expected**: `ethernet_enabled=false` and `ethernet_source=default`. `status` is read-only.
- **Catches**: A decision rule that turns Ethernet on when nobody consented (the old `GA_ETHERNET_DISABLED` scheme, where an absent key meant ON). The running link against this device's consent is the ethernet_force suite.
