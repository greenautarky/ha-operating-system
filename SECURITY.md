# Security Policy

## Supported Versions

Security fixes are provided for **the current final release and the one before
it**. In addition, every final release keeps security support for **at least
12 months from its first shipment**, even if two newer releases appear within
that time.

| Version | Supported |
|---------|-----------|
| Current final release | Yes |
| Previous final release | Yes |
| Older final release, less than 12 months after its first shipment | Yes |
| Older final release, 12 months or more after its first shipment | No — update to a supported release |
| Release candidates and development builds | No — superseded by the next build |

## Reporting a Vulnerability

If you discover a security vulnerability in GA OS or any of its components,
please report it responsibly:

1. **Email:** security@greenautarky.com
2. **Subject:** `[CVE] <component> — <short description>`
3. **Include:** affected component, version, steps to reproduce, potential impact

We aim to acknowledge reports within **24 hours** and provide a fix timeline
within **5 business days**.

**Please do not** open a public GitHub issue for security vulnerabilities.

## Scope

This policy covers:

- GA OS (this repository) — kernel, rootfs, system services
- Container images hosted at `ghcr.io/greenautarky/`
- Custom HA Core, Supervisor, and addon builds
- Build infrastructure and CI pipelines

## Regulatory reporting

From 11 September 2026 we are subject to the reporting obligations of the EU
Cyber Resilience Act (Regulation (EU) 2024/2847, Article 14). Where a report
concerns a vulnerability that is being actively exploited, or a severe incident
affecting the security of one of our products, we notify our designated national
CSIRT — CERT-Bund — and ENISA within the deadlines the regulation sets.

Reporting to us therefore also reaches the authorities through us. It does not
replace any report you may wish to make yourself.

## CVE Handling

See [CVE-HANDLING.md](docs/CVE-HANDLING.md) for our vulnerability assessment
and response process, including severity thresholds and response timelines.

## Security Measures

- Read-only root filesystem (erofs)
- Disk guard with emergency cleanup
- Encrypted remote access (NetBird/Tailscale VPN)
- No default passwords on production builds
- CycloneDX SBOM and CVE scan over release artifacts — the scan fails closed
  when it covers nothing, so an empty report cannot pass as a clean one
- Container image verification before build
- Version chain integrity checks
