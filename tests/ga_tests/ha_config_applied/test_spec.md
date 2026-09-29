# HA Config Applied — test spec

**Run it:** after provisioning, after an OTA, after any reconcile.

```sh
sh /usr/share/ga-tests/run_all.sh ha_config_applied     # on the device
```

## What it is for

Every assertion compares **Core's own state** to what is on disk. Nothing here
checks a file against another file, and that is the entire design:

> On 2026-08-19 six ga_manager releases shipped in one day. Every defect in them
> was found by a device and none by the test suite, and they shared one shape —
> a file that looked correct while Core ran something else.

The worst of them wrote `ga_packages/ga_integrations.yaml` perfectly and then
deleted the `packages:` key that includes it. Core lost all four GA
integrations. Nothing about the package file was wrong.

## Checks

| ID | Asserts | Why it can go red |
|---|---|---|
| HCA-01/02 | ga_manager runs, Core `/api/config` readable | Without these the suite could only check disk, which is the failure mode it exists for — so they FAIL, never skip |
| HCA-03/04 | `configuration.yaml` exists, exactly one `homeassistant:` block | Two blocks is a duplicate mapping key: the loader keeps the last and half the settings vanish silently |
| HCA-05 | a `ga_packages/` directory implies the include key | **The 2026-08-19 regression, verbatim.** Fires while the state is still harmless — before the Core restart that turns it into lost integrations |
| HCA-06/07 | every OS-staged component is declared | A component delivered by an OTA that nothing ever enabled |
| HCA-08 | every declared domain is **LOADED IN CORE** | Declared ≠ loaded. A broken include, a bad manifest, or a setup error all look identical from disk |
| HCA-09/10 | Core **runs** the file's value for every key ga_manager owns in `homeassistant:` — latitude/longitude/elevation (09), time_zone/country/unit_system (10) | File and Core disagree for as long as it takes Core to restart; a device in that state computes every sunrise for the previous location. Compared by VALUE in `site_config_verdict.sh`: a number as a number (the old `grep '"latitude": *52.52'` was a prefix match and passed Core running 52.5291), `unit_system` as the length/temperature/mass units Core reports for it (Core never returns the name). Core unreadable is FAIL; key absent from the file is SKIP |
| HCA-11 | **Information, never fails** (since 2026-09-29): records Core's `config_source` | It used to assert `config_source == yaml` as "our file is authoritative". It is not that. Home Assistant 2026.8.2 `homeassistant/core_config.py`, `async_process_ha_core_config` (~l.374–411): Core loads `.storage/core.config`, then every key present in the YAML `homeassistant:` block overrides the stored value and sets `config_source=yaml` — at every start and on `reload_core_config`; `config/core/update` (how ga_manager ≥ 0.216.0 applies config live) sets `storage` until the next start. The field names the **last writer**: it went storage/yaml between two identical flashes on a canary and would read red after every correct live update. Authority is what HCA-09/10 check directly |
| HCA-12 | `ga_logger.yaml` present | HA log levels unmanaged |
| HCA-13 | log levels raised **and** HA-log shipping enabled | The disclosure needs both switches, in two different systems, with no privacy filter on that path. Raised-but-not-shipped is a WARN, not a failure — it is a legitimate operator choice |
| HCA-15 | Core runs the `internal_url` from configuration.yaml | file written, Core not restarted — the url a resident is handed is the old one |
| HCA-16 | `internal_url` is `http://<live hostname>.local` plus Core's port (`:<port>`, none on :80 — ADR-0038; port from `lib/ha_port.sh`, failure recorded as HCA-16a) | a url left over from before a rename points at whatever answers that mDNS name on the LAN, which with two GA devices is the neighbour; a url with `:8123` on Core 2026.8 points at a closed port |
| HCA-17 | `external_url` names **this** device's prefix | a url from a previous identity hands out a link to another tenant. SKIP, not FAIL, on a device with no `url_prefix` yet — it has not been released, so the url is not due |
| HCA-14 | `provision-verify` passes | The device's own verdict, so one command after provisioning answers both questions. A disagreement between this suite and that check is itself information |

## Demonstrated

**Green**, K0, 2026-08-19: `21 passed, 2 failed` — the two failures honest
(`ga_logger.yaml` needs ga_manager 0.124.0; `provision-verify` reports K0's
known `ha_core_urls` gap).

**Red**, same device, same run, with the include removed and Core *not*
restarted:

```
FAIL  HCA-05: if ga_packages/ exists, configuration.yaml includes it
PASS  HCA-08:greenautarky_site: Core reports 'greenautarky_site' as loaded
--- 20 passed, 3 failed
```

HCA-05 red while HCA-08 is still green is the point: the suite catches the
state **before** the restart that would destroy it. `provision-verify` reported
the same fault only after the integrations were already gone.

Restored, and green again: `21 passed, 2 failed`.


## Added 2026-08-26 — the urls (HCA-15..17)

ga_manager 0.133.0 moved `internal_url`/`external_url` onto the reconcile path
(Odoo #701). Until then they were written by `converge` alone, which runs once
per device lifetime, so a device converged months earlier simply never had them
— and this suite could not see it: it checked location, integrations and log
levels, and said nothing about the two urls a resident and the fleet use to
reach the device.

### Demonstrated on K31 (latest software), 2026-08-26

Green: `26 passed, 1 failed, 0 skipped` — the failure is `HCA-14`
(`provision-verify`), reporting pre-existing gaps unrelated to the urls.

Red, with a url left over from before a rename and an `external_url` naming
another tenant:

```
FAIL  HCA-15: Core runs the configured internal_url (http://kibu-OLD.local:8123)
FAIL  HCA-16: internal_url matches the live hostname (KiBu), not a stale one
FAIL  HCA-17: external_url names THIS device's prefix (yres329c)
FAIL  HCA-17b: Core runs the configured external_url
```

Restored, and green again.

### Three parsing bugs the green run found

Each made a check unable to pass, and none was visible by reading:

- `sed 's/.*: *//'` is greedy, and a url contains colons — `internal_url:
  "http://kibu.local:8123"` yielded **`8123`**. All key extraction now goes
  through one `cfg_value()` helper using `^[^:]*:`, so the bug cannot come back
  per call site.
- `grep '"hostname"'` also matches the entry in the Supervisor's `features`
  list; `head -1` took that one and the value came out empty. The pattern needs
  the colon.
- the value arrived as `"\nKiBu"` without a newline strip.

This is why the must-pass half exists. Red proof alone would have shipped three
checks that could never go green — and a check that cannot pass teaches people
to ignore the colour just as fast as one that cannot fail.

### One fault is reported once

`HCA-16` skips when there is no `internal_url` at all, pointing at `HCA-15`;
`HCA-17b` does the same for `HCA-17`. Without that, a single missing url
produced four red lines and hid how many things were actually wrong.


## Changed 2026-09-29 — HCA-11 stops asserting the last writer

HCA-11 asserted `config_source == yaml`. That field says which writer touched
Core's config last, not whether our file wins (see the HCA-11 row for the Core
source). The check that answers "is our file authoritative" is the value
comparison, so it moved there: HCA-09/10 now compare every key ga_manager owns
(converge `HA_CORE_CONFIG_BASELINE` + `HA_LOCATION_SEED`) by value, including
`unit_system`, which nothing checked before. HCA-11 prints `config_source` and
passes.

The verdict lives in `site_config_verdict.sh` (sh + jq), so CI drives it over
fixtures without a device: `selftest.sh`, wired into `lint.yml` host-suites.
`cfg_value` delegates to the same file, so key extraction still has one
definition — now restricted to the `homeassistant:` block.

### Red and green, fixtures (host, 2026-09-29)

The old predicates, verbatim, over the fixtures:

```
old HCA-11 on yaml-matching: PASS
old HCA-11 on storage-matching: FAIL
old HCA-09:latitude on latitude-lookalike (Core 52.5200081, file 52.520008): PASS  <- wrong
```

The new section, driven with the same fixtures:

```
--- Core fixture: storage-matching        -> passed=7 failed=0
--- Core fixture: moved-latitude
  FAIL  HCA-09:latitude: Core runs the configured latitude (52.520008)
        -> file latitude=52.520008; Core runs latitude=48.137154 (config_source=storage)
  PASS  HCA-11: config_source recorded (info: names Core's last writer, not authority)
```

Mutations of the live verdict, each caught by the selftest (exit 1):
HCA-11 back to `config_source == yaml` (5 wrong); numeric compare back to the
prefix grep (1 wrong, latitude-lookalike); unit_system not compared (2 wrong);
extraction over the whole file instead of the block (2 wrong). Restored:
`49 cases, 0 wrong`, also under BusyBox applets.

**Not yet shown on a device** — the fixtures are Core 2026.8.2's `/api/config`
shape; the first device run after this lands is the on-device proof.
