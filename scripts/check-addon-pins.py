#!/usr/bin/env python3
"""Compare the OS bake pins against the published add-on store, and optionally
update them.

`buildroot-external/package/hassio/addon-images.json` decides which add-on
image version is baked into the OS image. The published truth for an add-on
lives in the PUBLIC greenautarky/vibe_addons store repo, which the Supervisor
reads on the device.

Until now each add-on's CI pushed its pin INTO this repo, which meant handing
every add-on repo a write token for the OS. This inverts it: the OS reads the
public store itself and proposes its own pin. No cross-repo credential, and the
pin no longer depends on some add-on repo happening to build.

The join is the IMAGE REF, not the JSON key: the keys here are local names
("mosquitto", "sonoff_dongle_flasher") while the store entry is keyed by the
add-on slug. `ghcr.io/greenautarky/ga_mosquitto-{arch}` -> slug ga_mosquitto.

    python3 scripts/check-addon-pins.py --store <path-to-vibe_addons-checkout>
    python3 scripts/check-addon-pins.py --store <path> --apply

Exit 0 = pins match the store (or --apply updated them). Exit 1 = drift found
in check mode, or nothing could be inspected. Never reports success over zero
add-ons: a comparison that ran over nothing proves nothing.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

import yaml

PINS = pathlib.Path("buildroot-external/package/hassio/addon-images.json")
IMAGE_RE = re.compile(r"^ghcr\.io/greenautarky/(?P<slug>[A-Za-z0-9_.-]+)-\{arch\}$")


def store_index(store_root: pathlib.Path) -> dict[str, str]:
    """slug -> version, from every <dir>/config.{yaml,json} in the store repo.

    Both extensions on purpose: the Supervisor accepts either, and two entries
    still use the legacy JSON form (zigbee2mqtt, the sonoff dongle flasher).
    Globbing only *.yaml silently skipped them — and z2m is one of the most
    frequently bumped add-ons we bake.
    """
    index: dict[str, str] = {}
    candidates = sorted(store_root.glob("*/config.yaml")) + sorted(store_root.glob("*/config.json"))
    for cfg in candidates:
        try:
            # yaml.safe_load parses JSON too, so one code path covers both.
            data = yaml.safe_load(cfg.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError as e:
            print(f"::warning::{cfg} is not valid YAML/JSON: {e}")
            continue
        slug, version = data.get("slug"), data.get("version")
        if slug and version is not None:
            index[str(slug)] = str(version)
    return index


def _is_prerelease(version: str) -> bool:
    """True for a canary tag, False for a normal release.

    The naive test — "does it contain a dash" — is wrong here: z2m ships as
    `2.12.1-3`, upstream version plus add-on revision, and treating that as a
    canary would silently stop proposing z2m pins forever. Our canary tags carry
    letters after the dash (`1.3.0-ga.1`); a plain numeric suffix is a release
    revision.
    """
    _, _, suffix = version.partition("-")
    return bool(suffix) and any(ch.isalpha() for ch in suffix)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", required=True, help="path to a vibe_addons checkout")
    ap.add_argument("--apply", action="store_true", help="write the new versions")
    args = ap.parse_args(argv)

    store = store_index(pathlib.Path(args.store))
    if not store:
        print("::error::no store entries found — refusing to report success")
        return 1

    pins = json.loads(PINS.read_text(encoding="utf-8"))
    addons = pins.get("addons") or {}
    if not addons:
        print(f"::error::{PINS} declares no add-ons — refusing to report success")
        return 1

    behind: list[tuple[str, str, str]] = []
    unmatched: list[str] = []
    prerelease: list[str] = []
    ok = 0

    for key, entry in addons.items():
        m = IMAGE_RE.match(str(entry.get("image", "")))
        if not m:
            unmatched.append(f"{key} (image not ours: {entry.get('image')})")
            continue
        slug = m.group("slug")
        published = store.get(slug)
        if published is None:
            unmatched.append(f"{key} (slug {slug} has no store entry)")
            continue
        pinned = str(entry.get("version"))
        if _is_prerelease(published):
            # A pre-release in the store is a CANARY: an image built from a
            # feature branch, with the store pointed at it by hand so exactly
            # one device pulls it. Baking that into an OS image would ship a
            # branch build to every device flashed from it — the opposite of
            # what the canary is for. Reported, never proposed.
            prerelease.append(f"{key} (store is on the pre-release {published}, pinned {pinned})")
        elif pinned != published:
            behind.append((key, pinned, published))
        else:
            ok += 1

    print(f"inspected {len(addons)} pins against {len(store)} store entries: "
          f"{ok} in sync, {len(behind)} drifted, {len(prerelease)} on a pre-release, "
          f"{len(unmatched)} unmatched")
    for p in prerelease:
        print(f"  pre-release, NOT proposed: {p}")
    for u in unmatched:
        print(f"  unmatched: {u}")
    for key, pinned, published in behind:
        print(f"  DRIFT {key}: pinned {pinned} -> store {published}")

    if ok == 0 and not behind:
        print("::error::not a single pin could be compared — refusing to report success")
        return 1

    if not behind:
        return 0

    if not args.apply:
        return 1

    for key, _pinned, published in behind:
        addons[key]["version"] = published
    PINS.write_text(json.dumps(pins, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"updated {len(behind)} pin(s) in {PINS}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
