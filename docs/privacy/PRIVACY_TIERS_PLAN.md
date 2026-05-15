# Privacy Tiers Refactor — Plan (review before implementation)

**Status**: design draft, awaiting review (2026-05-15).
**Scope**: cross-repo (ha-core / homeassisant_core, ha-operating-system,
ga_manager, ga-fleet-manager).
**Effort**: ~2 days focused work, split into 7 phases.

> ⚠️ This is **NOT legal advice**. The document interprets DSGVO/TTDSG/CRA
> based on common practice for IoT/smart-home products. A lawyer should
> review before production rollout (especially before B2B-Verkäufe).

## Why we're doing this

Current state (post 0.9.3): consent is a binary YES/NO per
`error_logs` and `metrics`. Operator who declines gets a device that
is fully blind to the operator team — no logs, no metrics. Operator
who accepts has no granular control over *what* gets shipped.

Problems:
1. **Theatre toggle** — users learn to click "Yes" because the alternative
   makes the device unusable for support. Consent becomes meaningless.
2. **No always-on baseline** — even mission-critical signals
   (security events, version drift) are gated behind consent. CRA
   requires automatic security updates → we need to at least *know*
   if a device's update succeeded.
3. **No legal-basis differentiation** — we treat data collected for
   contract performance (Vertragserfüllung) the same as analytics.
   The DSGVO permits the former without consent.
4. **No data-subject-rights API** — right-to-export and right-to-delete
   are missing. CRA + DSGVO eventually require both.
5. **No versioning** — policy text changes won't trigger re-consent.

## The tier model

Four tiers, each with explicit legal basis + toggle behavior:

| Tier | What | Legal basis (DSGVO Art. 6) | Toggle? | Examples |
|---|---|---|---|---|
| **0 — Betriebsnotwendig** | Data we MUST have to deliver the contracted service | (b) Vertragserfüllung + (f) berechtigtes Interesse | **NO toggle** — always on | device-id, OS/Supervisor/Core version, bundle-drift state, last-seen, security events (kernel panic, OOM, RAUC rollback, failed auth attempts) |
| **1 — Operative Fehlerbehebung** | Logs that help us fix bugs operationally | (f) berechtigtes Interesse | **Default ON, opt-out** anytime | structured app logs (level=INFO/WARN/ERROR), addon lifecycle events, network state changes |
| **2 — Performance & Patterns** | Time-series that reveal user patterns or aggregate-only behavior | (a) Einwilligung | **Default OFF, opt-in** | CPU/RAM/Disk-Timeseries, network traffic, addon usage frequency |
| **3 — Debug-Snapshot** | Full system dumps for a specific incident | (a) Einwilligung mit Zweckbindung | **Per-incident**, time-limited | full log archive, config dumps, remote-shell logs |

## Tier 0 — what specifically belongs here

Reasoning: data needed to fulfill the contract (running a managed fleet
device with secure auto-update) is processable under (b) without
consent. Aggregated/pseudonymized data we use for fleet operations is
processable under (f) — we have a legitimate interest in keeping our
devices alive and secure, balanced against minimal user impact.

The bar for Tier 0: removing this data would make the device
non-operational for the purpose the user bought it for.

Concrete data items:

- **device_id** (UUID generated at flash, not linked to person)
- **OS/Supervisor/Core/Frontend versions** (from /info)
- **bundle_drift state** (expected vs running)
- **last_seen timestamp** (when did device last respond)
- **boot slot + reboot counter** (security: detect tampering)
- **failed authentication attempts on device admin** (security log)
- **RAUC update events** (CRA requirement: track update success/failure)
- **kernel panic / OOM kill markers** (stability indicator)

Notably NOT in Tier 0:
- ❌ user-account names (personenbezogen)
- ❌ which entities/automations the user configured (use patterns)
- ❌ network traffic data (could reveal third-party services used)
- ❌ CPU/RAM/Disk timeseries (use patterns)

## Tier 1 — what specifically belongs here

The principle: structured operational logs that help us understand
"did the device work today?" without exposing sensitive user data.

We rely on (f) berechtigtes Interesse — the user has a legitimate
interest in their device working, we have a legitimate interest in
fixing it, and the balance favors processing IF we strip
user-identifying content.

Concrete data items:

- **ga_manager structured logs** (the JSON output from 0.9.3) — health
  ticks, job lifecycle, addon updates, drift detection
- **Supervisor logs** — addon start/stop events, update results
- **HA Core operational logs** — only WARN/ERROR level, structured;
  excludes anything containing entity state values
- **Addon-installation events** — which addons added/removed (not
  configuration values)

Pseudonymization: device_id is the only identifier in these logs.
User accounts are NEVER referenced by username — replaced with a
stable hash if at all.

Toggle: **default ON, opt-out anytime**. Opt-out is honored within
one boot cycle (markers re-evaluated → fluent-bit-tier-1 stops).

## Tier 2 — what specifically belongs here

Performance + behavioral data. Useful for capacity planning,
benchmarking, identifying performance regressions. Reveals patterns
that could correlate with user behavior.

Examples:
- CPU/RAM/Disk timeseries (current `telegraf` output)
- Network interface byte counters
- Addon CPU/memory consumption per addon
- HA entity-count statistics (e.g., "this device has 47 entities of
  type sensor.* and 12 binary_sensor.*")

Notably NOT in Tier 2 (would be Tier 3):
- Per-entity state values
- Automation trigger frequencies

Toggle: **default OFF, opt-in**. We assume a privacy-conscious user
declines this.

## Tier 3 — what specifically belongs here

Per-incident debug data. Operator opens a case, asks user to
temporarily enable detailed diagnostics for that case, data is
collected for a bounded time, then auto-disabled.

Examples:
- Full log archive ("zip the last 24h of all logs and send")
- HA Core debug logging at DEBUG level
- Configuration snapshot (sanitized — no passwords)
- Network traffic capture (pcap) — extremely rare, signed-off

Toggle: **per-incident, time-limited**. UI shows: "Operator XYZ
requests detailed diagnostics for issue #1234. Active until
2026-05-20 18:00 or until manually disabled."

## Implementation phases

### Phase A — Documentation + design (this doc) — DONE

- This file defines tier model + rules
- All later phases reference back to it

### Phase B — Tier 0 always-on path

**Goal**: get baseline data flowing regardless of consent state.

**Changes**:
1. New service `ga-telemetry-tier0.service` (or just bake into existing
   fleet-manager poll cycle — pull-based, already happening).
2. Define a **separate** fluent-bit instance OR a top-level Tier-0
   stream that ships:
   - kernel panic / OOM markers from journald
   - RAUC update events
   - failed-auth events from supervisor / fluent-bit's own metrics
3. Tier 0 data ships to a dedicated InfluxDB measurement (`ga_tier0`)
   and a dedicated Loki stream (`tier=0`).
4. No consent gate — `ConditionPathExists` removed for the Tier-0 service.
5. Document in privacy policy: "data we collect under Vertragserfüllung
   + berechtigtes Interesse with no separate consent."

**Touch points**:
- `buildroot-ihost/rootfs-overlay/etc/systemd/system/` — new service unit
- `buildroot-ihost/rootfs-overlay/usr/sbin/ga-telemetry-gate` — remove
  Tier 0 from consent check, or split into multiple gate scripts
- `buildroot-external/rootfs-overlay/etc/fluent-bit/` — Tier-0 config

**Effort**: ~3-4h

### Phase C — Tier 1 default ON

**Goal**: error_logs default ON; new onboarding defaults this way.

**Changes**:
1. `homeassisant_core/components/greenautarky_onboarding/consent_page.html`
   — switch "Fehlerberichte" toggle default to checked.
2. `ga-telemetry-gate` — if storage file missing OR error_logs key
   missing, default to true (current default-deny becomes default-allow
   for tier 1 only; tier 2 still default-deny).
3. Onboarding panel text explains: "Wir bitten dich, Fehlerberichte
   zugeschaltet zu lassen — sie helfen uns dein Gerät am Laufen zu
   halten. Du kannst sie jederzeit deaktivieren."

**Touch points**:
- `homeassisant_core/homeassistant/components/greenautarky_onboarding/consent_page.html`
- `homeassisant_core/homeassistant/components/greenautarky_telemetry/__init__.py`
  (defaults)
- `buildroot-ihost/rootfs-overlay/usr/sbin/ga-telemetry-gate`

**Effort**: ~1-2h

### Phase D — Right-to-export / right-to-delete API

**Goal**: DSGVO-conforming data subject rights.

**Changes**:
1. fleet-manager new endpoints:
   - `GET /api/devices/{id}/data-export` — returns a JSON dump of
     everything we have about this device (audit log entries, last
     poll snapshot, fleet-op participation history)
   - `DELETE /api/devices/{id}/data` — purges device data from
     fleet-manager's sqlite AND triggers Loki + InfluxDB deletion
     for tags matching device_id
2. Audit log entry for every export/delete (compliance trail)
3. Operator runbook (Phase G): how to handle a "I want my data" / "I
   want my data deleted" request from a customer

**Touch points**:
- `ga-fleet-manager/ga_fleet_manager/routes/data_subject.py` (new module)
- `ga-fleet-manager/ga_fleet_manager/data_export.py` (new module)
- `ga-fleet-manager/ga_fleet_manager/data_purge.py` (new module)
- InfluxDB + Loki retention APIs

**Effort**: ~3-4h

### Phase E — Versioned policy + per-consent timestamps

**Goal**: consent that survives policy changes (re-prompt when policy
version > accepted version).

**Changes**:
1. Privacy policy as a versioned doc in
   `homeassisant_core/components/greenautarky_onboarding/privacy_policy_v{N}.html`
2. Storage file `greenautarky_telemetry` adds a `policy_version`
   field per consent decision
3. At boot, `ga-telemetry-gate` compares the device's accepted
   policy_version to the latest available; if older, marks all
   consent fields as "stale → re-prompt"
4. Onboarding UI handles "stale consent" by re-showing the relevant
   page

**Touch points**:
- `homeassisant_core/homeassistant/components/greenautarky_telemetry/__init__.py`
  (storage schema)
- `homeassisant_core/homeassistant/components/greenautarky_onboarding/consent.py`
  (re-prompt logic)
- `buildroot-ihost/rootfs-overlay/usr/sbin/ga-telemetry-gate`
- New: privacy policy doc with version + change-log

**Effort**: ~2h

### Phase F — Consent UI redesign

**Goal**: the consent page actually explains what we collect, why,
and on what legal basis.

**Changes**:
1. `consent_page.html` redesign:
   - Per-tier section with title + legal basis text
   - Concrete examples per tier ("e.g., kernel panics, OS version")
   - Toggle with default per the tier model
   - Link to full versioned privacy policy
2. Tier 0 section shown as "We always collect:" — no toggle
3. Per-tier "Read more" expand-collapse for legal basis details

**Touch points**:
- `homeassisant_core/homeassistant/components/greenautarky_onboarding/consent_page.html`
- Translations (if applicable) for de/en

**Effort**: ~2h

### Phase G — Operator runbook

**Goal**: when a data subject request comes in, the operator has a
step-by-step procedure.

**Changes**:
1. New file `docs/privacy/RUNBOOK_DATA_SUBJECT_REQUESTS.md`:
   - "I want a copy of all my data" → procedure
   - "I want my data deleted" → procedure
   - "I want to revoke consent" → operator-side: edit toggle, reboot
   - "I want to see what you collect" → link to privacy policy
2. Time-bound: DSGVO Art. 12 requires response within one month
3. Audit log retention: how long do we keep evidence of consent
   decisions (recommendation: minimum 3 years post-revocation, for
   compliance defense)

**Effort**: ~1h

## Touch-point summary across repos

| Repo | Change |
|---|---|
| `homeassisant_core` | consent panel UI redesign, telemetry storage schema, defaults |
| `ha-operating-system` | telemetry-gate script split, fluent-bit Tier-0 config, RAUC event emission to Tier-0 |
| `ga_manager` (addon) | already done (0.9.3 JSON logging — works for Tier 1) |
| `ga-fleet-manager` | data-subject-rights endpoints, audit log retention |
| docs (multiple repos) | privacy policy doc + operator runbook |

## What's explicitly NOT in scope of this refactor

- ❌ DPO appointment (operator decision, separate)
- ❌ Auftragsverarbeitungsvertrag template (legal-team task, separate)
- ❌ External breach-notification automation (CRA topic, separate)
- ❌ HA Core "diagnostics" integration consent (upstream HA — out of scope)
- ❌ Adding new data we collect (this is restructuring of existing collection)

## Verification plan

After all phases:

1. **Tier 0**: provision a fresh device, decline ALL consents → Tier 0 data still arrives at ga-tools
2. **Tier 1**: provision a fresh device, accept all defaults → Tier 1 logs arrive; toggle off → logs stop within 1 boot cycle
3. **Data-export**: hit `GET /api/devices/{id}/data-export`, get JSON that contains everything we have on that device
4. **Data-delete**: hit `DELETE /api/devices/{id}/data`, verify InfluxDB measurement empties for that device_id + Loki query returns no results
5. **Policy version**: bump version, provision a device that previously accepted older version, verify re-prompt fires
6. **Audit**: all consent decisions + data subject requests have an
   audit log entry with operator, timestamp, action

## Open questions for review

1. **Tier 0 + Loki**: where exactly do we store Tier-0 logs? Same Loki
   instance with `tier=0` label? Or a separate hardened stream that
   cannot be filtered out by anyone? Recommendation: same Loki, label
   `tier`, with retention policy 365 days vs Tier 1 = 90 days.

2. **Pseudonymization**: do we hash device_ids for Tier 0 + 1 storage?
   Or accept that device_id alone is not personenbezogen unless
   joined? Recommendation: store as-is (operational utility), but
   document that no join with user identity happens in our backend.

3. **Tier 1 default ON — is this legally defensible?** The case I'd
   make: berechtigtes Interesse for operational error logging is
   well-established (compare to typical SaaS application logs).
   But this is the most legally-exposed part of the refactor. Want
   lawyer review specifically for this.

4. **Auto-update CRA event** — currently we don't have a separate
   "security update" channel. Should we split RAUC events into
   "security-relevant" (Tier 0) vs "feature update" (Tier 1)?
   Recommendation: all RAUC events Tier 0 for now (a feature update
   that fails IS a security concern because device stays vulnerable).

5. **Right to delete vs auditability** — if a user requests deletion,
   we must purge their data. But our audit log (proves we asked for
   consent + got it) should outlive deletion for compliance defense.
   How long? Suggestion: 3 years after deletion-request-date, only
   retain the proof-of-consent record (operator + timestamp + policy
   version), nothing else.

6. **Per-tier UI ordering**: in the onboarding panel, show Tiers in
   what order? My take: Tier 0 first as "this is what we always
   need", then Tier 1, then Tier 2. Tier 3 not shown in onboarding
   at all — appears only when an operator triggers it.

## Approve/modify before we cut code

Please review:
- The four-tier model — does Tier 0 contain what you'd expect?
- Defaults — is Tier 1 default ON OK with you (vs current default OFF)?
- Cross-repo scope — anything missing?
- The 6 open questions above — anything you have an opinion on?

After approval: I cut code in order Phase B → C → D → E → F → G.
Total 12-14h spread across however many sessions you want.
