# Canary verification — privacy refactor

Step-by-step checklist for verifying the Phase B–G privacy work on
KIB-SON-0 before broader rollout. Pairs with:

- `ga-ihost-docs/PRIVACY_TIERS.md` (canonical model)
- `ga-ihost-docs/PRIVACY_IMPLEMENTATION_ROADMAP.md` (phase definitions)
- `docs/privacy/OS_LAYER.md` (OS-level spec)
- `ga-fleet-manager/docs/RUNBOOK_DATA_SUBJECT_REQUESTS.md` (operator SOP)

## Prerequisites

- [ ] **PRs merged**:
  - [ ] `ha-core#11` (`ga/docs-privacy-tier-notes`) — backend v2 storage + WS + Phase E stale flag
  - [ ] `frontend#1` (`ga/privacy-tier-c2`) — Phase C-2 defaults + Phase E banner + Phase F UI redesign
  - [ ] `ga-fleet-manager#1` (`ga/phase-d-dsr-api`) — Phase D DSR API + Phase G runbook
- [ ] **Lawyer sign-off** on Tier 1 default-ON posture under Art. 6 (f) berechtigtes Interesse.
- [ ] **OS image rebuild** with the new HA Core tag (Core `2025.11.3.3`+).
- [ ] **fleet-manager redeployed** as 0.5.0 on ga-tools.
- [ ] **ssh access** to KIB-SON-0 via Tailscale + key from `~/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem`.

## Phase B — Tier 0 always-on path

```bash
ssh -p 22222 root@<KIB-SON-0-ip> '
  systemctl is-active fluent-bit-tier0       # → active
  systemctl is-active fluent-bit-tier1       # → depends on consent
  systemctl is-active telegraf               # → depends on consent
  cat /etc/ga-policy-version                 # → 1 (or current)
  ls /mnt/data/.ga-consent-*                 # → tier1+tier2 + legacy aliases
'
```

- [ ] `fluent-bit-tier0` is active regardless of `.ga-consent-*` state.
- [ ] On ga-tools / Loki: `{tier="0",host="KIB-SON-00000000"}` returns recent events.
- [ ] Forcing a synthetic kernel event (e.g. `dmesg -k -c -t … via journalctl`) shows up in the Tier 0 Loki stream within 60s.

## Phase C — backend + frontend tier model

```bash
# 1. Inspect the storage file on the device
ssh -p 22222 root@<KIB-SON-0-ip> \
  'cat /mnt/data/supervisor/homeassistant/.storage/greenautarky_telemetry | jq .'
```

- [ ] `version` is `2`, `data.tiers.tier1.value` and `data.tiers.tier2.value` present.
- [ ] `data.policy_version_accepted` is `1` (or the current OS-baked policy version).
- [ ] `data.legacy.error_logs` and `data.legacy.metrics` mirror the canonical values.

```bash
# 2. WS API check via the Home Assistant Lovelace developer-tools console
#    (or a one-off websocat call with a long-lived access token).
{"id":1,"type":"greenautarky_telemetry/get"}
```

- [ ] Response includes both `tier1`/`tier2` (canonical) **and** `error_logs`/`metrics` (legacy).
- [ ] Response includes `policy_version_accepted`, `current_policy_version`, `consent_is_stale`.

```bash
# 3. Frontend onboarding panel
#    Reset the consent file, reboot, open https://<device>:8123/onboarding.html
```

- [ ] Three tier sections visible (Tier 0 info-only with "immer aktiv" badge).
- [ ] Each section has a "Mehr erfahren" disclosure with examples + retention period.
- [ ] Tier 1 switch defaults ON, label "Fehlerberichte (empfohlen)".
- [ ] Tier 2 switch defaults OFF, label "Detaillierte Leistungsdaten".
- [ ] Footer link to `greenautarky.com/datenschutz` works.

## Phase D — DSR API end-to-end

From a workstation with operator credentials:

```bash
export FM_TOKEN=$(cat ~/.config/greenautarky/fleet-manager.token)
export FM_HOST=https://fleet-manager.greenautarky.com
export DEVICE=KIB-SON-00000000

# Export
curl -fsSL -H "Authorization: Bearer $FM_TOKEN" \
  "$FM_HOST/api/devices/$DEVICE/data-export" \
  -o "verify-export-$DEVICE.json"
```

- [ ] Response has `Content-Type: application/json; charset=utf-8` + `Content-Disposition: attachment; filename=...`.
- [ ] Archive contains `fleet-manager.ops_audit` source with rows for any prior operator action against this device.
- [ ] `influxdb.*` sources are populated (NOT `{skipped: true}`) — if skipped, the fleet-manager env vars are missing in prod; fix before continuing.
- [ ] `loki.*` sources populated similarly.

```bash
# Verify the export was audit-recorded
curl -fsSL -H "Authorization: Bearer $FM_TOKEN" \
  "$FM_HOST/api/audit/data-subject-actions?device_id=$DEVICE" | jq '.actions[0]'
```

- [ ] Newest action has `action=export`, current ISO timestamp.

**Delete path** — only run if a throwaway device is available; the
operation is irreversible. Defer to first real DSR request otherwise.

## Phase E — stale-consent re-prompt

```bash
# Simulate a policy bump by editing the storage file:
ssh -p 22222 root@<KIB-SON-0-ip> '
  STORE=/mnt/data/supervisor/homeassistant/.storage/greenautarky_telemetry
  jq ".data.policy_version_accepted = 0
    | .data.tiers.tier1.policy_version = 0
    | .data.tiers.tier2.policy_version = 0" $STORE > $STORE.tmp
  mv $STORE.tmp $STORE
  ga-telemetry-gate version
'
```

- [ ] `ga-telemetry-gate version` reports `baked > accepted`.
- [ ] `ga-telemetry-gate write` removes existing markers ("policy stale → withholding consent").
- [ ] HA Core WS `greenautarky_telemetry/get` returns `consent_is_stale: true`.
- [ ] Reloading the onboarding analytics panel shows the "Datenschutz-Hinweis aktualisiert" banner above the tier sections.
- [ ] Clicking "Finish" with toggles unchanged clears `consent_is_stale` and stamps `policy_version_accepted` to the current value.
- [ ] **Cleanup**: restore the storage file from a pre-test backup so the canary returns to baseline.

## Phase F — UI redesign visual check

Take screenshots and compare against `docs/privacy/screenshots/` (TBD):
- [ ] `analytics-fresh.png` — fresh-device view with both toggles defaulted.
- [ ] `analytics-stale.png` — the stale banner above the tier sections.
- [ ] `analytics-tier0-expanded.png` — Tier 0 "Mehr erfahren" open.

(Add the screenshots to the privacy folder for future regression
comparison; not blocking on the canary itself.)

## Phase G — runbook dry-run

- [ ] Walk the runbook with a fictional case `GA-DSR-000` against the canary device.
- [ ] Time the export+reply flow end-to-end. Target: under 10 minutes.
- [ ] Confirm the dsr_audit row shows the correct `case GA-DSR-000` reason.
- [ ] Refile any clunky steps as runbook v0.2 issues — adjust before the SOP goes to support staff training.

## Sign-off

| Phase | Verified by | Date | Notes |
|---|---|---|---|
| B (Tier 0 always-on) |  |  |  |
| C (tier model live) |  |  |  |
| D (DSR API works) |  |  |  |
| E (stale re-prompt) |  |  |  |
| F (UI redesign) |  |  |  |
| G (runbook trial) |  |  |  |

Once all six rows are signed, promote the OS image to `v1.3` (or
whichever release version carries this work) and start the broader
rollout to the rest of the fleet.

## Rollback plan

If a regression is found on KIB-SON-0:

1. **OS layer**: re-flash with the previous good image (v1.2 or last
   known good v1.3-rc). The OS overlay carries `/etc/ga-policy-version`
   and the new gate-script — both revert with the image swap.
2. **HA Core**: revert to the pinned Core Docker tag from the
   previous release. The v1→v2 migration is one-way, but the v1
   storage file is preserved on disk under the original key
   (rollback restores from the storage backup taken in Phase E above).
3. **fleet-manager**: pin to the previous image tag on ga-tools and
   restart the container — the dsr_audit table coexists with
   ops_audit so older fleet-manager versions ignore it.
4. **Frontend**: served from the HA Core image — reverting Core also
   reverts the frontend.

Document the failure mode in this file before re-attempting rollout.
