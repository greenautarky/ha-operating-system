#!/usr/bin/env python3
"""One command to repin the OS bake to the published add-on store.

Cutting an rc means bringing two files into step with the PUBLIC
greenautarky/vibe_addons store before the bake, by hand:

  * buildroot-external/package/hassio/addon-images.json — the pinned ``version``
    for every baked add-on (ga_manager, ga_default_addon, ga_hmvapp_addon,
    ga_influxdbv1, sonoff_dongle_flasher, …).
  * version.yaml ``gaos_release:`` — the ``BOSv1.3.0-rcN`` marker baked into
    ``/etc/ga-release``.

Hand-editing several version strings is where a typo slips in, and the typo is
not caught until the lock-step gate (``scripts/check-images.sh``, the
``check-versions`` job) turns the bake RED — late, after a multi-hour build has
already started. This script does the edit deterministically, and its
``--check`` mode lets an operator run the SAME comparison the gate runs FIRST,
so the red shows up on a laptop in one second instead of in the bake.

WHICH NOTION OF "THE STORE VERSION" — AND WHY NOT THE OTHER ONE
--------------------------------------------------------------
There are two store readers already in this repo and they do NOT agree on the
live store, so the choice is load-bearing:

  * ``scripts/check-images.sh`` — the ENFORCING ``check-versions`` gate — joins a
    pin to a store entry by the ``image:`` field. That is the gate whose red bake
    this tool exists to prevent, so ITS notion of "the store version" is the one
    that has to win.
  * ``scripts/check-addon-pins.py`` joins by a SLUG extracted from the image ref
    (``ghcr.io/greenautarky/<slug>-{arch}``). Measured 2026-08-31 against the
    live store, it cannot see ``sonoff_dongle_flasher`` at all: the pin's image
    yields slug ``ga_dongle_flasher``, but that add-on's store ``slug:`` is
    ``sonoff_dongle_flasher_for_ihost``, so it is silently "unmatched" and never
    repinned — while the ``image:`` field
    (``ghcr.io/greenautarky/ga_dongle_flasher-{arch}``) is byte-identical on both
    sides and the image-join matches it fine.

So this tool reuses the ENFORCING gate's image-join. It does NOT invent a third
notion: its selftest (``tests/gates/repin_addons/selftest.sh``) drives BOTH this
script and the real ``check-images.sh`` over the same fixtures and asserts their
verdicts agree — a mechanism guarding against the two drifting apart, not a
comment asking them not to.

Field extraction mirrors ``check-images.sh::_read_addon_field`` exactly (a
top-level scalar, a leading/trailing double-quote stripped, nothing else) so a
store entry reads the same here as in the gate. Stdlib only — no PyYAML — for the
same reason the gate uses awk/jq instead of a YAML library: fewer moving parts on
an operator's laptop, and the same parse either way.

The canary rule (``_is_prerelease``) is the SAME rule as
``check-images.sh::_is_prerelease`` and ``check-addon-pins.py::_is_prerelease``,
and it has to stay the same: a store on a canary (``1.3.0-ga.1``) is a decision
to bake a branch build onto every device, never a lock-step repair — so it is
reported and NEVER auto-pinned. A plain numeric suffix (z2m's ``2.12.1-4``) is a
release revision, not a canary.

USAGE
-----
    scripts/repin-addons.py                 # repin addon-images.json to the store
    scripts/repin-addons.py --check         # audit only; non-zero + names drift
    scripts/repin-addons.py --marker BOSv1.3.0-rc15   # also stamp version.yaml
    scripts/repin-addons.py --store PATH    # use a local vibe_addons checkout
                                            #   (default: clone it — one command)

``--marker`` combines with the default repin: cutting an rc is one command that
repins the pins AND stamps the marker together, so the two can never move apart.
The human-written trailing comment on the ``gaos_release:`` line is left exactly
as it is, for the operator to edit.

Exit 0 = in lockstep (or repinned / stamped). Non-zero = drift found in
``--check``, a pin with no matching store entry, an ambiguous store, or a run
that could compare nothing (a check that inspected nothing has proven nothing and
never reports success).
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

# REPO_ROOT is overridable exactly like scripts/check-images.sh honours it, so
# the selftest can drive this over a scratch tree. Every real invocation derives
# it from the script location.
REPO_ROOT = pathlib.Path(
    os.environ.get("REPO_ROOT") or pathlib.Path(__file__).resolve().parent.parent
)
PINS = REPO_ROOT / "buildroot-external/package/hassio/addon-images.json"
VERSION_YAML = REPO_ROOT / "version.yaml"

# Same source of truth and same env overrides as scripts/check-images.sh —
# "where the store is" is defined in ONE place, not two.
STORE_URL = os.environ.get("VIBE_ADDONS_REPO_URL", "https://github.com/greenautarky/vibe_addons")
STORE_REF = os.environ.get("VIBE_ADDONS_REPO_REF", "main")

# gaos_release: <marker>  <trailing comment kept verbatim>
MARKER_LINE_RE = re.compile(r"^(?P<pre>gaos_release:[ \t]*)(?P<ver>\S+)(?P<post>.*)$", re.MULTILINE)
# A BOS release marker: BOSvX.Y.Z, optionally -rcN. Deliberately narrow — the
# whole point of the tool is to stop a typo reaching the bake, so a marker that
# does not look like one is rejected here rather than baked.
MARKER_FMT_RE = re.compile(r"^BOSv\d+\.\d+\.\d+(-rc\d+)?$")


def _is_prerelease(version: str) -> bool:
    """True for a canary tag, False for a normal release or a release revision.

    SAME RULE as scripts/check-images.sh::_is_prerelease and
    scripts/check-addon-pins.py::_is_prerelease. The naive "contains a dash" test
    is wrong: z2m ships as ``2.12.1-4`` (upstream version + add-on revision) and
    treating that as a canary would silently stop repinning z2m forever. Our
    canary tags carry LETTERS after the dash (``1.3.0-ga.1``).
    """
    _, _, suffix = version.partition("-")
    return bool(suffix) and any(ch.isalpha() for ch in suffix)


def read_config_field(cfg: pathlib.Path, field: str) -> str | None:
    """Read one top-level scalar from a store add-on config.

    Mirrors scripts/check-images.sh::_read_addon_field byte-for-byte so this tool
    and the gate read a store entry identically:
      * .json  -> the top-level key via a JSON parse.
      * .yaml  -> the FIRST line that starts with ``field:`` (no indentation),
                  with a single leading and a single trailing double-quote
                  stripped and nothing else (no single-quote handling, no inline
                  comment stripping — exactly what the gate's awk does).
    """
    text = cfg.read_text(encoding="utf-8")
    if cfg.suffix == ".json":
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return None
        val = data.get(field)
        return None if val is None else str(val)
    prefix = f"{field}:"
    for line in text.splitlines():
        if line.startswith(prefix):
            val = line[len(prefix):].strip()
            # gate awk: gsub(/^"|"$/, "") — a leading and a trailing double-quote,
            # each removed independently.
            if val.startswith('"'):
                val = val[1:]
            if val.endswith('"'):
                val = val[:-1]
            return val
    return None


def store_image_index(store_root: pathlib.Path) -> tuple[dict[str, tuple[str, str]], list[str]]:
    """image -> (version, dirname) for every add-on in the store.

    Keyed by the ``image:`` field, the same join the enforcing gate uses. Both
    config.yaml and config.json are read: the Supervisor accepts either and the
    store mixes them (the sonoff flasher is JSON). A duplicate ``image:`` across
    two dirs is a malformed store — recorded and reported, never silently
    first-matched, because a silent pick could hide a store problem.
    """
    index: dict[str, tuple[str, str]] = {}
    duplicates: list[str] = []
    for d in sorted(p for p in store_root.iterdir() if p.is_dir()):
        cfg = None
        for name in ("config.yaml", "config.json"):
            candidate = d / name
            if candidate.is_file():
                cfg = candidate
                break
        if cfg is None:
            continue
        image = read_config_field(cfg, "image")
        version = read_config_field(cfg, "version")
        if not image or version is None:
            continue
        if image in index:
            duplicates.append(f"{image} (in {index[image][1]} and {d.name})")
            continue
        index[image] = (str(version), d.name)
    return index, duplicates


class Comparison:
    """The verdict of comparing addon-images.json against the store."""

    def __init__(self) -> None:
        self.ok: list[tuple[str, str]] = []                     # (key, version)
        self.drift: list[tuple[str, str, str, str]] = []        # (key, image, pinned, store)
        self.prerelease: list[tuple[str, str, str]] = []        # (key, store, pinned)
        self.missing: list[tuple[str, str]] = []                # (key, image)

    @property
    def compared(self) -> int:
        return len(self.ok) + len(self.drift) + len(self.prerelease)

    @property
    def clean(self) -> bool:
        """No action needed and nothing broken."""
        return not self.drift and not self.missing


def compare(pins: dict, store_index: dict[str, tuple[str, str]]) -> Comparison:
    c = Comparison()
    for key, entry in (pins.get("addons") or {}).items():
        image = str(entry.get("image", ""))
        pinned = str(entry.get("version"))
        found = store_index.get(image)
        if found is None:
            c.missing.append((key, image))
            continue
        store_version, _dirname = found
        if _is_prerelease(store_version) and not _is_prerelease(pinned):
            # Store is on a canary, pin holds a release: a decision, not drift.
            c.prerelease.append((key, store_version, pinned))
        elif pinned != store_version:
            c.drift.append((key, image, pinned, store_version))
        else:
            c.ok.append((key, pinned))
    return c


def print_report(c: Comparison, total_pins: int, store_entries: int) -> None:
    print(
        f"inspected {total_pins} pins against {store_entries} store entries: "
        f"{len(c.ok)} in lockstep, {len(c.drift)} drifted, "
        f"{len(c.prerelease)} on a pre-release, {len(c.missing)} with no store entry"
    )
    for key, store_v, pinned in c.prerelease:
        print(f"  PRERELEASE {key}: store is on canary {store_v}, pin holds release {pinned} "
              f"— NOT drift; baking a canary is a deliberate decision, left as-is")
    for key, image in c.missing:
        print(f"  NO STORE ENTRY {key}: image {image} matches no add-on in the store")
    for key, _image, pinned, store_v in c.drift:
        print(f"  DRIFT {key}: pinned {pinned} -> store {store_v}")


def apply_pins(pins: dict, drift: list[tuple[str, str, str, str]]) -> None:
    """Rewrite ONLY the drifted version strings, then serialise canonically.

    The serialisation is json.dumps(indent=2)+"\\n" — identical to
    scripts/check-addon-pins.py, and proven byte-idempotent on this file, so key
    order and formatting are preserved and only the version strings that drifted
    actually change.
    """
    for key, _image, _pinned, store_v in drift:
        pins["addons"][key]["version"] = store_v
    PINS.write_text(json.dumps(pins, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def update_marker(marker: str) -> None:
    """Replace ONLY the version token on the ``gaos_release:`` line.

    Everything else on the line — the ``gaos_release:`` key, the spacing, and the
    long human-written trailing comment — is kept byte-for-byte, so the operator
    edits the comment afterwards rather than having it clobbered.
    """
    if not MARKER_FMT_RE.match(marker):
        raise SystemExit(
            f"error: --marker {marker!r} does not look like a BOS release marker "
            f"(expected e.g. BOSv1.3.0-rc15 or BOSv1.3.0). Refusing to stamp it — "
            f"a bad marker is exactly the typo this tool exists to stop."
        )
    text = VERSION_YAML.read_text(encoding="utf-8")
    matches = list(MARKER_LINE_RE.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f"error: expected exactly one 'gaos_release:' line in {VERSION_YAML}, "
            f"found {len(matches)} — refusing to guess which to edit."
        )
    m = matches[0]
    old = m.group("ver")
    if old == marker:
        print(f"gaos_release already {marker} — nothing to stamp")
        return
    new_line = f"{m.group('pre')}{marker}{m.group('post')}"
    text = text[: m.start()] + new_line + text[m.end():]
    VERSION_YAML.write_text(text, encoding="utf-8")
    print(f"stamped gaos_release: {old} -> {marker} (trailing comment left for you to edit)")


def clone_store() -> pathlib.Path:
    """Shallow-clone the store the same way the gate does. Caller cleans up."""
    if shutil.which("git") is None:
        raise SystemExit("error: git is required to clone the store (or pass --store PATH)")
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="repin-store-"))
    dest = tmp / "vibe_addons"
    print(f"cloning store {STORE_URL} @ {STORE_REF} …")
    proc = subprocess.run(
        ["git", "clone", "--depth=1", "--quiet", "--branch", STORE_REF, STORE_URL, str(dest)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        shutil.rmtree(tmp, ignore_errors=True)
        raise SystemExit(
            f"error: could not clone {STORE_URL} @ {STORE_REF}: {proc.stderr.strip()}\n"
            f"       pass --store PATH to use a local checkout instead."
        )
    return dest


EXPECTED_GEN = REPO_ROOT / "tests" / "ga_tests" / "os_integrity" / "gen_expected.sh"


def regenerate_expectations() -> None:
    """Re-derive tests/ga_tests/os_integrity/expected.env from the pins.

    Best-effort by design: a repin must not fail because the generator is
    missing (it is not present in every checkout shape), but a generator that
    is present and fails is reported, because a silently stale declaration is
    exactly the failure this exists to prevent.
    """
    if not EXPECTED_GEN.is_file():
        print(f"\nnote: {EXPECTED_GEN.name} not found — expected.env not regenerated")
        return
    result = subprocess.run(["bash", str(EXPECTED_GEN)], capture_output=True, text=True)
    if result.returncode == 0:
        print("\nregenerated tests/ga_tests/os_integrity/expected.env from the new pins")
    else:
        print(f"\nWARNING: {EXPECTED_GEN.name} failed ({result.returncode}) — "
              f"expected.env may be stale; run it by hand:\n{result.stderr.strip()[:400]}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="Repin addon-images.json to the vibe_addons store, and stamp the rc marker.",
    )
    ap.add_argument("--check", action="store_true",
                    help="audit only: exit non-zero and name any drift, write nothing")
    ap.add_argument("--marker", metavar="BOSv1.3.0-rcN",
                    help="also stamp version.yaml gaos_release with this marker")
    ap.add_argument("--store", metavar="PATH",
                    help="path to a local vibe_addons checkout (default: clone it)")
    args = ap.parse_args(argv)

    if args.check and args.marker:
        ap.error("--check is read-only and --marker writes; use one or the other")

    if not PINS.is_file():
        print(f"error: {PINS} does not exist", file=sys.stderr)
        return 1

    # Resolve the store: an explicit checkout, or a fresh clone we clean up.
    cloned: pathlib.Path | None = None
    if args.store:
        store_root = pathlib.Path(args.store)
        if not store_root.is_dir():
            print(f"error: --store {store_root} is not a directory", file=sys.stderr)
            return 1
    else:
        cloned = clone_store()
        store_root = cloned

    try:
        store_index, duplicates = store_image_index(store_root)
        if not store_index:
            print(f"error: no add-on entries found under {store_root} — "
                  f"refusing to report success over an empty store")
            return 1
        if duplicates:
            print("error: the store has add-ons that share an image: field, so a pin "
                  "cannot be mapped unambiguously:")
            for d in duplicates:
                print(f"  {d}")
            return 1

        pins = json.loads(PINS.read_text(encoding="utf-8"))
        total_pins = len(pins.get("addons") or {})
        if total_pins == 0:
            print(f"error: {PINS} declares no add-ons — refusing to report success")
            return 1

        c = compare(pins, store_index)
        print_report(c, total_pins, len(store_index))

        if c.compared == 0:
            print("error: not a single pin could be compared to the store — "
                  "refusing to report success")
            return 1

        # A pin with no store entry is fail-closed in BOTH modes: the enforcing
        # gate FAILs on it ("has no matching addon in vibe_addons"), and repinning
        # a pin the store does not carry is impossible. Never silently skip it —
        # that silent skip is exactly how sonoff went unchecked for months.
        if c.missing:
            print(f"error: {len(c.missing)} pin(s) have no matching store entry — "
                  f"cannot verify or repin them (see NO STORE ENTRY above)")
            return 1

        if args.check:
            if c.drift:
                print(f"\nFAIL: {len(c.drift)} add-on(s) out of lockstep with the store. "
                      f"Run scripts/repin-addons.py (no --check) to bring the pins to the "
                      f"store version, then commit.")
                return 1
            print("\nOK: every pin is in lockstep with the store (or deliberately on a release "
                  "while the store carries a canary).")
            return 0

        # Default mode: write.
        if c.drift:
            apply_pins(pins, c.drift)
            print(f"\nrepinned {len(c.drift)} add-on(s) in {PINS}:")
            for key, _image, pinned, store_v in c.drift:
                print(f"  {key}: {pinned} -> {store_v}")
        else:
            print("\naddon-images.json already in lockstep with the store — no pin changed")

        if args.marker:
            update_marker(args.marker)

        # The device suite holds a flashed device against these same pins and
        # the release marker, from a file generated repo-side
        # (tests/ga_tests/os_integrity/expected.env). Moving a pin without
        # regenerating it makes the suite accuse a correct device: on the fresh
        # rc23 flash of K31 (2026-09-04) a stale expected.env produced three
        # OSI failures against a device that matched its image exactly. So the
        # tool that moves the pins also moves the declaration.
        if c.drift or args.marker:
            regenerate_expectations()
        return 0
    finally:
        if cloned is not None:
            shutil.rmtree(cloned.parent, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
