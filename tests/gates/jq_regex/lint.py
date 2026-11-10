#!/usr/bin/env python3
"""jq regex-builtin gate (Odoo #1720).

The image builds jq 1.7.1 WITHOUT oniguruma (BR2_PACKAGE_JQ=y, no BR2_PACKAGE_ONIGURUMA in
buildroot-ihost/configs/ga_ihost_full_defconfig and buildroot-dsgw210/configs/dsgw210_defconfig),
so every regex builtin (test, match, capture, scan, splits, sub, gsub, 2-arg split/2) exits 5 on
the device while working on every laptop and CI runner. The shell-aware extraction is ported from
greenautarky/ga-bootstrap tests/test_jq_lint.py and extended: jq inside "$(...)" / backticks /
${..:-$(..)}, a command word that is or expands to jq ($JQ, "$JQ", ${JQ:-jq}, /usr/bin/jq),
brace groups, VAR=x prefixes, and jq string literals are lexed before comments are stripped.

SCANNED (installed into the image that runs on the device), see SCAN_DIRS / PATCHES:
  buildroot-external/rootfs-overlay (both boards), buildroot-ihost/rootfs-overlay,
  buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay, buildroot-{external,ihost,dsgw210}/package
  except external/package/hassio, and patch 0130 (the supervisor launcher, runs on the device;
  context + added lines only). Read: the board dirs' other files (post-fakeroot.sh, haos-hook.sh,
  post-build.d, indicator*.py) run on the BUILDER or contain no jq; the completeness check below
  makes any future jq there a failure instead of a silent miss.

CHECKS (all fail closed):
  1. every regex builtin in a jq program;  2. any jq token that cannot be attributed to a program;
  3. PER FILE: a scanned file that mentions jq (outside comments) but yields no attributed program
     and no lookup (`command -v jq`) fails, unless listed in ALLOW_MENTION with a reason;
     non-shell files (python/perl/lua) that mention jq fail unless listed in ALLOW_NONSHELL;
  4. PER FILE pinned program counts (EXPECTED_PROGRAMS): going blind on one file is red, and a
     new jq call must be added to the table deliberately;
  5. COMPLETENESS: every file in the repo that mentions jq is either scanned or classified in
     NOT_DEVICE with a reason (a new jq user under board/, scripts/, post-build.d fails here);
  6. totals: MIN_FILES scanned files.
Reads the LIVE tree. Usage: lint.py [--root DIR] | lint.py --file F...
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

SCAN_DIRS = [
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

# Everything else in the repo that mentions jq, and why it is not device-side. Prefix match.
NOT_DEVICE = {
    "buildroot-external/package/hassio/": "runs on the builder (image checks)",
    "buildroot-external/patches-haos/0131-": "bake recipe, runs on the builder",
    "buildroot-external/patches-haos/0133-": "Makefile recipe, runs on the builder",
    "buildroot-external/patches-haos/0134-": "Makefile recipe, runs on the builder",
    "patches/haos/": "patches to hassio build scripts, run on the builder",
    "scripts/": "build host / CI tooling (check-images.sh, scan-cves.sh, ...)",
    "Dockerfile": "build-container definition, installs jq for the builder",
    "docs/": "prose",
    "CHANGELOG.md": "prose",
    "version.yaml": "prose / comments",
}
SKIP_WALK = {".git", "haos", "buildroot", "tests", ".github", "node_modules", "output"}

# Scanned files that mention jq outside comments but legitimately have no program. Reason each.
ALLOW_MENTION: dict[str, str] = {}
# Non-shell scanned files that mention jq, after reading them. Reason each.
ALLOW_NONSHELL: dict[str, str] = {}

# Pinned per-file jq program counts in the scanned set (measured 2026-11-10).
EXPECTED_PROGRAMS: dict[str, int] = {
    "buildroot-external/patches-haos/0130-ga-supervisor-launcher.patch": 4,
    "buildroot-external/rootfs-overlay/usr/libexec/ga-enroll": 8,
    "buildroot-external/rootfs-overlay/usr/libexec/ga-ha-init": 1,
    "buildroot-external/rootfs-overlay/usr/sbin/ga-addon-prime": 1,
    "buildroot-external/rootfs-overlay/usr/libexec/ga-host-stats": 1,
    "buildroot-external/rootfs-overlay/usr/libexec/ga-rauc-slots": 11,
    "buildroot-external/rootfs-overlay/usr/sbin/ga-mesh-watchdog": 3,
    "buildroot-external/rootfs-overlay/usr/sbin/ga-telemetry-profile-apply": 1,
}
MIN_FILES = 200

_REGEX_BUILTIN = re.compile(r'(?<![\w$.])(test|match|capture|scan|splits|sub|gsub)\s*\(')
_SPLIT2 = re.compile(r'(?<![\w$.])split\s*\([^()]*;')
_OPT_ARGS = {"--arg": 2, "--argjson": 2, "--slurpfile": 2, "--rawfile": 2,
             "--indent": 1, "-L": 1, "--seq": 0}
_FROM_FILE = {"-f", "--from-file"}
TRUNCATED = "<<shell-quote-truncated-program>>"
UNLINTED = "<<jq-call-the-lint-cannot-attribute-to-a-program>>"
_CMD_PREFIX = {"if", "while", "until", "!", "env", "then", "do", "elif", "else", "time", "exec", "{"}
_JQVAR = re.compile(r'^\$\{?\w*[jJ][qQ]\w*(:?[-=+?][^}]*)?\}?$')
_WRAPPERS = {"xargs", "nohup", "sudo", "timeout", "nice", "setsid", "stdbuf", "command", "busybox"}
_WORDBREAK = " \t\n|;&()<>`"


def _lex(text: str):
    """Tiny shell lexer: ("op", str) or ("word", segs), segs = [(kind, text)], kind in
    s (single-quoted) / d (double-quoted) / u (unquoted). Comments are skipped only where a shell
    skips them (a '#' starting a word outside quotes)."""
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
        elif c in "\n|;&()<>`":
            yield ("op", c)
            i += 1
        else:
            segs, buf = [], ""
            while i < n and text[i] not in _WORDBREAK:
                c = text[i]
                if c == "'" or c == '"':
                    if buf:
                        segs.append(("u", buf))
                        buf = ""
                    e = i + 1
                    while e < n and text[e] != c:
                        if c == '"' and text.startswith("$(", e):
                            e = _skip_sub(text, e)
                        elif c == '"' and text[e] == "`":
                            e = _skip_tick(text, e)
                        else:
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


def _skip_sub(s: str, i: int) -> int:
    """s[i:] starts with '$(': index just after the balanced ')' (quotes respected)."""
    depth, j, q, n = 1, i + 2, "", len(s)
    while j < n and depth:
        ch = s[j]
        if q:
            if ch == "\\" and q == '"':
                j += 1
            elif ch == q:
                q = ""
        elif ch in "'\"":
            q = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        j += 1
    return j


def _skip_tick(s: str, i: int) -> int:
    j = i + 1
    while j < len(s) and s[j] != "`":
        j += 2 if s[j] == "\\" else 1
    return j + 1


def _subs(s: str) -> list[str]:
    """Command substitutions inside double-quoted text: $( ... ) (balanced) and `...`."""
    out, i, n = [], 0, len(s)
    while i < n:
        if s.startswith("$(", i):
            j = _skip_sub(s, i)
            out.append(s[i + 2:j - 1])
            i = j
        elif s[i] == "`":
            j = _skip_tick(s, i)
            out.append(s[i + 1:j - 1])
            i = j
        elif s[i] == "\\":
            i += 2
        else:
            i += 1
    return out


def _is_jq(segs) -> bool:
    plain = "".join(t for _, t in segs)
    return plain in ("jq",) or plain.endswith("/jq") and "=" not in plain


def _is_jqvar(segs) -> bool:
    return bool(_JQVAR.match("".join(t for _, t in segs)))


def analyze(text: str):
    """-> (programs, lookups, mentions). programs: jq program text per invocation (UNLINTED /
    TRUNCATED markers for ones that cannot be attributed); lookups: `command -v jq` style;
    mentions: words outside comments that contain the token jq."""
    toks = list(_lex(text))
    progs: list[str] = []
    lookups = mentions = 0
    for kind, val in toks:  # command substitutions inside double quotes / backticks
        if kind != "word":
            continue
        if re.search(r'\bjq\b', "".join(t for _, t in val)):
            mentions += 1
        for sk, st in val:
            if sk == "d":
                for sub in _subs(st):
                    p, l, m = analyze(sub)
                    progs += p
                    lookups += l
                    mentions += m
    cmd_pos = True
    k = 0
    while k < len(toks):
        kind, val = toks[k]
        wrapped = (k > 0 and toks[k - 1][0] == "word"
                   and "".join(t for _, t in toks[k - 1][1]) in _WRAPPERS)
        if kind == "word" and (_is_jq(val) or ((cmd_pos or wrapped) and _is_jqvar(val))):
            if not cmd_pos:
                prev = [("".join(t for _, t in x[1]) if x[0] == "word" else x[1]) for x in toks[max(0, k - 3):k]]
                if (prev[-2:] == ["command", "-v"] or prev[-3:] == ["command", "-p", "-v"]
                        or prev[-1:] in (["which"], ["type"])):
                    lookups += 1
                else:
                    progs.append(UNLINTED)
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
                        if segs[0][0] == "d":
                            prog = re.sub(r'\\(["\\$`])', r'\1', prog)
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
        cmd_pos = kind == "op" or (kind == "word" and (
            (len(val) == 1 and val[0][0] == "u" and (val[0][1] in _CMD_PREFIX
                                                     or re.fullmatch(r"\w+=\S*", val[0][1])))))
        k += 1
    return progs, lookups, mentions


def jq_programs(text: str) -> list[str]:
    return analyze(text)[0]


def strip_jq(s: str) -> str:
    """Lex jq strings BEFORE dropping comments: '#' inside a string is not a comment, and
    string contents (regex names inside a literal) are blanked. \\( ... ) interpolation is code."""
    out: list[str] = []
    n = len(s)

    def code(i: int, depth: int) -> int:
        paren = 0
        while i < n:
            c = s[i]
            if c == '"':
                out.append('"')
                i = string(i + 1)
                out.append('"')
            elif c == "#":
                while i < n and s[i] != "\n":
                    i += 1
            elif depth and c == "(":
                paren += 1
                out.append(c)
                i += 1
            elif depth and c == ")":
                if paren == 0:
                    return i + 1
                paren -= 1
                out.append(c)
                i += 1
            else:
                out.append(c)
                i += 1
        return i

    def string(i: int) -> int:
        while i < n:
            c = s[i]
            if c == "\\":
                if s[i + 1:i + 2] == "(":
                    out.append(" ")
                    i = code(i + 2, 1)
                    out.append(" ")
                    continue
                i += 2
            elif c == '"':
                return i + 1
            else:
                i += 1
        return i

    code(0, 0)
    return "".join(out)


def violations(prog: str) -> list[str]:
    if prog == UNLINTED:
        return ["jq call the lint cannot attribute to a program (unlinted jq is red)"]
    if TRUNCATED in prog:
        return ["apostrophe closed the shell quote early (jq comment?)"]
    code = strip_jq(prog)
    return [m.group(0) for m in _REGEX_BUILTIN.finditer(code)] + \
           [m.group(0) for m in _SPLIT2.finditer(code)]


def _nonshell(text: str, rel: str) -> bool:
    first = text.split("\n", 1)[0]
    if rel.endswith((".py", ".pl", ".lua", ".js", ".rb")):
        return True
    if first.startswith("#!") and re.search(r"python|perl|lua|node|ruby", first):
        return True
    return bool(re.match(r"#\s*lint-kind:\s*python", first))  # fixtures carry no shebang


def lint_file(text: str, rel: str, patch: bool = False):
    """-> (n_programs, [violation strings]) including the per-file coverage rule."""
    if patch:  # keep context and added lines, drop removed lines and headers
        text = "\n".join(l[1:] for l in text.splitlines() if l[:1] in (" ", "+") and not l.startswith("+++"))
    if _nonshell(text, rel):
        if re.search(r"\bjq\b", text) and rel not in ALLOW_NONSHELL:
            return 0, ["non-shell file mentions jq; cannot be linted (read it, then list it in ALLOW_NONSHELL)"]
        return 0, []
    progs, lookups, mentions = analyze(text)
    bad = [v for p in progs for v in violations(p)]
    if mentions and not progs and not lookups and rel not in ALLOW_MENTION:
        bad.append("mentions jq but no jq program was attributed (lint blind, or list in ALLOW_MENTION)")
    return len(progs), bad


def read_text(p: Path):
    try:
        return p.read_bytes().decode("utf-8")
    except UnicodeDecodeError:
        return None


def scan(root: Path):
    files = []
    for g in SCAN_DIRS:
        for p in sorted((root / g).rglob("*")):
            rel = p.relative_to(root).as_posix()
            if p.is_symlink() or not p.is_file():
                continue
            if any(rel == e or rel.startswith(e + "/") for e in EXCLUDED):
                continue
            files.append((rel, p, False))
    files += [(x, root / x, True) for x in PATCHES]
    scanned = {r for r, _, _ in files}
    counts: dict[str, int] = {}
    bad: list[str] = []
    nfiles = 0
    for rel, p, patch in files:
        t = read_text(p)
        if t is None:
            continue
        nfiles += 1
        n, v = lint_file(t, rel, patch)
        if n:
            counts[rel] = n
        bad += [f"{rel}: {x}" for x in v]
    for rel in sorted(set(counts) | set(EXPECTED_PROGRAMS)):
        if counts.get(rel, 0) != EXPECTED_PROGRAMS.get(rel, 0):
            bad.append(f"{rel}: expected {EXPECTED_PROGRAMS.get(rel, 0)} jq programs, found "
                       f"{counts.get(rel, 0)} (update EXPECTED_PROGRAMS deliberately, or the lint went blind)")
    # completeness: every jq-mentioning file in the repo is scanned or classified
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_WALK]
        for f in fn:
            p = Path(dp) / f
            rel = p.relative_to(root).as_posix()
            if p.is_symlink() or rel in scanned or p.stat().st_size > 2_000_000:
                continue
            if any(rel.startswith(g + "/") for g in SCAN_DIRS) and not any(
                    rel == e or rel.startswith(e + "/") for e in EXCLUDED):
                continue
            t = read_text(p)
            if t and re.search(r"\bjq\b", t) and not any(rel.startswith(k) for k in NOT_DEVICE):
                bad.append(f"{rel}: mentions jq, is neither scanned nor classified in NOT_DEVICE "
                           "(device-side? add its dir to SCAN_DIRS; builder-side? classify with a reason)")
    return nfiles, counts, bad


def main(argv):
    if argv[:1] == ["--file"]:
        rc = 0
        for f in argv[1:]:
            n, bad = lint_file(Path(f).read_text(), Path(f).name)
            print(f"{f}: programs={n} violations={bad}")
            rc |= 1 if bad else 0
        return rc
    root = Path(argv[1]) if argv[:1] == ["--root"] else Path(__file__).resolve().parents[3]
    nfiles, counts, bad = scan(root)
    print(f"scanned files={nfiles} jq programs={sum(counts.values())} violations={len(bad)}")
    for rel in sorted(counts):
        print(f"  {counts[rel]:3d}  {rel}")
    for b in bad:
        print(f"  VIOLATION {b}")
    if nfiles < MIN_FILES:
        print(f"FAIL: extraction blind (files {nfiles} < {MIN_FILES})")
        return 1
    if not EXPECTED_PROGRAMS:
        print("FAIL: EXPECTED_PROGRAMS is empty")
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
