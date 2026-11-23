#!/usr/bin/env python3
"""pin_policy.py — the ONE definition of the add-on pin rules.

Used by scripts/repin-addons.py, scripts/check-addon-pins.py (import) and
scripts/check-images.sh (CLI below). Until 2026-11-23 the rules lived in three
places: check-images.sh honoured a declared ``store_ahead`` and
repin-addons.py --check did not, so the BOSv1.6.1-rc3 bake (ga-ops run
45225913542) was blocked by one script for a pin the other had accepted
(rule 61: two checks of one truth that disagree). Change a rule HERE only;
tests/gates/pin_policy/selftest.sh runs every consumer against it.

Rules
-----
* is_prerelease: a canary tag carries LETTERS after the first dash
  (``1.3.0-ga.1``); a numeric suffix is a release revision (``2.12.1-11``).
* store_ahead: a pin may be NEWER than the store when declared next to it,
  ``"store_ahead": {"reason": "...", "until": "YYYY-MM-DD"}``: a reason, a
  valid date, not past, at most MAX_DAYS ahead, and the pin really newer than
  the store. It never excuses a pin BEHIND the store.
* hold: a pin may stay BEHIND the newest published image when declared next
  to it, ``"hold": {"reason": "...", "until": "YYYY-MM-DD"}``, with the same
  window rules (reason; valid date; not past; at most MAX_DAYS ahead). Also
  read by ga-ops scripts/bake_precheck.py from the baked tree, so the bake's
  pre-check and the tree's own gate cannot disagree about a hold.
"""
from __future__ import annotations

import datetime
import json
import re
import sys

MAX_DAYS = 30
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def is_prerelease(version: str) -> bool:
    _, _, suffix = str(version).partition("-")
    return bool(suffix) and any(ch.isalpha() for ch in suffix)


def _key(version: str):
    # Same ordering as `sort -V` for our release tags (dotted numbers plus an
    # optional numeric revision): 2.12.1 < 2.12.1-11 < 2.12.1-12 < 2.12.2.
    parts = re.split(r"[.-]", str(version))
    return [(0, int(p)) if p.isdigit() else (1, p) for p in parts]


def is_newer(a: str, b: str) -> bool:
    """True when version a sorts strictly after version b."""
    return a != b and _key(a) > _key(b)


def _window(kind: str, decl, today: str | None):
    """The declaration rules shared by hold and store_ahead. None = valid, else why not."""
    if not isinstance(decl, dict):
        return f"{kind} is not an object"
    reason = str(decl.get("reason") or "").strip()
    until = str(decl.get("until") or "").strip()
    today_d = datetime.date.fromisoformat(today) if today else datetime.datetime.now(datetime.timezone.utc).date()
    if not reason:
        return f"{kind} has no reason"
    if not _DATE_RE.match(until):
        return f"{kind} until '{until}' is not YYYY-MM-DD"
    try:
        until_d = datetime.date.fromisoformat(until)
    except ValueError:
        return f"{kind} until '{until}' is not a valid date"
    if until_d < today_d:
        return f"{kind} expired on {until}"
    if until_d > today_d + datetime.timedelta(days=MAX_DAYS):
        return f"{kind} until {until} is more than {MAX_DAYS} days ahead"
    return None


def hold_verdict(entry: dict, today: str | None = None):
    """Return (declared, ok, why) for a pin held BEHIND the newest published image.

    Whether the pin really is behind is the caller's measurement (it lists the
    registry); this decides only whether the declaration excuses it.
    """
    h = entry.get("hold") if isinstance(entry, dict) else None
    if not h:
        return False, False, None
    why = _window("hold", h, today)
    return True, why is None, why


def store_ahead_verdict(entry: dict, pinned: str, store: str, today: str | None = None):
    """Return (declared, ok, why).

    declared=False: no store_ahead on this entry (why is None).
    declared=True, ok=True: the declaration excuses this pin.
    declared=True, ok=False: the declaration is invalid; why says why.
    """
    sa = entry.get("store_ahead") if isinstance(entry, dict) else None
    if not sa:
        return False, False, None
    why = _window("store_ahead", sa, today)
    if why:
        return True, False, why
    if not is_newer(str(pinned), str(store)):
        return True, False, f"store_ahead is declared but the pin is not newer than the store ({pinned} vs {store})"
    return True, True, None


def _main(argv: list[str]) -> int:
    """CLI for shell consumers.

    pin_policy.py is-prerelease VERSION              -> exit 0 yes / 1 no
    pin_policy.py store-ahead JSON KEY PINNED STORE   -> exit 0 ok; 1 not declared; 3 invalid (why on stdout)
    pin_policy.py hold JSON KEY                       -> exit 0 ok; 1 not declared; 3 invalid (why on stdout)
    GA_TODAY=YYYY-MM-DD overrides today (selftests only).
    """
    import os
    if len(argv) == 2 and argv[0] == "is-prerelease":
        return 0 if is_prerelease(argv[1]) else 1
    if (len(argv) == 5 and argv[0] == "store-ahead") or (len(argv) == 3 and argv[0] == "hold"):
        path, key = argv[1], argv[2]
        try:
            entry = (json.load(open(path)).get("addons") or {}).get(key) or {}
        except (OSError, ValueError) as e:
            print(f"cannot read {path}: {e}")
            return 2
        today = os.environ.get("GA_TODAY") or None
        if argv[0] == "hold":
            declared, ok, why = hold_verdict(entry, today)
        else:
            declared, ok, why = store_ahead_verdict(entry, argv[3], argv[4], today)
        if not declared:
            return 1
        if ok:
            return 0
        print(why)
        return 3
    print(_main.__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
