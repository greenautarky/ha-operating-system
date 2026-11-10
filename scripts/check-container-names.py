#!/usr/bin/env python3
"""check-container-names.py <path>... - fail on code/docs that name an add-on container
with the pre-2026.10 prefix `addon_`.

Supervisor 2026.10+ (BOSv1.6) names add-on containers app_<hash>_<slug>; addon_<hash>_<slug>
is BOSv1.5.x. Anything that spells `addon_` as a container name is blind on one of the two.
Use ga_ctr_of / ga_ctr_exact (tests/ga_tests/lib/test_helpers.sh) or the alternation `(app|addon)_`
(which contains no literal `addon_` and so never trips this gate).

Checked PER OCCURRENCE, on logical lines (backslash continuations joined). A line that
also mentions app_ does NOT excuse an addon_ on the same line. Shapes flagged:
  addon_<8 hex>_ / addon_x_ / addon_deadbeef_ / addon_core_   a concrete container name
  addon_ followed by space, quote, ) $ * . { < | \\ or end    a bare prefix (^addon_, grep addon_,
                                                              name=addon_, addon_$slug, addon_.*)
Not flagged: identifiers (addon_store_raw_url), REST/job names (addon_update), AppArmor profile
names (addon_x), `all_addon_configs` - an identifier continues with letters after `addon_`.
Whole-line `#` comments and trailing ` # ...` comments are ignored (prose). A line carrying
the marker `ga-ctr-ok` is excused (use only where BOTH prefixes are accepted on purpose).

rc 0 clean, 1 hits, 2 inspected nothing (fails closed).
"""
import os, re, sys

EXTS = (".sh", ".bash", ".py", ".md", ".service", ".conf", ".yml", ".yaml", ".patch")
# Builder/laptop-side files that legitimately keep `addon_` strings. NOTHING here runs on a
# device. Empty on purpose: add an entry (path suffix -> reason) rather than skipping a root.
ALLOW = {"scripts/check-container-names.py": "the gate itself documents the shapes"}

OCC = re.compile(
    r"(?<![A-Za-z0-9_])addon_(?:(?:[0-9a-f]{8}|x|deadbeef|core)_|(?=[\s\"')$*.{<|\\]|$))"
)


def logical_lines(path):
    buf, start = "", 0
    with open(path, errors="replace") as fh:
        for i, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not buf:
                start = i
            if line.endswith("\\"):
                buf += line[:-1] + " "
                continue
            yield start, buf + line
            buf = ""
    if buf:
        yield start, buf


def strip_comment(line, md):
    if md:
        return line
    if line.lstrip().startswith("#"):
        return ""
    return re.split(r"\s#\s", line, maxsplit=1)[0]


def scan(path):
    hits = []
    md = path.endswith(".md")
    for n, line in logical_lines(path):
        if "ga-ctr-ok" in line:
            continue
        code = strip_comment(line, md)
        if OCC.search(code):
            hits.append((n, line.strip()[:160]))
    return hits


def main(argv):
    files = []
    for root in argv:
        if os.path.isfile(root):
            files.append(root)
        elif os.path.isdir(root):
            for d, dn, fn in os.walk(root):
                dn[:] = [x for x in dn if x not in ("fixtures", "must-fail", "must-pass", ".git")]
                files += [os.path.join(d, f) for f in fn
                          if f.endswith(EXTS) or f.startswith("ga-")]
    files = [f for f in files if os.path.isfile(f) and not any(f.endswith(k) for k in ALLOW)]
    if not files:
        print("check-container-names: ERROR: inspected 0 files", file=sys.stderr)
        return 2
    bad = 0
    for f in sorted(files):
        for n, t in scan(f):
            print(f"{f}:{n}: {t}")
            bad += 1
    if bad:
        print(f"check-container-names: {bad} addon_ container-name use(s); BOSv1.6 uses app_*", file=sys.stderr)
        return 1
    print(f"check-container-names: {len(files)} file(s) clean")
    return 0


sys.exit(main(sys.argv[1:]))
