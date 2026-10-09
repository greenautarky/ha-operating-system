# heating — ADR-0021 outcomes on a commissioned device

The OUTCOME line for ADR-0021 (heating responsibilities: control and valve
calibration in the ga_heating custom component, add-ons are data producers,
one sender per valve) and for its §3, the heating decision contract v1
(ga_heating 0.4.0 consumes, the closed engine ga_hmvapp_addon >= 2.0.0
produces). Asked of the device itself: Core's state machine via the
ga_manager add-on (`/core/api/states`, reduced to `climate.*`, `number.*`,
`sensor.hm_*`), the entity/device registries, `.storage/ga_heating`, the local
InfluxDB (`gd_data`, under the engine's own delivered credential), and the
z2m / mosquitto / add-on container logs.

- HEAT-01 a live ga_heating room entity per area holding a z2m TRV (registry
  join: `unique_id ga_heating_<area_id>`, not a guessed slug).
- HEAT-02 <= 2 messages per valve on `zigbee2mqtt/<ieee>/set` in 10 min.
  Red on K31 rc22 (2026-09-03): hmvapp 1.7.1 sent 22 per valve in 8 min.
- HEAT-03 rooms with a dedicated sensor carry
  `calibration{offset,written_at,source}` per valve (ga_heating 0.4.0 shape,
  confirmed on K31 2026-09-03; `source` is `hmvapp`/`default`/null and says
  whose offset sits on the valve) and the valve's
  `number.<ieee>_local_temperature_calibration` is not `unknown`. RED on a
  device still carrying ga_heating < 0.4.0.
- HEAT-04 `.storage/ga_heating` `room_modes[<room>]` == live state (the
  2026-08-27 "mode never reached the state machine" class, ga-heating #27).
- HEAT-05 no `/set` publish carrying `occupied_heating_setpoint`/`system_mode`
  in the hmvapp/default_addon logs; hmvapp absent is a PASS (rework may remove it).
- HEAT-06 for every valve in a room with a dedicated sensor,
  `sensor.hm_<ieee>_desired_offset` exists with a numeric state, `contract == 1`
  and `valid_until` in the future. ISO-8601 UTC stamps are compared as strings
  on their first 19 characters (`date -u +%Y-%m-%dT%H:%M:%S`; BusyBox has no
  `date -d`). SKIP when the engine container is absent or up < 15 min
  (`docker ps` Status text, no date arithmetic); FAIL otherwise.
- HEAT-07 a `gd_data.hm_liveness` row (tag `room` = area id, resolved from the
  room entity's `unique_id`) younger than 5 min per room with a dedicated
  sensor — `SELECT LAST("decided") … WHERE "room"='<area>' AND time > now() - 5m`
  on host `:8086`, credential read from the engine's host-side `options.json`
  and handed to curl via `--data-urlencode`, never printed. SKIP when the
  engine or ga_influxdbv1 is absent, or when there is no credential path
  (options.json without `INFLUXDB_USERNAME`/`INFLUXDB_PASSWORD`, or no curl);
  FAIL when the engine is present and a room has no fresh row or InfluxDB
  refuses the credential.
- HEAT-08 in the mosquitto log of the last 10 min, `New client connected`
  lines whose client id starts with `ga_hmvapp` <= 10, AND lines from the
  engine container's address <= 10 (hmvapp 1.7.1 opened a fresh client per
  read and write under paho's random ids, which a prefix alone misses); total
  connect count reported for coverage. SKIP when mosquitto or the engine is absent.

- HEAT-12 every ga_heating room is back in the mode it had BEFORE the suite
  (Odoo #1195). HEAT-09 writes a valve, which ga_heating (>= 0.11, ADR-0021)
  reads as a hand on the radiator: the room goes `heat` (manual) for 3 h. The
  suite snapshots every room's mode (`room_modes.sh`, entity state of each
  climate.* room carrying `valves`) before any write; HEAT-12 restores each room
  that differs through `climate.set_hvac_mode` on the room entity, waits
  `GA_HEAT_RESTORE_SETTLE_S` (30 s), re-reads Core and repeats (up to
  `GA_HEAT_RESTORE_ROUNDS` = 4) until a round needs no write — a battery valve's
  late report can make the room manual again after a one-shot restore — then
  asserts on a fresh read and names every room not back. The room's OWN mode,
  never a blanket `auto`: a room a resident had on manual stays manual. Rooms
  that did not change are not written (a press would end a running boost or
  absence). An EXIT/INT/TERM trap runs the same restore when the suite dies
  early. Known limit: `manual_until` cannot be set through the API, so a room
  already manual before the suite may have its 3 h cap restarted.

Every TRV-dependent test SKIPs with its reason on a device without a paired TRV.

Fixture proof: `selftest.sh` runs the LIVE `test.sh` over `fixtures/` with a
docker/curl shim (`fixtures/shim/`); `base/` is the finished device, every
other directory holds only what differs. Overrides used: `GA_HEAT_HA_DIR`,
`GA_HEAT_ADDON_DATA`, `GA_HEAT_TMP`; fixtures with a `fake-ha` marker get a
STATEFUL Core (`GA_HEAT_LIVE`: service calls change what the next read returns,
a valve write turns an `auto` room manual, `late-echo` re-manuals it once after a
restore, `hvac-refused` makes `set_hvac_mode` fail), and the selftest checks
where the rooms END plus three mutations of `room_modes.sh` (no restore, hard
`auto`, one-shot without re-check), each of which must turn HEAT-12 red. CI runs it on every PR (lint.yml, step
"Heating suite selftest", next to provisioning/selftest.sh).
