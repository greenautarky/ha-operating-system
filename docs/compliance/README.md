# Compliance docs

Operator-facing documents covering legal obligations that come with
distributing GreenAutarky BOS to customers. Each doc is a self-contained
runbook or canonical reference; cross-links flagged inline.

| Doc | Purpose | Trigger |
|---|---|---|
| [`RUNBOOK_SOURCE_REQUEST.md`](RUNBOOK_SOURCE_REQUEST.md) | Step-by-step SOP for handling GPL § 3b source-code requests | Customer / researcher asks for source |
| [`WRITTEN_OFFER.md`](WRITTEN_OFFER.md) | Canonical text of the GPL § 3b written offer (ships in image + on website + on About page) | Every release — text only changes with legal review |

Adjacent docs (not in this folder):

- [`../REPRODUCIBILITY.md`](../REPRODUCIBILITY.md) — technical mechanism
  behind the source-request runbook: every release captures
  `source-pins.json` + lockfiles so any tag is reproducible.
- [`../../ga-fleet-manager/docs/RUNBOOK_DATA_SUBJECT_REQUESTS.md`](../../ga-fleet-manager/docs/RUNBOOK_DATA_SUBJECT_REQUESTS.md) —
  the sibling runbook for DSGVO Art. 15 / 17 requests. Same shape, same
  audience (support staff), different legal basis.
- [`../privacy/PRIVACY_TIERS_PLAN.md`](../privacy/PRIVACY_TIERS_PLAN.md) — the
  4-tier privacy model that underpins what data we hold per device.

## What's in flight

The eight-track OSS compliance audit (memory note
`todo_oss_compliance_2026_05_11.md`):

| Track | Status |
|---|---|
| 1. License inventory / SBOM publication (CRA-ready by 2027) | partial — `legal-info/` generated; no public bundle yet |
| 2. GPL "written offer" for corresponding source | ✅ `WRITTEN_OFFER.md` text done; not yet baked into image / website |
| 3. Modified-source disclosure (kernel patches + Supervisor mods) | covered by public repo + `source-pins.json` |
| 4. Trademark / brand compliance (HA attribution) | partial — `os-release` says "based on Home Assistant" |
| 5. Apache-2.0 NOTICE files preserved through Buildroot | TODO — verify Buildroot keeps NOTICE files |
| 6. Pick + apply a clear license for our own additions | ✅ Apache-2.0 on ha-operating-system; MIT on satellite repos |
| 7. Customer-side experience: runbook for source-request handling | ✅ `RUNBOOK_SOURCE_REQUEST.md` |
| 8. CRA preparedness: SBOM publication + SECURITY.md + CVE process | partial — `SECURITY.md` exists in all repos; CVE scan workflow runs |

Tracks 1, 4, 5, 8 (the technical / build-time ones) are the next
chunk of work. Tracks 2 and 7 — the operator-facing ones — landed
2026-05-17 alongside this README.
