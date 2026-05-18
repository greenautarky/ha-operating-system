# Runbook — Customer source-code requests (GPL § 3b / LGPL § 6)

**Status**: operator-facing SOP.
**Pairs with**: [`WRITTEN_OFFER.md`](WRITTEN_OFFER.md) (the public-facing offer text), [`docs/REPRODUCIBILITY.md`](../REPRODUCIBILITY.md) (the technical mechanism that makes any release reproducible).

This runbook covers how greenautarky support handles incoming requests
for the corresponding source code of GPL/LGPL components shipped in
GreenAutarky BOS. Adjacent to (but separate from) the DSGVO Art. 15
runbook in `ga-fleet-manager/docs/RUNBOOK_DATA_SUBJECT_REQUESTS.md`.

## 0. TL;DR — the 5-minute path

A customer's device runs GAOS `v1.2.0` and they want the source.

```bash
# 1. Identify the exact release version (from device or customer email)
VER=v1.2.0

# 2. Grab the release archive (which carries source-pins.json + lockfiles)
RELEASE_URL="https://github.com/greenautarky/ha-operating-system/releases/download/${VER}/ga-os-${VER}-source-bundle.tar.gz"

# 3. If the bundle isn't published yet, rebuild from the release tag
#    using docs/REPRODUCIBILITY.md, then upload as a release asset.

# 4. Send the customer a download link + checksum.
```

Then: log the request in the case system and confirm fulfillment.
Retention obligation is **3 years from the date the device was last
shipped**, GPL-2.0 § 3b.

## 1. When a request arrives

Triggers:
- Customer emails / writes asking for source code of "the Linux on my
  device", "ha-operating-system", "the kernel", or any specific
  component.
- Competitor / researcher / journalist asks the same.
- Internal: legal asks us to verify we can satisfy a hypothetical
  request before broader rollout.

First-line handling:

1. **Open a case** in the support system. Case-id format:
   `GA-OSS-<incrementing-number>` (e.g. `GA-OSS-001`).
2. **Classify the scope** of the request:
   - *"Everything you ship"* → full release source bundle.
   - *"Just the kernel"* / *"Just the Supervisor"* → component bundle.
   - *"The patches you made on top of upstream"* → modified-source
     subset (lighter to produce — these all live in
     `buildroot-external/board/sonoff/ihost/patches/` and
     `homeassisant_core` / `ha-supervisor` ga-prefixed branches).
3. **No identity verification required** — GPL § 3b doesn't condition
   the offer on having proven device ownership. Anyone may request.
   *But*: log who asked + what was requested in the case.
4. **Note the deadline**. We commit to a 30-day delivery window
   (matches the DSGVO runbook cadence and is well within GPL norms).

## 2. Identify the release version

If the customer can read it off their device:

```bash
ssh -p 22222 root@<device> 'cat /etc/os-release'
# Look for GA_BUILD_ID — that's the release tag they're running.
```

If they can't:
- Ask which iHost generation (KIB-SON-0 / pilot batch / production
  batch) — release versions per generation are tracked in
  [`docs/RELEASE-WORKFLOW.md`](../RELEASE-WORKFLOW.md) and
  `ga-ihost-docs/RELEASES-REPO.md`.
- Worst case: produce the most recent release bundle and offer it as
  the "current shipping version" — under § 3b we may provide source
  for *any* version we've distributed within 3 years.

## 3. Produce the source bundle

### Path A — bundle already published as a release asset

Check `https://github.com/greenautarky/ha-operating-system/releases`
for the tag. If `ga-os-${VER}-source-bundle.tar.gz` exists, use it.

### Path B — generate from the release tag

```bash
git clone https://github.com/greenautarky/ha-operating-system /tmp/ga-os-src
cd /tmp/ga-os-src
git checkout ${VER}
./scripts/ga_build.sh prod        # Produces ga_output/images/configs/
# Bundle the configs + buildroot legal-info + the source-pins
./scripts/bundle-source.sh ${VER} > /tmp/ga-os-${VER}-source-bundle.tar.gz
# (see TODO at the bottom — scripts/bundle-source.sh not yet written)
```

What goes in the bundle (the four required pieces under § 3b):

1. **All sources of GPL/LGPL components**:
   - Linux kernel tarball + our patches (`buildroot-external/board/*/patches/linux/`)
   - Buildroot tree + our customizations (`buildroot-external/`, `buildroot-ihost/`)
   - U-Boot tarball + our patches (`buildroot-external/board/*/patches/uboot/`)
   - Modified HA Supervisor branch (cherry-picks listed in our `ga/*` branches at `greenautarky/ha-supervisor`)
2. **The complete corresponding scripts to control compilation and
   installation** of the executable — covered by `buildroot.config`,
   `kernel.config`, `defconfig`, and the build scripts in `scripts/`.
3. **A copy of the licenses** — Buildroot's `legal-info/` directory
   already contains every package's license text. Generated automatically
   for prod builds; verify it's present in the bundle.
4. **A pointer to where customers can get more info** — README inside
   the bundle linking to the public repo + this runbook + the
   written-offer.

### Path C — for a Supervisor / Core / Frontend only request

These live in separate repos with their own release tags:
- `greenautarky/ha-supervisor` (branch `ga/custom-onboarding`)
- `greenautarky/ha-core` (branch `ga/custom-onboarding`)
- `greenautarky/frontend` (branch `ga/custom-onboarding`)

Bundle the specific repo at the SHA referenced by the GAOS release's
`source-pins.json`. No need to ship the kernel / Buildroot for these
narrower requests.

## 4. Deliver to customer

Same delivery rules as the DSR runbook:
- **Preferred**: upload to an encrypted file-share (Nextcloud share
  with expiring password). Email the share link + password via two
  separate channels. Include the SHA-256 checksum.
- **Public release asset**: if the bundle is small enough and contains
  no customer-specific info (it shouldn't), publish it as a GitHub
  release asset under the same tag and just send the URL.
- **Never**: send unencrypted via standard email for large bundles —
  not because the content is sensitive but because attachments
  > 25 MB often bounce silently.

Reply template:

> Sehr geehrte/r [Kundenname],
>
> anbei der vollständige Quellcode für die GreenAutarky-OS-Version
> `[VERSION]`, die auf Ihrem Gerät läuft, gemäß GPL-2.0 § 3b.
>
> Das Archiv enthält:
> - Linux-Kernel-Quellcode und unsere Patches
> - Buildroot-Konfiguration und unsere Anpassungen
> - U-Boot-Bootloader-Quellcode
> - Lizenztexte aller enthaltenen Pakete (`legal-info/`)
> - Buildanweisungen und Konfigurationsdateien
>
> Download: `[encrypted-share-link]`
> SHA-256: `[checksum]`
>
> Der öffentliche Quell-Repository-Mirror ist unter
> https://github.com/greenautarky/ha-operating-system einsehbar; das
> exakte Release-Tag ist `[VERSION]`.
>
> Bei Fragen zum Build-Prozess verweisen wir auf die Anleitung in
> `docs/REPRODUCIBILITY.md` im obigen Repository.
>
> Aktenzeichen: [CASE_ID]
>
> Mit freundlichen Grüßen,
> greenautarky Support

## 5. Quick reference

```text
┌────────────────────────────────────────────────────────────────────┐
│  Source-request runbook quick card                                 │
├────────────────────────────────────────────────────────────────────┤
│  Legal basis        : GPL-2.0 § 3b, LGPL § 6, Apache-2.0 NOTICE    │
│  Response deadline  : 30 days (self-imposed; GPL has no statutory  │
│                       deadline but "reasonable" is the standard)   │
│  Retention duration : 3 years from last device shipment             │
│  Case-id format     : GA-OSS-NNN                                    │
│  Identity check     : NOT required (GPL § 3b is unconditional)      │
│  Charge             : "Reasonable cost of physically performing     │
│                       distribution" — for download links, that's    │
│                       zero. Never charge if delivering electronic. │
├────────────────────────────────────────────────────────────────────┤
│  Source bundle path: ga-os-{VERSION}-source-bundle.tar.gz          │
│  Public mirror     : github.com/greenautarky/ha-operating-system   │
│  Per-release tag   : v1.x.y                                        │
└────────────────────────────────────────────────────────────────────┘
```

## 6. Edge cases

### Customer wants Supervisor or Core only
See Path C above. Lighter bundle, but the legal-info index is
specific to GAOS — also include the upstream HA Core / Supervisor
license headers (already present in those repos' own `LICENSE.md`).

### Customer claims derivative-work obligations
E.g. "you must publish my modifications I made on top of GAOS".
- We are NOT obligated to publish *their* modifications.
- If they ask us to *host* their modifications: politely decline,
  point them at GitHub forks.
- If they assert their modifications create derivative-work
  obligations on *us*: escalate to legal.

### Multiple device generations
A customer has one KIB-SON-0 (running v1.1) and one pilot device
(running v1.2). Two separate bundles, one per release tag. Reference
both case_id and version_tag in the reply.

### "I want the source of the addons too"
Addons (e.g. `ga_hmvapp_addon`, `ga_default_addon`) are separate
repos under proprietary licensing — **not** GPL-covered. Politely
decline; clarify the distinction: GAOS itself is GPL-derived;
add-ons are MIT/proprietary depending on slug. Document the
distinction in the customer reply if helpful.

### The request is older than 3 years
Past the § 3b retention window. We may still help if we can produce
the bundle, but we have no obligation. Document the decision.

### The request comes from a competitor
Treat identically to any other request. GPL § 3b doesn't condition
the offer on the requester's identity or intent. Internally flag
the case so legal is aware, but **don't** delay or refuse — that's
where companies historically get into trouble.

## 7. Audit / supervisor view

Quarterly check the support system for all `GA-OSS-*` cases. Acceptance
bar:
- Every case has the release version + bundle SHA-256 documented.
- Every fulfilled case has a delivery confirmation email logged.
- Bundle archives still exist (GitHub releases retention or our own
  long-term archive).

## 8. Open follow-ups

These items are tracked in the OSS-compliance TODO
(`memory/todo_oss_compliance_2026_05_11.md`) and need landing before
broader rollout:

- [ ] **`scripts/bundle-source.sh`** — automate the Path B bundle
      assembly. Reads `source-pins.json`, fetches the pinned source
      tarballs + applies our patches, packs the result. Manual
      assembly works today but is error-prone.
- [ ] **CI hook** to auto-publish the source bundle as a release
      asset on every `v1.x.y` tag push — so Path A is the default
      and we never need to rebuild Path B reactively.
- [ ] **Public mirror page** at `greenautarky.com/sources/<v>/` so
      customers can self-serve without contacting support. Out of
      scope for this runbook; tracked separately.
- [ ] **Bake the written offer** ([`WRITTEN_OFFER.md`](WRITTEN_OFFER.md))
      into the shipped image as `/usr/share/doc/greenautarky/SOURCE_OFFER.md`
      and link it from the About page in the HA Core UI.
