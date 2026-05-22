# GreenAutarky Add-on: GA Manager

## Overview

GA Manager is the centralized management and supervision engine for all
GreenAutarky Home Assistant addons and shared infrastructure.

## Installation

1. Add the GreenAutarky repository to your Home Assistant instance.
2. Install the "GA Manager" add-on.
3. Start the add-on.
4. Check the logs to verify everything is running.

## Configuration

**Note**: _Remember to restart the add-on when the configuration is changed._

Example add-on configuration:

```yaml
log_level: info
```

### Option: `log_level`

The `log_level` option controls the level of log output by the addon and can
be changed to be more or less verbose, which might be useful when you are
dealing with an unknown issue. Possible values are:

- `trace`: Show every detail, like all called internal functions.
- `debug`: Shows detailed debug information.
- `info`: Normal (usually) interesting events.
- `warning`: Exceptional occurrences that are not errors.
- `error`: Runtime errors that do not require immediate action.
- `fatal`: Something went terribly wrong. Add-on becomes unusable.

By default, the `log_level` is set to `info`, which is the recommended setting
unless you are troubleshooting.

## MQTT Integration

GA Manager requires an MQTT broker (provided by the GA Mosquitto addon).
MQTT credentials are obtained automatically via the Home Assistant Supervisor API.

## Planned Capabilities

- Addon health monitoring and automatic restart
- MQTT broker status oversight
- Infrastructure service coordination
- Configuration validation across addons
- Centralized logging aggregation

## Changelog

### 0.21.0 — T4 device reconciliation

- **Lifecycle modes.** GA Manager now owns the device lifecycle. A marker
  file `/share/.ga_converged` (survives reboots + addon reinstall, wiped
  by a factory reset) distinguishes two modes: **converging** (marker
  absent — actively bring the device to the baked-in desired-state
  baseline) and **steady** (marker present — today's monitor + remediate
  behaviour). New module `mode.py`.
- **`converge` job worker.** A single observable job converges *any*
  device — fresh, v1.0 (GA OS + stock Core + stock Supervisor + GA addons,
  an admin owner plus a separate "Mieter" user) or v1.1 (the GA-fork
  stack) — to the V1.2-clean desired state. It runs one fixed ordered
  sequence: install/start the baked local addons, place the
  `greenautarky_onboarding` custom_component, create the HA owner account
  (only if HA onboarding is still pending), report that password to the
  fleet-manager, flash + verify the Zigbee coordinator, un-fork Core to the
  stock V1.2 image if it is running a GA-fork image, self-enrol into
  NetBird + Tailscale, apply the HA/DNS config baseline, arm the onboarding
  wizard (only if HA onboarding is still pending), then set the converged
  marker. There is **no class detection** — every step is idempotent and
  self-gates on actual device state, so a re-run (or a run against any
  class) is safe and effectively a no-op. On startup GA Manager
  auto-enqueues this job once while in *converging* mode; in *steady* mode
  it does not run.
- **Onboarding-gated owner + wizard steps.** The HA owner-account creation
  and the onboarding-wizard arming both act **only when HA onboarding is
  genuinely pending** (true only on a fresh device). On a v1.0 or
  onboarded-v1.1 device both are skipped — the existing admin owner and the
  separate "Mieter" normal user are left entirely untouched. This is what
  makes the worker safe to run on a device with a live tenant.
- **Core un-fork step.** If Core is running a `ghcr.io/greenautarky/...`
  fork image (a v1.1 device) the worker triggers a Core update to the stock
  V1.2 version via the Supervisor API, so the minimal V1.2-clean Supervisor
  pulls the stock upstream image. A clean no-op when Core is already stock
  (fresh + v1.0 devices). Idempotent / fail-open.
- **V1.2-clean-OS trigger.** Auto-convergence is triggered by the device
  being on the **V1.2-clean OS**, not by an identity-file. That OS's host
  service `ga-bootstrap.service` writes the marker `/share/.ga_os` on every
  boot; the service exists only on the V1.2-clean OS. GA Manager
  auto-enqueues `converge` iff `/share/.ga_os` is present and
  `/share/.ga_converged` is absent. If `/share/.ga_os` is absent the device
  is on a pre-V1.2 OS that merely received a `ga_manager` addon-update — it
  is left entirely untouched (no convergence, no marker written).
- **Pre-convergence backup.** The `converge` worker's step 0 takes a full
  Supervisor backup (`pre-convergence-<ts>`) before any convergence step — a
  recoverable snapshot for a v1.0/v1.1 device being migrated.
  Best-effort / fail-open.
- **`ga-identity.json`.** Device identity now comes from the single
  per-device artifact `/share/ga-identity.json` (`schema_version`,
  `device_id`, `device_type`, `url_prefix`, `onboarding_pin`). `auth.py`
  gains `get_identity()`; `get_device_id()` reads from it. The old
  `/share/ga-device-id` file is retired.
- **custom_component bundling.** The `greenautarky_onboarding`
  custom_component is now vendored into the addon image at build time
  (`Dockerfile`, pinned git ref) under `/usr/share/ga/custom_components/`;
  the `converge` worker copies it to `/config` on first boot.

### 0.20.0 — per-container health state

- `container.any_stopped` now reports **per-container** up/down state in
  `details.containers` (`[{name, slug, kind, state, reason?}]`) instead of
  only an aggregate count, so the fleet-manager dashboard can render each
  container precisely. The check `value` is now a `{up, down, exempt}`
  summary.
- The must-run set is the union of the bundle's `expected.addons_running`
  and the always-on infrastructure containers (`hassio_supervisor`, the HA
  Core container, `ga_manager` itself) — no hardcoded device-specific
  addon list.
- **Job-aware suppression**: when an expected container is down but an
  active `ga_manager` job legitimately stopped it (e.g.
  `zigbee-firmware-update` takes Zigbee2MQTT offline to free the
  coordinator's serial port for chipset flashing; `addon-update` /
  `addon-uninstall` / `restart` stop their target addon), that container
  is reported `unknown` ("expected-down: job &lt;type&gt; running") and
  does **not** trip a `warn`. Note `zigbee-ota-update` is *not* suppressed:
  it drives sub-device OTA *through* Zigbee2MQTT over MQTT, so z2m stays
  up and a down z2m during that job is a real fault.

## Authors & Contributors

Thomas Taube <thomas@greenautarky.com>
