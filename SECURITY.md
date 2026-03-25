# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest build (master) | Yes |
| Older builds | Best effort |

## Reporting a Vulnerability

If you discover a security vulnerability in GA OS or any of its components,
please report it responsibly:

1. **Email:** security@greenautarky.com
2. **Subject:** `[CVE] <component> — <short description>`
3. **Include:** affected component, version, steps to reproduce, potential impact

We aim to acknowledge reports within **48 hours** and provide a fix timeline
within **5 business days**.

**Please do not** open a public GitHub issue for security vulnerabilities.

## Scope

This policy covers:

- GA OS (this repository) — kernel, rootfs, system services
- Container images hosted at `ghcr.io/greenautarky/`
- Custom HA Core, Supervisor, and addon builds
- Build infrastructure and CI pipelines

## CVE Handling

See [CVE-HANDLING.md](docs/CVE-HANDLING.md) for our vulnerability assessment
and response process, including severity thresholds and response timelines.

## Security Measures

- Read-only root filesystem (erofs)
- Disk guard with emergency cleanup
- Encrypted remote access (NetBird/Tailscale VPN)
- No default passwords on production builds
- Automated SBOM generation (CycloneDX) on production builds
- Container image verification before build
- Version chain integrity checks
