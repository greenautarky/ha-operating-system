#!/usr/bin/env python3
"""check.py — root host scripts write into the shared directory only through
ga-share-publish.

The Supervisor share directory (/mnt/data/supervisor/share on the host) is also
mounted into every add-on that declares `share:rw`. A path inside it can
therefore be replaced by something the host script did not create, including a
symlink. A shell redirect (`>`, `>>`, `N>`, `<>`) or a `tee`/`touch`/`cp`/`mv`
whose target lies in that directory opens or renames the path as it finds it.
The host has one primitive for publishing there — /usr/libexec/ga-share-publish,
which stages in a host-only directory and renames into place — and this gate
keeps every other write out.

What it inspects
    Every shell script (sh/bash shebang) under buildroot-*/rootfs-overlay and
    buildroot-*/package. A variable is "share-derived" when its assignment
    contains the literal share path, or references a share-derived variable
    (fixpoint, per file). A line is flagged when an output redirect, a
    `tee`/`touch` operand, or the destination of `cp`/`mv`/`ln`/`install`
    expands a share-derived variable or names the share path literally.

What it deliberately allows
    * reads (`< "$X"`, `[ -f "$X" ]`, `cat "$X"`) and `rm -f "$X"` — neither
      creates nor writes through a planted path;
    * ga-share-publish itself (its only redirect targets its host-only staging
      directory);
    * heredoc bodies and comments.

Known limit (stated, not hidden): taint does not follow function arguments
($1..$9) or values read at runtime. A helper that receives a share path as an
argument and writes it is not seen here; that is what the behavioural suite
tests/ga_tests/share_writers/ is for.

Usage
    check.py                    scan the live overlays of this repository
    check.py --root DIR         scan DIR as if it were the repository root
    check.py FILE...            scan exactly these files (fixtures)
Exit 0 = clean, 1 = findings, 2 = nothing to inspect / bad invocation.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

SHARE_LITERAL = "supervisor/share"
PUBLISHER_BASENAME = "ga-share-publish"
SCAN_GLOBS = ("buildroot-*/rootfs-overlay", "buildroot-*/package")

ASSIGN_RE = re.compile(r"^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
VARREF_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
# An output-capable redirect: optional fd, then >, >>, >|, <>, or &> / &>>.
# Not >& / <& (fd duplication) and not a plain < (read).
REDIR_RE = re.compile(r"(?:(?<![<>&0-9])\d+|&)?(?:>>|>\||<>|>)(?!&)(?!\()\s*")
WRITE_CMDS_ANY = ("tee", "touch")
WRITE_CMDS_DEST = ("cp", "mv", "ln", "install")


def is_shell(path: Path) -> bool:
    try:
        with path.open("rb") as fh:
            first = fh.readline(200)
    except OSError:
        return False
    return bool(re.match(rb"#!\s*\S*(?:/|env\s+)(?:ba)?sh\b", first))


def strip_comment(line: str) -> str:
    """Drop an unquoted `# ...` tail. Tracks single/double quotes and escapes."""
    out, q, i = [], None, 0
    while i < len(line):
        c = line[i]
        if c == "\\" and q != "'":
            out.append(line[i:i + 2]); i += 2; continue
        if q:
            if c == q:
                q = None
        elif c in ("'", '"'):
            q = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t;|&("):
            break
        out.append(c); i += 1
    return "".join(out)


def code_lines(text: str):
    """Yield (lineno, code) with comments and heredoc bodies removed."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        code = strip_comment(raw)
        yield i + 1, code
        m = HEREDOC_RE.search(code)
        if m:
            term = m.group(2)
            i += 1
            while i < len(lines) and lines[i].strip() != term:
                i += 1
        i += 1


def take_word(s: str) -> str:
    """The shell word at the start of s (quotes kept, stops at unquoted space/;|&)."""
    out, q, i = [], None, 0
    while i < len(s):
        c = s[i]
        if c == "\\" and q != "'":
            out.append(s[i:i + 2]); i += 2; continue
        if q:
            if c == q:
                q = None
        elif c in ("'", '"'):
            q = c
        elif c in " \t;|&)<>":
            break
        out.append(c); i += 1
    return "".join(out)


def split_words(s: str):
    """Command words of s, with redirections (`2>/dev/null`, `< f`) removed."""
    words, rest = [], s
    while True:
        rest = rest.lstrip()
        if not rest or rest[0] in ";|&)":
            return words, rest
        if rest[0] in "<>":
            rest = rest.lstrip("<>&|").lstrip()
            rest = rest[len(take_word(rest)):]
            continue
        w = take_word(rest)
        if not w:
            return words, rest
        rest = rest[len(w):]
        if w.isdigit() and rest[:1] in ("<", ">"):
            continue  # fd number of a redirect
        words.append(w)


def tainted_vars(lines) -> set[str]:
    assigns = []
    for _, code in lines:
        for stmt in re.split(r";|&&|\|\|", code):
            m = ASSIGN_RE.match(stmt)
            if m:
                assigns.append((m.group(1), m.group(2)))
    tainted: set[str] = set()
    changed = True
    while changed:
        changed = False
        for name, rhs in assigns:
            if name in tainted:
                continue
            if SHARE_LITERAL in rhs or any(v in tainted for v in VARREF_RE.findall(rhs)):
                tainted.add(name); changed = True
    return tainted


def word_is_share(word: str, tainted: set[str]) -> bool:
    if SHARE_LITERAL in word:
        return True
    return any(v in tainted for v in VARREF_RE.findall(word))


def scan_text(text: str):
    lines = list(code_lines(text))
    tainted = tainted_vars(lines)
    findings = []
    for lineno, code in lines:
        # 1. output redirects
        for m in REDIR_RE.finditer(code):
            # skip `2>/dev/null`-style and arithmetic `$(( a > b ))` / `[ a -gt b ]`
            before = code[:m.start()]
            if before.count("((") > before.count("))"):
                continue
            target = take_word(code[m.end():])
            if target and word_is_share(target, tainted):
                findings.append((lineno, code.strip(), f"redirect into shared dir: {target}"))
        # 2. commands that write their operands
        for seg in re.split(r"\||;|&&|\|\||\$\(|`", code):
            words, _ = split_words(seg)
            while words and ASSIGN_RE.match(words[0]):
                words = words[1:]
            if not words:
                continue
            cmd = os.path.basename(words[0].strip("'\""))
            if cmd == "command" and len(words) > 1:
                words = words[1:]; cmd = os.path.basename(words[0])
            ops = [w for w in words[1:] if not w.startswith("-")]
            if cmd in WRITE_CMDS_ANY:
                hits = [w for w in ops if word_is_share(w, tainted)]
            elif cmd in WRITE_CMDS_DEST and len(ops) >= 2:
                hits = [ops[-1]] if word_is_share(ops[-1], tainted) else []
            else:
                hits = []
            for w in hits:
                findings.append((lineno, code.strip(), f"`{cmd}` writes into shared dir: {w}"))
    return findings


def discover(root: Path):
    files = []
    for g in SCAN_GLOBS:
        for base in sorted(root.glob(g)):
            for p in sorted(base.rglob("*")):
                if p.is_file() and not p.is_symlink() and is_shell(p):
                    files.append(p)
    return files


def main(argv):
    args = argv[1:]
    root = Path(__file__).resolve().parents[3]
    if args[:1] == ["--root"]:
        if len(args) < 2:
            print("usage: check.py [--root DIR] [FILE...]", file=sys.stderr); return 2
        root = Path(args[1]); args = args[2:]
    files = [Path(a) for a in args] if args else discover(root)
    if not files:
        print(f"share-writes: FAIL — found no shell scripts to inspect under {root} "
              f"({', '.join(SCAN_GLOBS)}); refusing to pass over nothing", file=sys.stderr)
        return 2
    inspected, total = 0, 0
    for f in files:
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            print(f"share-writes: FAIL — cannot read {f}: {e}", file=sys.stderr); return 2
        inspected += 1
        if f.name == PUBLISHER_BASENAME:
            continue
        for lineno, code, why in scan_text(text):
            total += 1
            try:
                shown = f.relative_to(root)
            except ValueError:
                shown = f
            print(f"{shown}:{lineno}: {why}\n    {code}")
    print(f"share-writes: inspected {inspected} shell file(s), {total} finding(s)")
    if total:
        print("share-writes: route these through /usr/libexec/ga-share-publish "
              "(stdin -> staged file -> rename into place)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
