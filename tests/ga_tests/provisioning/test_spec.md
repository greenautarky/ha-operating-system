# Converge-Provisioning Tests

## Purpose
Verify the on-device **effects of ga_manager's converge worker** for the
provisioning steps moved out of `ga-flasher-py` into converge, plus the 0.24.0
self-check. This suite reads the real device state directly — an **independent
cross-check** of converge step 8 / step 11, so it catches drift even if the
in-worker self-check were itself buggy.

Maps each assertion back to the flasher stage it replaced.

## Prerequisites
- Device booted on the V1.2-clean OS and converged (`/share/.ga_converged`)
- `ha` CLI + `jq` available on the host (standard on GA OS)
- For PROV-02/03: a Zigbee dongle present so converge configured z2m

## Tests

### PROV-01: converged marker present
- **Command**: `[ -f /share/.ga_converged ]`
- **Expected**: converge completed (step 10 wrote the marker)
- **Catches**: converge never ran / never finished

### PROV-02: z2m serial port = /dev/ttyS4 (= flasher stage 64)
- **Command**: `grep -qE 'port:[[:space:]]*/dev/ttyS4' <z2m configuration.yaml>`
- **Expected**: z2m serial points at the iHost's built-in EFR32 UART
- **Catches**: converge step 8 z2m-serial config missing → Zigbee never forms

### PROV-03: z2m advanced.channel = 15 (= ga_manager 0.23.2)
- **Command**: `grep -qE '^[[:space:]]*channel:[[:space:]]*15$' <z2m configuration.yaml>`
- **Expected**: fresh network forms on the fleet-standard channel 15
- **Catches**: channel left at z2m default (11) → fleet channel drift

### PROV-04: HA-Core MQTT config entry present (= flasher stage 65)
- **Command**: `grep -qE '"domain":[[:space:]]*"mqtt"' <core.config_entries>`
- **Expected**: converge step 8 wrote the MQTT integration entry
- **Catches**: MQTT integration missing → Zigbee/MQTT entities never appear

### PROV-05-<addon>: load-bearing addon flags (= flasher stage 69)
- **Command**: `ha addons info <slug> --raw-json | jq -e '.data.watchdog==true and .data.auto_update==false'`
- **Run for**: `ga_mosquitto`, `ga_zigbee2mqtt`, `ga_ihosthardwarecontrol` (slug resolved by identity suffix)
- **Expected**: watchdog on (survive a crash), auto_update off (fleet owns updates)
- **Catches**: converge step 8 addon-flag enforcement missing/drifted

### PROV-06: converge self-check ran and PASSED (= ga_manager 0.24.0, step 11)
- **Command**: `docker logs <ga_manager container> | grep -q 'self-check PASSED'`
- **Expected**: the on-device provisioning self-check (provision_verify) ran at
  the end of converge and reported PASSED
- **Catches**: the self-check itself failing or not running; a regression in any
  converge step that the self-check guards
