# OS Layer — Privacy Tier implementation

**Sister docs**:
- Canonical: [`ga-ihost-docs/PRIVACY_TIERS.md`](https://github.com/greenautarky/ga-ihost-docs/blob/main/PRIVACY_TIERS.md)
- Roadmap: [`ga-ihost-docs/PRIVACY_IMPLEMENTATION_ROADMAP.md`](https://github.com/greenautarky/ga-ihost-docs/blob/main/PRIVACY_IMPLEMENTATION_ROADMAP.md)
- This-repo plan: [`PRIVACY_TIERS_PLAN.md`](./PRIVACY_TIERS_PLAN.md)

This file is the OS-side technical spec for Phases B + E. Covers
what changes on the device (boot-time gates, fluent-bit configs,
systemd units, file paths).

## Today's state (pre-refactor)

Single binary gate. Two markers. Two gated services.

```
.storage/greenautarky_telemetry → ga-telemetry-consent.service
                                      │
                                      ▼
                                  ga-telemetry-gate write
                                      │
                       ┌──────────────┴───────────────┐
                       ▼                              ▼
            /mnt/data/.ga-consent-metrics    /mnt/data/.ga-consent-error_logs
                       │                              │
                       ▼                              ▼
              telegraf.service               fluent-bit.service
              (ConditionPathExists)          (ConditionPathExists)
```

If both consents OFF → device ships nothing operational. Even
safety-critical signals (kernel panic, RAUC update failures) are
gated.

## Target state (post-refactor)

Three streams: Tier 0 always, Tier 1 default-ON, Tier 2 default-OFF.

```
.storage/greenautarky_telemetry (versioned)
                                      │
                                      ▼
                                  ga-telemetry-gate write
                                      │
                ┌─────────────────────┼────────────────────────┐
                │                     │                        │
                ▼                     ▼                        ▼
        (Tier 0 — no gate)     marker tier-1               marker tier-2
                │                     │                        │
                ▼                     ▼                        ▼
        fluent-bit-tier0       fluent-bit-tier1          telegraf
        (always-on)            (Cond: error_logs)        (Cond: metrics)
                │                     │                        │
                └─────────────────────┴────────────────────────┘
                                      │
                                      ▼
                               Loki / InfluxDB
                              (tier labels)
```

## File-level changes

### Modified: `/usr/sbin/ga-telemetry-gate`

Split the existing single-purpose script. Today it does:

```
ga-telemetry-gate write   → writes both markers based on consent file
ga-telemetry-gate metrics → returns 0/1 for the metrics key
ga-telemetry-gate error_logs → returns 0/1 for the error_logs key
```

New surface:

```
ga-telemetry-gate write         → writes tier 1 + tier 2 markers
ga-telemetry-gate tier1         → returns 0/1 (alias for error_logs)
ga-telemetry-gate tier2         → returns 0/1 (alias for metrics)
ga-telemetry-gate version       → prints accepted policy_version
```

The old `error_logs` / `metrics` subcommand stays as aliases for
backward compatibility (existing systemd units don't break).

**New: policy_version check** at the top of `write`:
- Read the device's accepted policy_version from storage file
- Read the OS-baked policy_version constant (`/etc/ga-policy-version`)
- If accepted < baked → emit "stale" log + remove all markers
  (forces re-consent on next browser visit)

### New: `/etc/ga-policy-version`

Baked at build-time from a constant in `buildroot-external/`. Example:
```
2
```

### New: `/usr/lib/systemd/system/fluent-bit-tier0.service`

Same shape as the existing `fluent-bit.service`, but:
- **No** `ConditionPathExists` — always starts
- Reads `/etc/fluent-bit/fluent-bit-tier0.conf` (different config)
- Loki output: same endpoint, but labels include `tier=0`
- Inputs limited to:
  - `journald` filtered to `_PRIORITY <= 4` AND specific units:
    rauc.service, ga-update.service, supervisor.service (auth log)
  - kernel panic detection via journald `MESSAGE_ID` filter
  - failed-auth via journald PAM detection

Concretely the diff vs the existing config:

```ini
# fluent-bit-tier0.conf
[SERVICE]
    Flush               5
    Log_Level           info

[INPUT]
    Name                systemd
    Tag                 tier0.host
    DB                  /mnt/data/fluent-bit/db/tier0-systemd.db
    Systemd_Filter      _SYSTEMD_UNIT=rauc.service
    Systemd_Filter      _SYSTEMD_UNIT=ga-update.service
    Systemd_Filter      PRIORITY=0
    Systemd_Filter      PRIORITY=1
    Systemd_Filter      PRIORITY=2

[INPUT]
    Name                tail
    Tag                 tier0.kernel
    Path                /var/log/kern.log
    Parser              kernel

[FILTER]
    Name                modify
    Match               tier0.*
    Add                 tier 0
    Add                 device_label ${DEVICE_LABEL}

[OUTPUT]
    Name                loki
    Match               tier0.*
    Host                ${LOKI_HOST}
    Port                3100
    Tenant_ID           greenautarky
    Labels              tier=0, device_label=${DEVICE_LABEL}
```

### Modified: existing `fluent-bit.service` → renamed `fluent-bit-tier1.service`

Just a rename for clarity. The systemd condition stays
`/mnt/data/.ga-consent-error_logs`. The config gets a `tier=1` label
in the modify filter so Loki separates streams.

### Modified: existing `telegraf.service`

Add `tier=2` label to the InfluxDB writes (via the existing
`[global_tags]` section). No condition change.

### Hostfs files affected

| Path | Purpose |
|---|---|
| `/mnt/data/.ga-consent-tier1` | Marker for fluent-bit-tier1 (was `.ga-consent-error_logs` — alias kept for compat) |
| `/mnt/data/.ga-consent-tier2` | Marker for telegraf (was `.ga-consent-metrics` — alias kept for compat) |
| `/etc/ga-policy-version` | Baked policy version |
| `/mnt/data/supervisor/homeassistant/.storage/greenautarky_telemetry` | Storage with version + per-tier accepted_at |

## Storage schema evolution (Phase E)

Today:
```json
{
  "version": 1,
  "minor_version": 1,
  "key": "greenautarky_telemetry",
  "data": {
    "error_logs": false,
    "metrics": false
  }
}
```

Target:
```json
{
  "version": 2,
  "minor_version": 0,
  "key": "greenautarky_telemetry",
  "data": {
    "policy_version_accepted": 2,
    "tiers": {
      "tier1": {
        "value": true,
        "accepted_at": "2026-05-15T13:37:34Z",
        "policy_version": 2
      },
      "tier2": {
        "value": false,
        "accepted_at": "2026-05-15T13:37:34Z",
        "policy_version": 2
      }
    },
    "legacy": {
      "error_logs": true,
      "metrics": false
    }
  }
}
```

Migration logic in `greenautarky_telemetry/__init__.py`:
- On load: if v1, read `error_logs` + `metrics` → write v2 with
  policy_version=1 (since user accepted v1 originally) + same values
- The legacy dict stays for older binaries that still expect it.
  Drops in OS build N+2 once everything has migrated.

## Acceptance test (Phase B+E combined)

Run on KIB-SON-0 after deploy:

```bash
# 1. Fresh boot, both consents OFF
ssh ... 'rm /mnt/data/.ga-consent-*; systemctl reboot'

# 2. Wait for boot, check Tier 0 still flows
ssh ... 'systemctl is-active fluent-bit-tier0'   # expect: active
ssh ... 'systemctl is-active fluent-bit-tier1'   # expect: inactive (no consent)
ssh ... 'systemctl is-active telegraf'           # expect: inactive (no consent)

# 3. From ga-tools, query Loki for Tier 0 stream
curl -G http://loki:3100/loki/api/v1/query \
  --data-urlencode 'query={tier="0",device_label="KIB-SON-00000000"}' \
  | jq '.data.result | length'  # expect: >0

# 4. Test a deliberate kernel-level event
ssh ... 'echo c > /proc/sysrq-trigger'  # forces a kernel panic

# 5. After reboot, verify the panic shows in Tier 0 Loki stream
```

## Open OS-layer questions

1. **Bake or upgrade?** The OS-layer changes (new fluent-bit-tier0
   service, gate-script split) only apply via a new OS build. That
   means devices on v1.2 don't get this until v1.3. Older devices
   stay on the binary consent gate. Acceptable since refactor is
   forward-looking; document this.

2. **Tier-0 storage costs**: kernel events are infrequent (good),
   but if a device boot-loops, we get many panic events fast. Need
   Loki retention policy on `tier=0` separate from `tier=1`.
   Recommendation: 365 days for tier=0 (security audit value),
   90 days for tier=1 (operational utility), 30 days for tier=2.

3. **DEVICE_LABEL vs device_id**: Tier 0 logs use DEVICE_LABEL
   (human-readable, "KIB-SON-00000000"), Tier 1 logs use device_id
   (UUID). Decision: standardize on device_id everywhere; DEVICE_LABEL
   is fine as additional context but pseudonymization should be the
   primary label.

## Implementation steps for Phase B (concretely)

1. Add baked-in `/etc/ga-policy-version` (constant `1` initially)
2. Add new fluent-bit-tier0 config file in
   `buildroot-external/rootfs-overlay/etc/fluent-bit/fluent-bit-tier0.conf`
3. Add new systemd unit `fluent-bit-tier0.service` in
   `buildroot-ihost/rootfs-overlay/etc/systemd/system/`
4. Symlink in `multi-user.target.wants/` to auto-enable
5. Update `ga-telemetry-gate` script (split + version check)
6. Bake into next OS image
7. Push to KIB-SON-0 canary for acceptance test

## Rollback safety

If Phase B introduces issues:
- Old fluent-bit.service binary still exists (renamed but functional)
- Old `.ga-consent-error_logs` marker name still recognized (alias)
- Operator can `systemctl disable fluent-bit-tier0` if needed
- Worst case: revert the OS commit, re-flash device with v1.2 image
