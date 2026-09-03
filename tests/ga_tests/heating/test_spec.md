# heating — ADR-0021 outcomes on a commissioned device

The OUTCOME line for ADR-0021 (heating responsibilities: control and valve
calibration in the ga_heating custom component, add-ons are data producers,
one sender per valve). Asked of the device itself: Core's state machine via
the ga_manager add-on (`/core/api/states`), the entity/device registries,
`.storage/ga_heating`, and the z2m / add-on container logs.

- HEAT-01 a live ga_heating room entity per area holding a z2m TRV (registry
  join: `unique_id ga_heating_<area_id>`, not a guessed slug).
- HEAT-02 <= 2 messages per valve on `zigbee2mqtt/<ieee>/set` in 10 min.
  Red on K31 rc22 (2026-09-03): hmvapp 1.7.1 sent 22 per valve in 8 min.
- HEAT-03 rooms with a dedicated sensor carry `calibration{offset,written_at}`
  per valve and the valve's `number.<ieee>_local_temperature_calibration` is
  not `unknown`. RED until the ga_heating calibration release ships.
- HEAT-04 `.storage/ga_heating` `room_modes[<room>]` == live state (the
  2026-08-27 "mode never reached the state machine" class, ga-heating #27).
- HEAT-05 no `/set` publish carrying `occupied_heating_setpoint`/`system_mode`
  in the hmvapp/default_addon logs; hmvapp absent is a PASS (rework may remove it).

Every test SKIPs with its reason on a device without a paired TRV.
Fixture-proven red (5/5 FAIL) and green (6/6 PASS) on 2026-09-03 with a docker
shim; set `GA_HEAT_HA_DIR` to point the registries/store at a fixture tree.
