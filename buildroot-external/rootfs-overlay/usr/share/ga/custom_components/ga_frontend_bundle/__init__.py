"""GA frontend card bundle — the de-HACS Lovelace card set.

A stateless integration that replaces HACS for delivering GreenAutarky's curated
Lovelace cards. On setup it:

1. serves the vendored card ``.js`` files as a static directory, and
2. injects each as a frontend JS module via ``add_extra_js_url`` so the
   ``custom:*`` elements (``custom:button-card``, ``custom:mushroom-*`` …)
   resolve on every dashboard.

No GitHub access, no HACS, no per-device Lovelace-resource registration. The
cards are pinned in ``bundle.lock.yaml`` and vendored at build time
(``scripts/vendor.py``).

No ``config_flow`` and no HA ``Store`` — the integration holds no persistent
state. It is activated by ``ga_frontend_bundle:`` in ``configuration.yaml``,
which converge maintains via its enable-list. See
``ga-ihost-docs/VENDORED-INTEGRATION-DELIVERY.md`` and ``docs/CONVERGE-HANDOFF.md``.
"""

from __future__ import annotations

import logging
from pathlib import Path

from homeassistant.components.frontend import add_extra_js_url
from homeassistant.components.http import StaticPathConfig
from homeassistant.core import HomeAssistant
from homeassistant.helpers.typing import ConfigType

from .bundle import card_url, load_cards
from .const import COMMUNITY_DIRNAME, DOMAIN, STATIC_URL_BASE

_LOGGER = logging.getLogger(__name__)


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Set up the GA frontend bundle (yaml-activated, idempotent)."""
    if DOMAIN in hass.data:
        return True
    hass.data[DOMAIN] = {}

    community_dir = Path(__file__).parent / COMMUNITY_DIRNAME
    # iterdir()/glob()/is_file() are blocking — run the scan in the executor.
    cards = await hass.async_add_executor_job(load_cards, community_dir)
    if not cards:
        _LOGGER.error(
            "%s: no vendored cards under %s — bundle is empty. Did "
            "scripts/vendor.py run before packaging? Not blocking HA start.",
            DOMAIN,
            community_dir,
        )
        return True

    await hass.http.async_register_static_paths(
        [StaticPathConfig(STATIC_URL_BASE, str(community_dir), True)]
    )

    injected = 0
    for card in cards:
        try:
            add_extra_js_url(hass, card_url(STATIC_URL_BASE, card))
        except KeyError:
            # add_extra_js_url indexes hass.data["frontend_extra_module_url"],
            # which only exists once `frontend` has set up. We declare frontend
            # as a dependency so this should not happen on a real device; stay
            # defensive for minimal/test setups.
            _LOGGER.warning(
                "%s: frontend not ready — card %s not injected", DOMAIN, card["id"]
            )
            continue
        injected += 1

    hass.data[DOMAIN] = {"cards": cards, "injected": injected}
    _LOGGER.info(
        "%s: serving %d cards at %s, injected %d frontend modules",
        DOMAIN,
        len(cards),
        STATIC_URL_BASE,
        injected,
    )
    return True
