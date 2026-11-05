#!/usr/bin/env python3
"""check-ihost-iodomains.py — the iHost I/O voltage domains match what Sonoff ships.

Each RV1126 I/O bank is told by the DT which regulator feeds it. A wrong value
programs the pad for the wrong voltage: VCCIO5 (Ethernet RGMII/MDIO) was
declared 1.8 V for months while the board feeds 3.3 V (finding 2026-11-03).

Two DTs carry the same truth — the Linux DT and the U-Boot DT — and they had
drifted apart. This check holds BOTH against one pinned constant taken from the
vendor DT read off a never-provisioned iHost's eMMC (stock-emmc-dump.sh,
2026-11-05, model rockchip,rv1126-evb-ddr3-v13). The expectation is a constant,
never derived from the files it checks.

  check-ihost-iodomains.py              check the live tree (exit 1 on drift)
  check-ihost-iodomains.py --selftest   prove it flags a mutated copy and passes the live one

A missing pmu_io_domains block FAILS (never skips): a check that finds nothing
to compare is not green.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Vendor DT (Sonoff stock eMMC, 2026-11-05), phandles resolved to regulator labels.
STOCK = {
    "pmuio0": "vcc3v3_sys",
    "pmuio1": "vcc3v3_sys",
    "vccio1": "vcc_1v8",
    "vccio2": "vccio_sd",
    "vccio3": "vcc_3v3",
    "vccio4": "vcc_3v3",
    "vccio5": "vcc_3v3",
    "vccio6": "vcc_3v3",
    "vccio7": "vcc_1v8",
}

# (path, side) — side "+" reads the added lines of a patch, "" a plain file.
SOURCES = [
    ("tests/ga_tests/build/reference/rv1126-sonoff-ihost.dtsi.expected", ""),
    ("buildroot-ihost/board/sonoff/ihost/patches/uboot/0001-arm-rockchip-rv1126-Sync-DT-from-linux.patch", "+"),
]


def domains(text: str, side: str) -> dict[str, str] | None:
    lines = []
    for ln in text.splitlines():
        if side:
            if not ln.startswith(side) or ln.startswith(side * 3):
                continue
            ln = ln[1:]
        lines.append(ln)
    body = "\n".join(lines)
    m = re.search(r"&pmu_io_domains\s*\{(.*?)\n\s*\};", body, re.S)
    if not m:
        return None
    return dict(re.findall(r"(\w+)-supply\s*=\s*<&(\w+)>;", m.group(1)))


def check(texts: dict[str, str]) -> list[str]:
    errs = []
    for path, side in SOURCES:
        got = domains(texts[path], side)
        if got is None:
            errs.append(f"{path}: no &pmu_io_domains block found — refusing to pass over nothing")
            continue
        for dom, want in STOCK.items():
            if got.get(dom) != want:
                errs.append(f"{path}: {dom}-supply = {got.get(dom)!r}, stock DT says {want!r}")
    return errs


def live() -> dict[str, str]:
    return {p: (ROOT / p).read_text() for p, _ in SOURCES}


def selftest() -> int:
    texts = live()
    ok = True
    if check(texts):
        print("SELFTEST FAIL: the live tree does not pass"); ok = False
    for path, _ in SOURCES:
        bad = dict(texts)
        bad[path] = texts[path].replace("vccio5-supply = <&vcc_3v3>;", "vccio5-supply = <&vcc_1v8>;", 1)
        if bad[path] == texts[path] or not any("vccio5" in e and path in e for e in check(bad)):
            print(f"SELFTEST FAIL: a 1.8 V VCCIO5 in {path} is not flagged"); ok = False
        gone = dict(texts)
        gone[path] = texts[path].replace("&pmu_io_domains", "&pmu_io_gone")
        if not any("no &pmu_io_domains" in e for e in check(gone)):
            print(f"SELFTEST FAIL: a missing block in {path} is not flagged"); ok = False
    print("selftest:", "ok" if ok else "FAILED")
    return 0 if ok else 1


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    errs = check(live())
    for e in errs:
        print("FAIL:", e)
    if not errs:
        print(f"ok: {len(SOURCES)} DTs × {len(STOCK)} domains match the stock iHost DT")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
