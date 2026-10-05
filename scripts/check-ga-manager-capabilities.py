#!/usr/bin/env python3
"""check-ga-manager-capabilities.py — does the BAKED ga_manager carry what this OS needs?

WHY THIS EXISTS
---------------
Some things a fresh device needs are not in the OS at all: they are delivered
by the ga_manager add-on that the bake stores in the data partition. On
BOSv1.4.0-rc2 nothing configured Home Assistant Core's InfluxDB integration,
so Core wrote nothing into the device-local ``ga_homeassistant_db`` — the
database ga_hmvapp_addon and ga_default_addon read room temperatures from. The
fix lives in ga_manager (the ``ha_influxdb`` reconciler, 0.221.0). An OS image
that pins an older ga_manager ships the defect again, and nothing in the build
said so.

WHAT IT INSPECTS
----------------
1. The pin (``addon-images.json``): the ga_manager version must be at least
   the release that introduced each capability below. Cheap, and it runs on a
   source-only checkout too.
2. The ARTEFACT: the ga_manager image tar the bake actually wrote
   (``fetch-container-image.sh`` -> ``skopeo copy … docker-archive:``). The tar
   is found by the exact name derived from the pin — the same derivation
   ``check-baked-addon-images.sh`` uses — and its layers are read in the order
   ``manifest.json`` lists them, last writer wins, whiteouts honoured. Each
   capability names files and the text they must contain. The version the
   image says it is (``/opt/ga-manager/source-config.yaml``) is compared with
   the pin as well: two sources for one fact are compared, not reported side
   by side.

The expectations below are pinned constants. Nothing is derived from the
image or the pin under inspection.

EXIT CODES
----------
0 every capability present · 1 a capability missing or the pin too old ·
2 cannot judge (no pin, unreadable tar, nothing inspected) — never a pass.
"""
from __future__ import annotations

import argparse
import io
import json
import re
import sys
import tarfile
from pathlib import Path

#: What the OS relies on ga_manager for. Add a row when the OS starts relying
#: on a new one; never derive a row from the artefact.
CAPABILITIES: list[dict] = [
    {
        "id": "core_influxdb",
        "since": "0.221.0",
        "why": "HA Core's InfluxDB integration -> ga_homeassistant_db "
               "(BOSv1.4.0-rc2 shipped without it)",
        "files": {
            "usr/bin/ga_manager/ha_influxdb.py": [
                'DATABASE = "ga_homeassistant_db"',
                'USERNAME = "ga_ha_influx_user"',
            ],
            "usr/bin/ga_manager/desired_state.py": ['name="ha_influxdb"'],
            "usr/bin/ga_manager/healthchecks/dataflow.py": [
                'CORE_DATABASE = "ga_homeassistant_db"',
            ],
        },
    },
]
ADDON = "ga_manager"
SOURCE_CONFIG = "opt/ga-manager/source-config.yaml"


def vtuple(v: str) -> tuple[int, ...] | None:
    m = re.fullmatch(r"\s*(\d+)\.(\d+)\.(\d+)\s*", str(v or ""))
    return tuple(int(x) for x in m.groups()) if m else None


def tar_prefix(image: str, version: str, arch: str) -> str:
    ref = f"{image.replace('{arch}', arch)}:{version}"
    return ref.replace("/", "_").replace(":", "_")


def _norm(name: str) -> str:
    return name[2:] if name.startswith("./") else name.lstrip("/")


def read_layered(tar_path: Path, wanted: set[str]) -> dict[str, bytes | None]:
    """The final content of each wanted path across the image's layers.

    None for a path no layer provides (or a later layer deleted). Raises
    ValueError when the archive is not a docker-archive this can read.
    """
    out: dict[str, bytes | None] = {w: None for w in wanted}
    with tarfile.open(tar_path, "r:*") as outer:
        try:
            manifest = json.load(outer.extractfile("manifest.json"))  # type: ignore[arg-type]
        except (KeyError, TypeError, ValueError) as e:
            raise ValueError(f"no readable manifest.json ({e.__class__.__name__})") from None
        layers = (manifest[0] or {}).get("Layers") if isinstance(manifest, list) and manifest else None
        if not layers:
            raise ValueError("manifest.json lists no layers")
        for layer in layers:
            member = outer.extractfile(layer)
            if member is None:
                raise ValueError(f"layer {layer} missing from the archive")
            data = member.read()
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as lt:
                for m in lt.getmembers():
                    name = _norm(m.name)
                    base = name.rsplit("/", 1)
                    if len(base) == 2 and base[1].startswith(".wh."):
                        gone = f"{base[0]}/{base[1][4:]}"
                        if gone in out:
                            out[gone] = None
                        if base[1] == ".wh..wh..opq":
                            for w in out:
                                if w.startswith(base[0] + "/"):
                                    out[w] = None
                        continue
                    if name in out and m.isfile():
                        f = lt.extractfile(m)
                        out[name] = f.read() if f else None
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--pins", required=True, help="addon-images.json")
    ap.add_argument("--images-dir", help="the bake's hassio images dir; omit for a pin-only check")
    ap.add_argument("--arch", default="armv7")
    a = ap.parse_args(argv)
    if not CAPABILITIES:
        print("CANNOT JUDGE: CAPABILITIES is empty — a check of nothing is not a pass")
        return 2

    try:
        pin = json.loads(Path(a.pins).read_text(encoding="utf-8"))["addons"][ADDON]
        image, version = pin["image"], pin["version"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"CANNOT JUDGE: no {ADDON} pin readable in {a.pins} ({e.__class__.__name__})")
        return 2
    have = vtuple(version)
    if have is None:
        print(f"CANNOT JUDGE: {ADDON} pin version {version!r} is not X.Y.Z")
        return 2

    failed = 0
    for cap in CAPABILITIES:
        if have < vtuple(cap["since"]):  # type: ignore[operator]
            print(f"FAIL: {ADDON} {version} is pinned, {cap['id']} needs >= {cap['since']} — {cap['why']}")
            failed += 1
        else:
            print(f"ok:   pin {ADDON} {version} >= {cap['since']} ({cap['id']})")

    if not a.images_dir:
        print(f"{ADDON} capabilities: pin checked, artefact NOT inspected (no --images-dir)")
        return 1 if failed else 0

    prefix = tar_prefix(image, version, a.arch)
    tars = sorted(Path(a.images_dir).glob(f"{prefix}@sha256_*.tar"))
    if len(tars) != 1:
        print(f"FAIL: expected exactly one {prefix}@sha256_*.tar in {a.images_dir}, found {len(tars)}")
        return 1

    wanted = {SOURCE_CONFIG} | {p for cap in CAPABILITIES for p in cap["files"]}
    try:
        files = read_layered(tars[0], wanted)
    except (ValueError, tarfile.TarError, OSError) as e:
        print(f"CANNOT JUDGE: {tars[0].name} unreadable: {e}")
        return 2

    inspected = 0
    baked = files.get(SOURCE_CONFIG)
    m = re.search(rb'(?m)^version:\s*"?([0-9.]+)"?\s*$', baked or b"")
    if m is None:
        print(f"FAIL: the image carries no readable {SOURCE_CONFIG} version")
        failed += 1
    elif m.group(1).decode() != version:
        print(f"FAIL: the image says it is {ADDON} {m.group(1).decode()}, the pin says {version}")
        failed += 1
    else:
        print(f"ok:   image is {ADDON} {version} (source-config.yaml agrees with the pin)")

    for cap in CAPABILITIES:
        missing: list[str] = []
        for path, needles in cap["files"].items():
            inspected += 1  # a path looked for and absent is inspected, and a FAIL
            body = files.get(path)
            if body is None:
                missing.append(f"{path} absent")
                continue
            for n in needles:
                if n.encode() not in body:
                    missing.append(f"{path} lacks {n!r}")
        if missing:
            print(f"FAIL: {cap['id']} not in the baked image — {'; '.join(missing)}")
            failed += 1
        else:
            print(f"ok:   {cap['id']} present in the baked image ({len(cap['files'])} files)")

    if inspected == 0:
        print("CANNOT JUDGE: no capability file was inspected (empty CAPABILITIES)")
        return 2
    print(f"{ADDON} capabilities: {len(CAPABILITIES)} checked against {tars[0].name}, "
          f"{failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
