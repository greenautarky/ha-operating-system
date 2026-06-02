# Vendored custom_components

GA Home Assistant custom_components shipped in the V1.2-clean OS image and
staged to `/share/ga-custom-components/` on every boot by `ga-bootstrap`.
`ga_manager`'s `converge` worker copies them from there into
`/config/custom_components/` and owns their drift afterwards.

They ship in the **OS image** (GreenAutarky's own trusted build) — *not* in
the `ga_manager` addon image — so the addon image carries no private-repo
content and needs no build-time credential.

## Pins

| Component | Source repo | Ref | Commit |
|---|---|---|---|
| `greenautarky_onboarding` | `greenautarky/ha-greenautarky-onboarding` (private) | `v0.2.3` | `9cb87790d9c46318c08cb30e0ba68fc05e696420` |
| `ga_frontend_bundle` | `greenautarky/ga-frontend-bundle` (private) | `v1.0.0` | `bf4759fa355330856301f0724820ec6f584b7d2a` |

`ga_frontend_bundle` is stateless (no `config_flow`, no `Store`): converge places
it like onboarding, and activates it via the `configuration.yaml` enable-list
(`ga_frontend_bundle:`). Its source-of-truth repo vendors the card JS itself via
`scripts/vendor.py` (refresh there, not by cloning); see
`ga-frontend-bundle/docs/CONVERGE-HANDOFF.md`.

## Refreshing

To ship a newer component version:

```sh
git clone --depth 1 --branch <tag> \
    https://github.com/greenautarky/ha-greenautarky-onboarding.git /tmp/o
rm -rf greenautarky_onboarding
cp -r /tmp/o/custom_components/greenautarky_onboarding .
```

Then update the pin row above. The component's source-of-truth stays the
`ha-greenautarky-onboarding` repo; this is a vendored copy at a fixed ref.
