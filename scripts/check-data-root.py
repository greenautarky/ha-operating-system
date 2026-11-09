#!/usr/bin/env python3
"""check-data-root.py — no OS file may hard-code Supervisor's add-on data root.

Supervisor 2025.11 keeps add-on data under /mnt/data/supervisor/addons/data,
2026.10+ under /mnt/data/supervisor/apps/data (Odoo #1610). The one place that
knows is buildroot-external/rootfs-overlay/usr/libexec/ga-data-root.sh; every
other shipped file must ask it. Exception: systemd .path units cannot call a
resolver, so they must name BOTH variants of every path they watch.

Scope (see tests/gates/data_root/selftest.sh): the OS overlays, scripts/ and the
workflows. tests/ is exempt: it builds fake Supervisor trees to drive the resolver.
This file is skipped (it spells the patterns).

Limits: this is a regex heuristic against ACCIDENTAL regressions (contiguous,
variable-split, quote-split and continued spellings). It is not bypass-proof:
printf/array/brace-expansion/glob/`cd` + relative-path spellings are not caught
(independent review 2026-11-09). Review such constructs by hand.

Usage: check-data-root.py ROOT [ROOT...]   (each ROOT is scanned recursively)
Exit 0 clean, 1 violations, 2 nothing inspected (a scan over zero files is a
failure, not a pass).
"""
import os
import re
import sys

# Spellings of the hard-coded root, matched on the NORMALISED line (quotes removed,
# backslash-continuations joined, ${X} -> $X):
#  1. contiguous:            .../supervisor/addons  .../supervisor/apps  addons/data  apps/data
#  2. split by a variable:   SUP=/mnt/data/supervisor ; A=$SUP/addons     (also via a second
#                            variable assigned from the first)
#  3. variable as the dir:   B=apps ; X=/mnt/data/supervisor/$B/data
#  4. bare after a variable: $BASE/addons/data  $BASE/apps/data
PAT = re.compile(r"supervisor/(?:addons|apps)\b|\baddons/data\b|\bapps/data\b")
PAT_VARDIR = re.compile(r"supervisor/\$\w+/data\b")
ASSIGN = re.compile(r"(?:^|[\s;&|(])(?:export\s+|local\s+|readonly\s+)?(\w+)=(\S*)")
RESOLVER = "ga-data-root.sh"
SELF = os.path.realpath(__file__)


def normalise(text):
    """Join backslash-continued lines (keeping the first line's number), strip quotes."""
    out, cur, start = [], "", None
    for i, l in enumerate(text.split("\n")):
        if start is None:
            start = i + 1
        if l.endswith("\\"):
            cur += l[:-1]
            continue
        cur += l
        out.append((start, cur))
        cur, start = "", None
    if cur:
        out.append((start, cur))
    res = []
    for n, l in out:
        q = re.sub(r"['\"]", "", l)
        q = re.sub(r"\$\{(\w+)\}", r"$\1", q)
        res.append((n, l, q))
    return res


def supervisor_vars(lines):
    """Names assigned a value containing 'supervisor' or an already-known such name."""
    known, changed = set(), True
    while changed:
        changed = False
        for _, _, q in lines:
            for m in ASSIGN.finditer(q):
                name, val = m.group(1), m.group(2)
                if name in known:
                    continue
                if "supervisor" in val or any(re.search(r"\$" + re.escape(k) + r"\b", val) for k in known):
                    known.add(name)
                    changed = True
    return known


def violations(lines):
    """[(lineno, original line)] for every line that spells the data root."""
    known = supervisor_vars(lines)
    pats = [PAT, PAT_VARDIR, re.compile(r"\$\w+/(?:addons|apps)/data\b")]
    if known:
        alt = "|".join(re.escape(k) for k in sorted(known))
        pats.append(re.compile(r"\$(?:" + alt + r")/(?:addons|apps)\b"))
    return [(n, l) for n, l, q in lines
            if not l.lstrip().startswith("#") and any(p.search(q) for p in pats)]


def norm(line):
    return re.sub(r"supervisor/(?:addons|apps)/", "supervisor/@/", line.strip())


def scan(roots):
    findings, inspected = [], 0
    for root in roots:
        for d, _, names in os.walk(root):
            for n in names:
                p = os.path.join(d, n)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                try:
                    text = open(p, encoding="utf-8").read()
                except (UnicodeDecodeError, OSError):
                    continue  # binary
                if os.path.realpath(p) == SELF:
                    continue  # this file spells the patterns it looks for
                inspected += 1
                hits = violations(normalise(text))
                if not hits or n == RESOLVER:
                    continue
                if n.endswith(".path"):
                    kinds = {}
                    for i, l in hits:
                        w = "apps" if re.search(r"supervisor/apps/", l) else "addons"
                        kinds.setdefault(norm(l), {})[w] = i
                    for k, v in kinds.items():
                        for w in ("apps", "addons"):
                            if w not in v:
                                findings.append(f"{p}:{list(v.values())[0]}: .path unit watches only the {'addons' if w == 'apps' else 'apps'}/ variant of {k!r} (must name both)")
                else:
                    for i, l in hits:
                        findings.append(f"{p}:{i}: hard-coded Supervisor data root — use ga-data-root.sh: {l.strip()[:100]}")
    return findings, inspected


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    findings, inspected = scan(argv[1:])
    for f in findings:
        print(f)
    if inspected == 0:
        print("check-data-root: inspected 0 files — refusing to pass over nothing")
        return 2
    print(f"check-data-root: {inspected} files inspected, {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
