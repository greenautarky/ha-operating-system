"""Ask the RUNNING Home Assistant Core for its HTTP config (``http/config``).

Runs INSIDE the ga_manager container (the one place on the device holding a
SUPERVISOR_TOKEN), piped in by config_verify/test.sh:

    docker exec -i <ga_manager> python3 - < http_config_query.py

Prints ONE JSON object on stdout:
  * the websocket result message (``{"id":1,"type":"result","success":true,
    "result":{"stable":…,"pending":…,"active_config_type":…,…}}``), or
  * ``{"error": "<why>"}`` when the question could not be asked.

Core 2026.8+ only: ``http/config`` is admin-only; the Supervisor's websocket
proxy authenticates Core-side as the Supervisor's system user, which is admin.
Standard library + aiohttp, which ga_manager itself runs on.
"""

import asyncio
import json
import os
import sys

URL = "http://supervisor/core/websocket"
TIMEOUT_S = 20


async def main() -> int:
    auth = os.environ.get("SUPERVISOR_TOKEN") or os.environ.get("HASSIO_TOKEN")
    if not auth:
        print(json.dumps({"error": "no SUPERVISOR_TOKEN in this container"}))
        return 2
    try:
        import aiohttp
    except ImportError as e:
        print(json.dumps({"error": f"aiohttp unavailable: {e}"}))
        return 2
    try:
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(URL, headers={"Authorization": f"Bearer {auth}"}) as ws:
                hello = await ws.receive_json(timeout=TIMEOUT_S)
                if hello.get("type") == "auth_required":
                    await ws.send_json({"type": "auth", "access_token": auth})
                    reply = await ws.receive_json(timeout=TIMEOUT_S)
                    if reply.get("type") != "auth_ok":
                        print(json.dumps({"error": f"auth refused: {reply.get('type')}"}))
                        return 3
                await ws.send_json({"id": 1, "type": "http/config"})
                while True:
                    msg = await ws.receive_json(timeout=TIMEOUT_S)
                    if msg.get("id") == 1:
                        print(json.dumps(msg))
                        return 0 if msg.get("success") else 4
    except Exception as e:  # noqa: BLE001 — every failure is reported, none raised
        print(json.dumps({"error": f"{e.__class__.__name__}: {e}"}))
        return 5


async def bounded() -> int:
    try:
        return await asyncio.wait_for(main(), timeout=3 * TIMEOUT_S)
    except asyncio.TimeoutError:
        print(json.dumps({"error": f"no answer within {3 * TIMEOUT_S}s"}))
        return 6


sys.exit(asyncio.run(bounded()))
