#!/usr/bin/env python3
"""jq regex-builtin gate (Odoo #1720).

The image builds jq 1.7.1 WITHOUT oniguruma (BR2_PACKAGE_JQ=y, no BR2_PACKAGE_ONIGURUMA in
buildroot-ihost/configs/ga_ihost_full_defconfig and buildroot-dsgw210/configs/dsgw210_defconfig),
so every regex builtin (test, match, capture, scan, splits, sub, gsub, 2-arg split/2) exits 5 on
the device while working on every laptop and CI runner. The extraction/lexing approach is ported
from greenautarky/ga-bootstrap tests/test_jq_lint.py.

WHAT IS SCANNED (the files installed into the image that runs on the device):
  - buildroot-external/rootfs-overlay/**                  (GA layer overlay, both boards)
  - buildroot-ihost/rootfs-overlay/**                     (iHost board overlay)
  - buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay/** (DSGW210 board overlay)
  - buildroot-{external,ihost,dsgw210}/package/** except external/package/hassio/ (installed units/scripts)
  - buildroot-external/patches-haos/0130-ga-supervisor-launcher.patch (the launcher that runs on
    the device; only context + added lines are scanned)
NOT SCANNED (jq runs on the BUILDER there, where jq has oniguruma, regex is fine):
  buildroot-external/package/hassio/** (check-supervisor-image.sh, check-core-image.sh: build host),
  patches-haos/0131/0133/0134 (Makefile/bake recipes), scripts/** (check-images.sh, scan-cves.sh...).
  Add a path to EXCLUDED below only with a reason.

Reads the LIVE tree, never a copy. FAILS (never skips) if it finds fewer than MIN_PROGRAMS jq
programs or MIN_FILES scanned files, or if any jq token cannot be attributed to a program.
Usage: lint.py [--root DIR]   |   lint.py --file F...  (lint given files, print findings)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

_REGEX_BUILTIN = re.compile(r'(?<![\w$.])(test|match|capture|scan|splits|sub|gsub)\s*\(')
_SPLIT2 = re.compile(r'(?<![\w$.])split\s*\([^()]*;')
# jq options that consume N following words
_OPT_ARGS = {"--arg": 2, "--argjson": 2, "--slurpfile": 2, "--rawfile": 2,
             "--indent": 1, "-L": 1, "--seq": 0}
_FROM_FILE = {"-f", "--from-file"}
# pinned: real jq programs in the live script (addon_repo_present, step 1a,
# parse check, creds host list + username + password, version, protected, state).
# Update deliberately when a jq call is added or removed.

TRUNCATED = "<<shell-quote-truncated-program>>"


def _lex(text: str):
    """Tiny shell lexer. Yields ("op", str) or ("word", segs) where segs is a
    list of (kind, text) with kind in {"s" single-quoted, "d" double-quoted,
    "u" unquoted}. Comments are skipped only where a shell skips them (a '#'
    at the start of a word outside quotes), so '#' inside a quoted jq program
    is NOT treated as a shell comment and an apostrophe in a jq comment
    closes the quote exactly as the real shell would."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t":
            i += 1
        elif c == "\\" and text[i + 1:i + 2] == "\n":
            i += 2
        elif c == "#":
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("$(", i):
            yield ("op", "$(")
            i += 2
        elif c in "\n|;&()<>":
            yield ("op", c)
            i += 1
        else:
            segs, buf = [], ""
            while i < n and text[i] not in " \t\n|;&()<>":
                c = text[i]
                if c == "'" or c == '"':
                    if buf:
                        segs.append(("u", buf))
                        buf = ""
                    e = i + 1
                    while e < n and text[e] != c:
                        e += 2 if (c == '"' and text[e] == "\\") else 1
                    segs.append(("s" if c == "'" else "d", text[i + 1:e]))
                    i = e + 1
                elif c == "\\":
                    buf += text[i:i + 2]
                    i += 2
                elif text.startswith("$(", i):
                    break
                else:
                    buf += c
                    i += 1
            if buf:
                segs.append(("u", buf))
            if segs:
                yield ("word", segs)


def _is_jq(segs) -> bool:
    plain = "".join(t for _, t in segs)
    return plain in ("jq", "$JQ_CLI", "${JQ_CLI}") or _is_jq_path(segs)


_CMD_PREFIX = {"if", "while", "until", "!", "env", "then", "do", "elif", "else", "time", "exec"}
UNLINTED = "<<jq-call-the-lint-cannot-attribute-to-a-program>>"


def jq_programs(text: str) -> list[str]:
    """Program text of each jq invocation. Command position = start of a
    command, after an operator (| ; & && || $( newline) or after
    if/while/until/!/env/then/do/... Programs may be single- or double-quoted.
    A program whose shell quote is closed early (apostrophe in a jq comment)
    gets a TRUNCATED marker. ANY other jq token (not at command position, -f
    file, unquoted/variable program, no program) yields an UNLINTED marker, so
    an unlinted jq call is red, never silently uncounted. Words in comments
    are not tokens at all."""
    toks = list(_lex(text))
    progs = []
    cmd_pos = True
    k = 0
    while k < len(toks):
        kind, val = toks[k]
        if kind == "word" and _is_jq(val):
            if not cmd_pos:
                # `command -v jq` / `which jq` / `type jq` only look the binary up, no program
                prev = [("".join(t for _, t in x[1]) if x[0] == "word" else x[1]) for x in toks[max(0, k - 3):k]]
                if (prev[-2:] == ["command", "-v"] or prev[-3:] == ["command", "-p", "-v"]
                        or prev[-1:] in (["which"], ["type"])):
                    k += 1
                    continue
                progs.append(UNLINTED)
                cmd_pos = False
                k += 1
                continue
            k += 1
            skip = 0
            found = False
            while k < len(toks) and toks[k][0] == "word":
                segs = toks[k][1]
                word = "".join(t for _, t in segs)
                if skip:
                    skip -= 1
                elif word in _FROM_FILE:
                    break
                elif word.startswith("-") and len(segs) == 1 and segs[0][0] == "u":
                    skip = _OPT_ARGS.get(word, 0)
                else:
                    if segs[0][0] in ("s", "d") and not (
                            len(segs) == 1 and segs[0][0] == "d"
                            and re.fullmatch(r"\$\{?\w+\}?", segs[0][1])):
                        prog = segs[0][1]
                        if len(segs) > 1 and segs[1][0] == "u" and segs[1][1][:1].isalnum():
                            prog += TRUNCATED
                        progs.append(prog)
                        found = True
                    break
                k += 1
            if not found:
                progs.append(UNLINTED)
            cmd_pos = False
            continue
        cmd_pos = kind == "op" or (
            kind == "word" and len(val) == 1 and val[0][0] == "u" and val[0][1] in _CMD_PREFIX)
        k += 1
    return progs


def violations(prog: str) -> list[str]:
    # drop jq comments (a '#' at line start or after whitespace)
    if prog == UNLINTED:
        return ["jq call the lint cannot attribute to a program (unlinted jq is red)"]
    if TRUNCATED in prog:
        return ["apostrophe closed the shell quote early (jq comment?)"]
    stripped = re.sub(r'(^|\s)#[^\n]*', r'\1', prog)
    return [m.group(0) for m in _REGEX_BUILTIN.finditer(stripped)] + \
           [m.group(0) for m in _SPLIT2.finditer(stripped)]




def _is_jq_path(segs) -> bool:  # absolute path to the binary counts as jq too
    plain = "".join(t for _, t in segs)
    return plain.endswith("/jq") and "=" not in plain


SCAN_GLOBS = [
    "buildroot-external/rootfs-overlay",
    "buildroot-ihost/rootfs-overlay",
    "buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay",
    "buildroot-external/package",
    "buildroot-ihost/package",
    "buildroot-dsgw210/package",
]
EXCLUDED = {
    # build-host only: jq with oniguruma on the builder, never installed into the image
    "buildroot-external/package/hassio",
}
PATCHES = ["buildroot-external/patches-haos/0130-ga-supervisor-launcher.patch"]
# Pinned from a measurement of the live tree (2026-11-10). Update deliberately when a device-side
# jq call or file is added/removed; a drop means the extraction went blind.
MIN_PROGRAMS = 21  # measured: 21 programs in 217 files
MIN_FILES = 200


def read_text(p: Path, patch: bool = False):
    try:
        t = p.read_bytes().decode("utf-8")
    except UnicodeDecodeError:
        return None
    if patch:  # keep context and added lines, drop removed lines and headers
        t = "\n".join(l[1:] for l in t.splitlines() if l[:1] in (" ", "+") and not l.startswith("+++"))
    return t


def lint_text(text: str):
    progs = jq_programs(text)
    return len(progs), [v for p in progs for v in violations(p)]


def scan(root: Path):
    files = []
    for g in SCAN_GLOBS:
        base = root / g
        for p in sorted(base.rglob("*")):
            rel = p.relative_to(root).as_posix()
            if p.is_symlink() or not p.is_file():
                continue
            if any(rel == e or rel.startswith(e + "/") for e in EXCLUDED):
                continue
            files.append((rel, p, False))
    files += [(x, root / x, True) for x in PATCHES]
    nprog, nfiles, bad = 0, 0, []
    for rel, p, patch in files:
        t = read_text(p, patch)
        if t is None:
            continue
        nfiles += 1
        n, v = lint_text(t)
        nprog += n
        bad += [f"{rel}: {x}" for x in v]
    return nfiles, nprog, bad


def main(argv):
    if argv[:1] == ["--file"]:
        rc = 0
        for f in argv[1:]:
            n, bad = lint_text(Path(f).read_text())
            print(f"{f}: programs={n} violations={bad}")
            if n < 1:
                rc = 1
            if bad:
                rc = 1
        return rc
    root = Path(argv[1]) if argv[:1] == ["--root"] else Path(__file__).resolve().parents[3]
    nfiles, nprog, bad = scan(root)
    print(f"scanned files={nfiles} jq programs={nprog} violations={len(bad)}")
    for b in bad:
        print(f"  VIOLATION {b}")
    if nprog < MIN_PROGRAMS or nfiles < MIN_FILES:
        print(f"FAIL: extraction blind (programs {nprog} < {MIN_PROGRAMS} or files {nfiles} < {MIN_FILES})")
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
