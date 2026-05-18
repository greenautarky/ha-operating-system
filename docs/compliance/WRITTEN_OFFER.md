# Written offer — Corresponding source code

This file holds the canonical "written offer" text required under GPL-2.0
§ 3b for the GPL/LGPL components shipped in GreenAutarky BOS. It must be:

1. Shipped inside the OS image at `/usr/share/doc/greenautarky/SOURCE_OFFER.md`
2. Linked from the device's About page in the HA Core UI
3. Published on `greenautarky.com/legal/source-offer/`
4. Provided on physical media (printed insert) for any boxed product

The exact wording below is the legally-binding offer — only update with
legal review and bump the version footer when you do.

## Operator-facing version (the file we ship)

> **Corresponding Source Code — Written Offer**
>
> This product, GreenAutarky BOS, contains software components licensed
> under the GNU General Public License (GPL) version 2 and other
> free / open-source software licenses. Per § 3b of the GPL-2.0, we
> hereby offer to provide, for a period of three (3) years following
> the date of distribution of this product, a complete machine-readable
> copy of the corresponding source code for all such components, in the
> exact version that was distributed with your device.
>
> The source code is available in two ways:
>
> 1. **Online (preferred)**: visit
>    `https://github.com/greenautarky/ha-operating-system` and check out
>    the git tag matching the version printed at the top of your
>    device's About page (e.g. `v1.2.0`). All build configuration,
>    kernel patches, and modified component sources are present in
>    that repository. Reproduction instructions:
>    `docs/REPRODUCIBILITY.md`.
>
> 2. **By request**: send an email to `source-requests@greenautarky.com`
>    quoting the version printed on your About page and a postal or
>    email address where we can send a download link. We will respond
>    within 30 days with either a download URL (no cost) or, if you
>    explicitly request physical media, an invoice for our reasonable
>    cost of materials and shipping.
>
> The corresponding source code includes:
> - The Linux kernel and any modifications we have made
> - The U-Boot bootloader and any modifications
> - All other GPL-licensed components packaged in the Buildroot tree
> - The complete scripts used to control compilation and installation
> - A copy of the applicable license texts (`legal-info/`)
>
> This offer is valid for anyone in receipt of this product, regardless
> of whether they purchased it directly from greenautarky GmbH.
>
> Components licensed under Apache-2.0, MIT, BSD, or other permissive
> licenses are covered by the license notices preserved in
> `legal-info/` and in the project repositories. Greenautarky's own
> additions are licensed under the Apache License version 2.0; see the
> `LICENSE` file in the repository.
>
> Issued: 2026-05-15
> Document version: 1
> Contact: source-requests@greenautarky.com

## Customer-facing summary (the version shown in the HA Core About page)

A shorter rendering, intended for in-UI display. Links to the full
offer for the legally complete text.

> **Open source software**
>
> GreenAutarky BOS is built on Home Assistant OS, the Linux kernel, and
> hundreds of other open-source components. You have the right to
> request the complete corresponding source code under their
> respective licenses (GPL, LGPL, Apache, MIT, BSD).
>
> - **Browse online**: [github.com/greenautarky/ha-operating-system](https://github.com/greenautarky/ha-operating-system)
> - **Request by email**: source-requests@greenautarky.com
> - **Full written offer**: [greenautarky.com/legal/source-offer](https://greenautarky.com/legal/source-offer)
>
> *Your right to request source persists for 3 years after the device
> was distributed.*

## Operational notes (for engineers, not customers)

- The `source-requests@greenautarky.com` address must route to a
  monitored inbox. Currently maps to support; consider a dedicated
  alias once volume grows.
- The 30-day response commitment is self-imposed. GPL has no statutory
  deadline; "reasonable" is the standard. 30 days matches our DSGVO
  Art. 12 (3) commitment so support staff have one consistent cadence.
- If we ever modify the offer text (e.g. new contact address, new
  delivery mechanism), bump the "Document version" footer. Devices
  shipped under the old version remain entitled to source under that
  version's terms — keep an archive of historical offer versions.
- "Reasonable cost" for physical media is documented in the runbook
  but: in practice we expect zero physical-media requests. If we get
  one, charging ~25 EUR (media + shipping) is well within "reasonable"
  for a USB stick + EU postage.
