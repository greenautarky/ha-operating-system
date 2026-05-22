"""HTTP views for greenautarky onboarding.

Onboarding views are unauthenticated (like stock HA onboarding) but gated by
the completion state — once onboarding is done, the endpoints return 403.

Consent views are authenticated and available after onboarding is complete.
"""

from __future__ import annotations

import base64
from datetime import UTC, datetime, timedelta
import hmac
import json
import logging
from pathlib import Path
import subprocess
from typing import Any
from urllib.parse import urlencode

from aiohttp import web

from homeassistant.auth.const import GROUP_ID_USER
from homeassistant.auth.providers.homeassistant import HassAuthProvider, InvalidUser
from homeassistant.components import frontend
from homeassistant.components.http import HomeAssistantView
from homeassistant.core import HomeAssistant
from homeassistant.helpers.storage import Store

from .consent import async_record_consent, get_outdated_consents
from .const import DOMAIN, PIN_FILE, PIN_MAX_DELAY

_LOGGER = logging.getLogger(__name__)


def _async_get_hass_provider(hass: HomeAssistant) -> HassAuthProvider:
    """Get the Home Assistant auth provider."""
    for prv in hass.auth.auth_providers:
        if prv.type == "homeassistant":
            return prv
    raise RuntimeError("Home Assistant auth provider not found")


# Load HTML templates once at import time
_CONSENT_HTML = (Path(__file__).parent / "consent_page.html").read_text(
    encoding="utf-8"
)
_PW_RESET_HTML = (Path(__file__).parent / "password_reset_page.html").read_text(
    encoding="utf-8"
)


def _get_store(hass: HomeAssistant) -> Store[dict[str, Any]]:
    """Get the storage store."""
    return hass.data[DOMAIN]["store"]


def _get_state(hass: HomeAssistant) -> dict[str, Any]:
    """Get the current onboarding state."""
    return hass.data[DOMAIN]["state"]


def _check_not_completed(hass: HomeAssistant) -> web.Response | None:
    """Return a 403 response if onboarding is already completed."""
    state = _get_state(hass)
    if state.get("completed"):
        return web.json_response(
            {"message": "Onboarding already completed"}, status=403
        )
    return None


def _pin_file_path(hass: HomeAssistant) -> Path:
    """Get the path to the onboarding PIN file."""
    return Path(hass.config.path(PIN_FILE))


def _pin_required(hass: HomeAssistant) -> bool:
    """Check if a PIN file exists on the device."""
    return _pin_file_path(hass).exists()


def _check_pin_verified(hass: HomeAssistant) -> web.Response | None:
    """Return 403 if PIN is required but not yet verified.

    Called by GDPR, create_user, and other endpoints to gate access
    until physical access is proven.
    """
    if not _pin_required(hass):
        return None  # No PIN file — no verification needed
    state = _get_state(hass)
    if state.get("pin_verified"):
        return None  # Already verified
    return web.json_response({"error": "PIN verification required"}, status=403)


class GAOnboardingPageView(HomeAssistantView):
    """Redirect to the built greenautarky-setup.html page.

    The actual HTML is built by the frontend build pipeline and served as a
    static file by the frontend component (just like onboarding.html).
    """

    url = "/greenautarky-setup"
    name = "greenautarky_onboarding:page"
    requires_auth = False

    async def get(self, request: web.Request) -> web.Response:
        """Redirect to the built frontend page."""
        hass: HomeAssistant = request.app["hass"]
        state = _get_state(hass)
        if state.get("completed"):
            raise web.HTTPFound("/")
        raise web.HTTPFound("/greenautarky-setup.html")


class GAAdminBypassView(HomeAssistantView):
    """Admin shortcut that bypasses the GA tenant onboarding wizard.

    GET /admin redirects to /auth/authorize with self-referential OAuth
    params and ga_bypass=1, landing the admin on the normal HA login page
    (not the tenant onboarding wizard) regardless of onboarding state.

    Self-referential OAuth params (client_id = device origin, redirect_uri =
    device-origin/config) are required because <ha-authorize> rejects the
    request as "Invalid redirect URI" otherwise. /config is used instead
    of /lovelace so a logged-in admin lands in HA Settings — never on the
    GA setup panel which is the auto-default while onboarding is incomplete.

    A `ga_bypass=1` cookie is also set on the redirect response so the
    server-side IndexView (frontend/__init__.py) skips its own redirect
    when the post-OAuth `/config?code=…` landing arrives without the
    `ga_bypass=1` query (HA's OAuth strips query params from redirect_uri).
    """

    url = "/admin"
    name = "greenautarky_onboarding:admin"
    requires_auth = False

    async def get(self, request: web.Request) -> web.Response:
        """Redirect to /auth/authorize with admin-bypass params."""
        # Build origin from the request so it works regardless of how the
        # device is reached (NetBird IP, LAN IP, hostname, public domain).
        origin = f"{request.scheme}://{request.host}"
        # `auth_callback=1` is required so the HA frontend SPA recognises
        # `/config?code=…&auth_callback=1` as its own OAuth callback and
        # exchanges the code for a token. Without it the SPA discards the
        # code and starts a fresh OAuth round-trip, forcing a second login.
        #
        # `state` mirrors what home-assistant-js-websocket does on its own
        # OAuth init: base64(JSON({hassUrl, clientId})). Without it the SPA
        # crashes with "InvalidCharacterError: atob" while validating the
        # callback. Bytes-form base64 to match what HA produces (no padding
        # is fine — HA decodes via atob which is permissive).
        state = base64.b64encode(
            json.dumps({"hassUrl": origin, "clientId": f"{origin}/"}).encode()
        ).decode()
        params = urlencode(
            {
                "client_id": f"{origin}/",
                "redirect_uri": f"{origin}/config?auth_callback=1",
                "state": state,
                "ga_bypass": "1",
            }
        )
        response = web.Response(
            status=302,
            headers={"location": f"/auth/authorize?{params}"},
        )
        # Mirror IndexView's cookie shape (frontend/__init__.py:735-743).
        response.set_cookie(
            "ga_bypass",
            "1",
            max_age=3600,
            httponly=True,
            samesite="Lax",
            path="/",
        )
        return response


class GAOnboardingStatusView(HomeAssistantView):
    """Return current onboarding status."""

    url = "/api/greenautarky_onboarding/status"
    name = "api:greenautarky_onboarding:status"
    requires_auth = False

    async def get(self, request: web.Request) -> web.Response:
        """Return onboarding status including PIN verification state."""
        hass: HomeAssistant = request.app["hass"]
        state = _get_state(hass)
        response = {**state}

        # Admin bypass cookie: report completed=true so authorize.ts (client-side)
        # skips the GA onboarding redirect and shows the normal HA login.
        if request.cookies.get("ga_bypass") == "1":
            response["completed"] = True

        # Add PIN status fields
        response["pin_required"] = _pin_required(hass)
        response["pin_verified"] = state.get("pin_verified", False)
        locked_until = state.get("pin_locked_until")
        if locked_until:
            remaining = (
                datetime.fromisoformat(locked_until) - datetime.now(UTC)
            ).total_seconds()
            response["pin_retry_after"] = max(0, int(remaining))

        return self.json(response)


class GAOnboardingGDPRView(HomeAssistantView):
    """Handle GDPR consent."""

    url = "/api/greenautarky_onboarding/gdpr"
    name = "api:greenautarky_onboarding:gdpr"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Accept GDPR consent."""
        hass: HomeAssistant = request.app["hass"]
        if err := _check_not_completed(hass):
            return err
        if err := _check_pin_verified(hass):
            return err

        state = _get_state(hass)
        store = _get_store(hass)

        body = await request.json()
        state["gdpr_accepted"] = bool(body.get("accepted", False))
        if "gdpr" not in state["steps_done"]:
            state["steps_done"].append("gdpr")
        await store.async_save(state)

        return self.json({"status": "ok"})


class GAOnboardingTelemetryView(HomeAssistantView):
    """Handle telemetry preferences."""

    url = "/api/greenautarky_onboarding/telemetry"
    name = "api:greenautarky_onboarding:telemetry"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Save telemetry preferences."""
        hass: HomeAssistant = request.app["hass"]
        if err := _check_not_completed(hass):
            return err

        state = _get_state(hass)
        store = _get_store(hass)

        body = await request.json()

        # Forward to greenautarky_telemetry integration
        telemetry_data = hass.data.get("greenautarky_telemetry")
        if telemetry_data:
            prefs = telemetry_data["preferences"]
            prefs["error_logs"] = bool(body.get("error_logs", False))
            prefs["metrics"] = bool(body.get("metrics", False))
            telemetry_store: Store = telemetry_data["store"]
            await telemetry_store.async_save(prefs)

        if "telemetry" not in state["steps_done"]:
            state["steps_done"].append("telemetry")
        await store.async_save(state)

        return self.json({"status": "ok"})


class GAOnboardingEthernetView(HomeAssistantView):
    """Handle Ethernet consent.

    Ethernet is disabled by default (set during provisioning by ga-flasher).
    Users must actively consent to enable it during onboarding.
    """

    url = "/api/greenautarky_onboarding/ethernet"
    name = "api:greenautarky_onboarding:ethernet"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Save Ethernet preference and record consent."""
        hass: HomeAssistant = request.app["hass"]
        if err := _check_not_completed(hass):
            return err

        state = _get_state(hass)
        store = _get_store(hass)

        body = await request.json()
        enable_ethernet = bool(body.get("enable_ethernet", False))

        # Record consent via the version-tracked consent system
        await async_record_consent(hass, store, state, "ethernet")

        if enable_ethernet:

            def _enable_ethernet() -> None:
                subprocess.run(
                    ["ga-manage-ethernet", "enable"],
                    timeout=10,
                    check=False,
                )

            try:
                await hass.async_add_executor_job(_enable_ethernet)
            except Exception:
                _LOGGER.exception("Failed to enable Ethernet")
                return web.json_response(
                    {"message": "Failed to enable Ethernet"}, status=500
                )

        if "ethernet" not in state["steps_done"]:
            state["steps_done"].append("ethernet")
        await store.async_save(state)

        return self.json({"status": "ok"})


class GAOnboardingCompleteView(HomeAssistantView):
    """Mark onboarding as complete."""

    url = "/api/greenautarky_onboarding/complete"
    name = "api:greenautarky_onboarding:complete"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Complete the GA onboarding."""
        hass: HomeAssistant = request.app["hass"]
        if err := _check_not_completed(hass):
            return err

        state = _get_state(hass)
        store = _get_store(hass)

        if "complete" not in state["steps_done"]:
            state["steps_done"].append("complete")
        state["completed"] = True
        await store.async_save(state)

        # Remove the sidebar panel (for app users)
        frontend.async_remove_panel(
            hass, "greenautarky-setup-panel", warn_if_unknown=False
        )

        _LOGGER.info("greenautarky onboarding completed")

        return self.json({"status": "ok", "redirect": "/"})


class GAOnboardingCreateUserView(HomeAssistantView):
    """Create a user account during greenautarky onboarding.

    This endpoint is unauthenticated (the end user has no account yet).
    It creates a normal (non-admin) user and returns an auth_code so the
    frontend can authenticate and continue with authenticated steps.
    """

    url = "/api/greenautarky_onboarding/create_user"
    name = "api:greenautarky_onboarding:create_user"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Create a new user and return auth_code for frontend auth."""
        hass: HomeAssistant = request.app["hass"]
        if err := _check_not_completed(hass):
            return err
        if err := _check_pin_verified(hass):
            return err

        body = await request.json()
        client_id = body.get("client_id", "").strip()
        name = body.get("name", "").strip()
        username = body.get("username", "").strip()
        password = body.get("password", "")
        body.get("language", "de")

        if not name or not username or not password or not client_id:
            return self.json_message(
                "client_id, name, username, and password are required",
                status_code=400,
            )

        # Create user in normal user group (not admin)
        user = await hass.auth.async_create_user(name, group_ids=[GROUP_ID_USER])

        # Create credentials via homeassistant auth provider
        provider = _async_get_hass_provider(hass)
        await provider.async_initialize()
        try:
            await provider.async_add_auth(username, password)
        except InvalidUser:
            return self.json_message("Username already exists", status_code=400)
        credentials = await provider.async_get_or_create_credentials(
            {"username": username}
        )
        await hass.auth.async_link_user(user, credentials)

        # Create person entity if available
        if "person" in hass.config.components:
            from homeassistant.components import person  # noqa: PLC0415

            await person.async_create_person(hass, name, user_id=user.id)

        # Mark account step as done
        state = _get_state(hass)
        store = _get_store(hass)
        if "account" not in state.get("steps_done", []):
            state.setdefault("steps_done", []).append("account")
            await store.async_save(state)

        # Return auth_code so frontend can authenticate
        from homeassistant.components.auth import create_auth_code  # noqa: PLC0415

        auth_code = create_auth_code(hass, client_id, credentials)

        _LOGGER.info("Created user via greenautarky onboarding: %s", name)

        return self.json({"auth_code": auth_code})


# ---------------------------------------------------------------------------
# Test/QA reset endpoint (admin-authenticated)
# ---------------------------------------------------------------------------


class GAOnboardingResetView(HomeAssistantView):
    """Reset GA onboarding state to allow re-running the wizard.

    Intended for QA and automated testing (e.g. ga-flasher stage 90).
    Requires admin authentication — the ga-flasher uses the admin token
    obtained during Phase 1 provisioning to call this endpoint.

    Resets: completed, gdpr_accepted, steps_done.
    Preserves: consents (version-tracked separately).
    """

    url = "/api/greenautarky_onboarding/reset"
    name = "api:greenautarky_onboarding:reset"
    requires_auth = True

    async def post(self, request: web.Request) -> web.Response:
        """Reset onboarding state."""
        hass: HomeAssistant = request.app["hass"]

        # Require admin
        user = request["hass_user"]
        if not user.is_admin:
            return web.json_response({"message": "Admin required"}, status=403)

        state = _get_state(hass)
        store = _get_store(hass)

        # Reset wizard state, preserve consents
        state["completed"] = False
        state["gdpr_accepted"] = False
        state["steps_done"] = []
        await store.async_save(state)

        # Re-register the sidebar panel if it was removed on completion.
        # Skip if already registered (e.g. onboarding was never completed).
        from homeassistant.components.frontend import DATA_PANELS  # noqa: PLC0415

        # Relative import of our own package __init__ — works whether this
        # is loaded as a built-in (homeassistant.components.*) or a
        # custom_component (custom_components.*). Deferred (inside the
        # handler) to avoid a circular import: __init__.py imports http.py.
        from . import (  # noqa: PLC0415
            PANEL_URL_PATH,
            _async_register_panel,
        )

        if PANEL_URL_PATH not in hass.data.get(DATA_PANELS, {}):
            await _async_register_panel(hass)

        _LOGGER.info("greenautarky onboarding state reset by %s", user.name)
        return self.json({"status": "ok"})


# ---------------------------------------------------------------------------
# PIN verification (unauthenticated — proves physical access to device)
# ---------------------------------------------------------------------------


class GAPinVerifyView(HomeAssistantView):
    """Verify the 6-digit onboarding PIN printed on the device sticker.

    The PIN file is written to the device during provisioning (ga-flasher
    stage 69b) and persists across onboarding resets. Exponential backoff
    prevents brute-force attacks from the internet.

    Rate limiting: delay = min(5 * 2^(attempt-2), 3600) for attempt >= 2
    """

    url = "/api/greenautarky_onboarding/verify_pin"
    name = "api:greenautarky_onboarding:verify_pin"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Verify the submitted PIN against the device's PIN file."""
        hass: HomeAssistant = request.app["hass"]

        if err := _check_not_completed(hass):
            return err

        state = _get_state(hass)
        store = _get_store(hass)

        # Already verified — idempotent
        if state.get("pin_verified"):
            return self.json({"status": "ok"})

        # Check rate limit
        locked_until = state.get("pin_locked_until")
        if locked_until:
            remaining = (
                datetime.fromisoformat(locked_until) - datetime.now(UTC)
            ).total_seconds()
            if remaining > 0:
                return self.json(
                    {
                        "status": "locked",
                        "message": "Too many attempts",
                        "retry_after": int(remaining),
                    },
                    status_code=429,
                )

        # Read PIN from device file
        pin_path = _pin_file_path(hass)
        if not pin_path.exists():
            return self.json(
                {"error": "No PIN configured on this device"}, status_code=404
            )

        stored_pin = pin_path.read_text().strip()

        # Parse submitted PIN (strip dashes, whitespace)
        body = await request.json()
        submitted_pin = body.get("pin", "").strip().replace("-", "")

        # Constant-time comparison to prevent timing attacks
        if hmac.compare_digest(submitted_pin.encode(), stored_pin.encode()):
            # Success
            state["pin_verified"] = True
            if "pin" not in state.get("steps_done", []):
                state.setdefault("steps_done", []).append("pin")
            state["pin_attempts"] = 0
            state["pin_locked_until"] = None
            await store.async_save(state)
            _LOGGER.info("Onboarding PIN verified successfully")
            return self.json({"status": "ok"})

        # Failure — increment attempts with exponential backoff
        attempts = state.get("pin_attempts", 0) + 1
        state["pin_attempts"] = attempts

        delay = 0
        if attempts >= 2:
            delay = min(5 * (2 ** (attempts - 2)), PIN_MAX_DELAY)
            lock_time = datetime.now(UTC) + timedelta(seconds=delay)
            state["pin_locked_until"] = lock_time.isoformat()

        await store.async_save(state)
        _LOGGER.warning("Invalid PIN attempt %d (next retry in %ds)", attempts, delay)
        return self.json(
            {
                "status": "error",
                "message": "Invalid PIN",
                "retry_after": delay,
                "attempts": attempts,
            },
            status_code=401,
        )


# ---------------------------------------------------------------------------
# Password reset (unauthenticated — PIN-based, for locked-out users)
# ---------------------------------------------------------------------------


def _check_pw_reset_rate_limit(
    state: dict[str, Any],
) -> web.Response | None:
    """Check password reset rate limit. Returns 429 response if locked."""
    locked_until = state.get("pw_reset_pin_locked_until")
    if locked_until:
        remaining = (
            datetime.fromisoformat(locked_until) - datetime.now(UTC)
        ).total_seconds()
        if remaining > 0:
            return web.json_response(
                {
                    "status": "locked",
                    "message": "Too many attempts",
                    "retry_after": int(remaining),
                },
                status=429,
            )
    return None


def _verify_pw_reset_pin(
    hass: HomeAssistant,
    state: dict[str, Any],
    submitted_pin: str,
) -> bool:
    """Verify PIN for password reset. Returns True if correct."""
    pin_path = _pin_file_path(hass)
    if not pin_path.exists():
        return False
    stored_pin = pin_path.read_text().strip()
    clean_pin = submitted_pin.strip().replace("-", "")
    return hmac.compare_digest(clean_pin.encode(), stored_pin.encode())


class GAPasswordResetPageView(HomeAssistantView):
    """Serve the standalone password reset page."""

    url = "/greenautarky-password-reset"
    name = "greenautarky_onboarding:password_reset_page"
    requires_auth = False

    async def get(self, request: web.Request) -> web.Response:
        """Serve the password reset page HTML."""
        return web.Response(text=_PW_RESET_HTML, content_type="text/html")


class GAPasswordResetUsersView(HomeAssistantView):
    """Return list of resettable users after PIN verification.

    Only tenant users (GROUP_ID_USER) are returned — admin accounts
    are excluded and managed via flasher/SSH.
    """

    url = "/api/greenautarky_onboarding/password_reset/users"
    name = "api:greenautarky_onboarding:password_reset:users"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Return resettable users after verifying PIN."""
        hass: HomeAssistant = request.app["hass"]
        state = _get_state(hass)
        store = _get_store(hass)

        # Rate limit check
        if err := _check_pw_reset_rate_limit(state):
            return err

        body = await request.json()
        submitted_pin = body.get("pin", "")

        # PIN file must exist
        if not _pin_required(hass):
            return self.json(
                {"error": "No PIN configured on this device"}, status_code=404
            )

        if not _verify_pw_reset_pin(hass, state, submitted_pin):
            # Increment attempts with exponential backoff
            attempts = state.get("pw_reset_pin_attempts", 0) + 1
            state["pw_reset_pin_attempts"] = attempts
            delay = 0
            if attempts >= 2:
                delay = min(5 * (2 ** (attempts - 2)), PIN_MAX_DELAY)
                lock_time = datetime.now(UTC) + timedelta(seconds=delay)
                state["pw_reset_pin_locked_until"] = lock_time.isoformat()
            await store.async_save(state)
            _LOGGER.warning(
                "Invalid password reset PIN attempt %d (next retry in %ds)",
                attempts,
                delay,
            )
            return self.json(
                {
                    "status": "error",
                    "message": "Invalid PIN",
                    "retry_after": delay,
                    "attempts": attempts,
                },
                status_code=401,
            )

        # PIN correct — collect resettable users
        provider = _async_get_hass_provider(hass)
        await provider.async_initialize()

        users = []
        for user in await hass.auth.async_get_users():
            if user.system_generated:
                continue
            if user.is_admin:
                continue
            # Must have homeassistant auth credentials
            username = None
            for cred in user.credentials:
                if cred.auth_provider_type == "homeassistant":
                    username = cred.data.get("username")
                    break
            if username:
                users.append({"name": user.name, "username": username})

        return self.json({"status": "ok", "users": users})


class GAPasswordResetView(HomeAssistantView):
    """Reset a tenant user's password after PIN verification.

    Only GROUP_ID_USER accounts can be reset — admin accounts are
    protected and managed via flasher/SSH.
    """

    url = "/api/greenautarky_onboarding/password_reset"
    name = "api:greenautarky_onboarding:password_reset"
    requires_auth = False

    async def post(self, request: web.Request) -> web.Response:
        """Reset password after PIN verification."""
        hass: HomeAssistant = request.app["hass"]
        state = _get_state(hass)
        store = _get_store(hass)

        # Rate limit check
        if err := _check_pw_reset_rate_limit(state):
            return err

        body = await request.json()
        submitted_pin = body.get("pin", "")
        username = body.get("username", "").strip()
        new_password = body.get("new_password", "")

        if not username or not new_password:
            return self.json(
                {"error": "username and new_password are required"},
                status_code=400,
            )

        # PIN file must exist
        if not _pin_required(hass):
            return self.json(
                {"error": "No PIN configured on this device"}, status_code=404
            )

        # Verify PIN
        if not _verify_pw_reset_pin(hass, state, submitted_pin):
            attempts = state.get("pw_reset_pin_attempts", 0) + 1
            state["pw_reset_pin_attempts"] = attempts
            delay = 0
            if attempts >= 2:
                delay = min(5 * (2 ** (attempts - 2)), PIN_MAX_DELAY)
                lock_time = datetime.now(UTC) + timedelta(seconds=delay)
                state["pw_reset_pin_locked_until"] = lock_time.isoformat()
            await store.async_save(state)
            _LOGGER.warning(
                "Invalid password reset PIN attempt %d (next retry in %ds)",
                attempts,
                delay,
            )
            return self.json(
                {
                    "status": "error",
                    "message": "Invalid PIN",
                    "retry_after": delay,
                    "attempts": attempts,
                },
                status_code=401,
            )

        # Verify user is a tenant (GROUP_ID_USER), not admin or system
        target_user = None
        for user in await hass.auth.async_get_users():
            if user.system_generated or user.is_admin:
                continue
            for cred in user.credentials:
                if (
                    cred.auth_provider_type == "homeassistant"
                    and cred.data.get("username") == username
                ):
                    target_user = user
                    break
            if target_user:
                break

        if target_user is None:
            return self.json(
                {"error": "User not found or not resettable"},
                status_code=404,
            )

        # Change password
        provider = _async_get_hass_provider(hass)
        try:
            await provider.async_change_password(username, new_password)
        except InvalidUser:
            return self.json(
                {"error": "User not found in auth provider"},
                status_code=404,
            )

        # Reset PIN attempt counter on success
        state["pw_reset_pin_attempts"] = 0
        state["pw_reset_pin_locked_until"] = None
        await store.async_save(state)

        _LOGGER.info(
            "Password reset via PIN for user '%s' (%s)", username, target_user.name
        )
        return self.json({"status": "ok"})


# ---------------------------------------------------------------------------
# Consent views (authenticated — for post-onboarding consent re-confirmation)
# ---------------------------------------------------------------------------


class GAConsentPageView(HomeAssistantView):
    """Serve the standalone consent re-confirmation page."""

    url = "/greenautarky-consent"
    name = "greenautarky_onboarding:consent_page"
    requires_auth = False

    async def get(self, request: web.Request) -> web.Response:
        """Serve the consent page HTML."""
        return web.Response(text=_CONSENT_HTML, content_type="text/html")


class GAConsentStatusView(HomeAssistantView):
    """Return which consents are outdated."""

    url = "/api/greenautarky_onboarding/consent/status"
    name = "api:greenautarky_onboarding:consent:status"
    requires_auth = True

    async def get(self, request: web.Request) -> web.Response:
        """Return consent status."""
        hass: HomeAssistant = request.app["hass"]
        state = _get_state(hass)
        outdated = get_outdated_consents(state)
        return self.json(
            {
                "consents": state.get("consents", {}),
                "outdated": list(outdated.keys()),
            }
        )


class GAConsentAcceptView(HomeAssistantView):
    """Accept a consent type."""

    url = "/api/greenautarky_onboarding/consent/accept"
    name = "api:greenautarky_onboarding:consent:accept"
    requires_auth = True

    async def post(self, request: web.Request) -> web.Response:
        """Record consent acceptance."""
        hass: HomeAssistant = request.app["hass"]
        store = _get_store(hass)
        state = _get_state(hass)

        body = await request.json()
        consent_type = body.get("type", "")

        if not consent_type:
            return web.json_response({"message": "Missing 'type' field"}, status=400)

        ok = await async_record_consent(hass, store, state, consent_type)
        if not ok:
            return web.json_response(
                {"message": f"Unknown consent type: {consent_type}"}, status=400
            )

        return self.json({"status": "ok"})
