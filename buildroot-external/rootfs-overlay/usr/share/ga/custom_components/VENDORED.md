# Vendored custom_components

GA Home Assistant custom_components shipped in the V1.2-clean OS image
and laid out by `scripts/sync-components.sh` at OS build time, then
copied at first boot to `/config/custom_components/` by `ga_manager`'s
converge worker.

Both pinned components are now **Tier-2 OCI artifacts** — they live in
their own GitHub repos and publish a `.tar.gz` artifact to GHCR on
every tag. The trees themselves are **not** committed to this directory
(gitignored); the OS build pulls them via `oras` based on the pin in
`version.yaml` at the repo root.

## Pins

| Component | Source repo | Pin location | Pulled from |
|---|---|---|---|
| `greenautarky_site` | [greenautarky/greenautarky-onboarding](https://github.com/greenautarky/greenautarky-onboarding) (source repo not yet renamed) | `version.yaml` → `components.greenautarky-site` | `ghcr.io/greenautarky/greenautarky-site:<ver>` |
| `ga_frontend_bundle` | [greenautarky/ga-frontend-bundle](https://github.com/greenautarky/ga-frontend-bundle) | `version.yaml` → `components.ga-frontend-bundle` | `ghcr.io/greenautarky/ga-frontend-bundle:<ver>` |

`ga_frontend_bundle` is stateless (no `config_flow`, no `Store`): converge places
it like onboarding, and activates it via the `configuration.yaml` enable-list
(`ga_frontend_bundle:`). Its source-of-truth repo vendors the card JS itself via
`scripts/vendor.py` — refresh there, not by editing files here.

## Refreshing

1. Cut a release in the component repo (= tag `vX.Y.Z`; CI publishes
   the OCI artifact + GitHub Release).
2. Bump the pin in this repo's `version.yaml`.
3. Run `./scripts/sync-components.sh` (or wait for the next build —
   it runs as a pre-build step).
4. Commit the `version.yaml` change. The component dir itself stays
   gitignored.

See `ga-ihost-docs/TIER-2-COMPONENTS.md` for the full architecture
rationale and the migration roadmap for the remaining baked components.
