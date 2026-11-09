#!/usr/bin/env python3
"""check-data-root.py — no OS file may hard-code Supervisor's add-on data root.

Supervisor 2025.11 keeps add-on data under /mnt/data/supervisor/addons/data,
2026.10+ under /mnt/data/supervisor/apps/data (Odoo #1610). The one place that
knows is buildroot-external/rootfs-overlay/usr/libexec/ga-data-root.sh; every
other shipped file must ask it. Exception: systemd .path units cannot call a
resolver, so they must name BOTH variants of every path they watch.

Usage: check-data-root.py ROOT [ROOT...]   (each ROOT is scanned recursively)
Exit 0 clean, 1 violations, 2 nothing inspected (a scan over zero files is a
failure, not a pass).
"""
import os
import re
import sys

PAT = re.compile(r"supervisor/(?:addons|apps)\b|\baddons/data\b|\bapps/data\b")
RESOLVER = "ga-data-root.sh"


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
                    lines = open(p, encoding="utf-8").read().split("\n")
                except (UnicodeDecodeError, OSError):
                    continue  # binary
                inspected += 1
                hits = [(i + 1, l) for i, l in enumerate(lines)
                        if PAT.search(l) and not l.lstrip().startswith("#")]
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
