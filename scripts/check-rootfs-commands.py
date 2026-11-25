#!/usr/bin/env python3
"""Every external command our target scripts call must exist in the target rootfs.

Why: 12 scripts called `logger` and the image had none; each call was
`logger ... 2>/dev/null || ...`, so nothing ever said so.

  check-rootfs-commands.py --board B (--target DIR | --list FILE [--plus NAME]...)
      [--repo DIR] [--allow FILE] [--min-scripts N] [--dump]

Scripts judged: shell scripts of the shared and the board's rootfs overlay, and
package scripts that are installed (same file name in the target). --target is
the real build output (the bake); --list is a recorded file list of one (CI).
--plus names a command the recorded build does not have yet but the tree now
configures; it must be justified in the CI call.

A command is REQUIRED unless the same script probes it (`command -v X`,
`type X`, `which X`, `[ -x /path/X ]`): then it is optional and only reported.
The allowlist (one `command<TAB>script glob<TAB>reason[<TAB>until YYYY-MM-DD]` per
line) is for calls that never run on this rootfs, or are accepted until a date; an
entry that excuses nothing, or whose date has passed, is a failure.
Exit 0 ok, 1 missing command or stale allowlist entry, 2 could not judge.
"""
import argparse
import datetime
import fnmatch
import os
import pathlib
import re
import sys

BUILTINS = set(
    """. : [ alias bg bind break builtin caller cd command compgen complete continue declare dirs disown echo
    enable eval exec exit export false fc fg getopts hash help history jobs kill let local logout mapfile popd
    printf pushd pwd read readarray readonly return set shift shopt source suspend test times trap true type
    typeset ulimit umask unalias unset wait""".split()
)
RESERVED = {"if", "then", "else", "elif", "fi", "do", "done", "while", "until", "{", "}", "!", "time", "in", "esac"}
# command -> number of own arguments before the command it runs
WRAPPERS = {"exec": 0, "nohup": 0, "nice": 0, "ionice": 0, "setsid": 0, "env": 0, "timeout": 1, "chrt": 1, "xargs": 0}
NAME = re.compile(r"^[A-Za-z0-9_.+/-]+$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")


class Lexer:
    """Finds simple commands. Not a full shell: enough to name argv[0], and cross-checked against shfmt."""

    def __init__(self, text):
        self.s, self.i, self.cmds, self.funcs, self.heredocs = text, 0, [], set(), []

    def quoted(self, q):  # past the opening quote; returns literal text or None when it is dynamic
        out, dyn = "", False
        while self.i < len(self.s):
            c = self.s[self.i]
            if q == "'" and c == "'" or q == '"' and c == '"':
                self.i += 1
                return None if dyn else out
            if q == '"' and c == "\\":
                out += self.s[self.i + 1 : self.i + 2]
                self.i += 2
                continue
            if q == '"' and c in "$`":
                dyn = True
                self.expansion()
                continue
            out += c
            self.i += 1
        return None

    def expansion(self):
        s = self.s
        if s[self.i] == "`":
            j = self.i + 1
            while j < len(s) and s[j] != "`":
                j += 2 if s[j] == "\\" else 1
            self.sub(s[self.i + 1 : j])
            self.i = j + 1
        elif s.startswith("$((", self.i):
            depth, self.i = 2, self.i + 3
            while self.i < len(s) and depth:
                if s.startswith("$(", self.i) and not s.startswith("$((", self.i):
                    self.expansion()
                    continue
                depth += {"(": 1, ")": -1}.get(s[self.i], 0)
                self.i += 1
        elif s.startswith("$(", self.i):
            self.i += 2
            self.commands(")")
        elif s.startswith("${", self.i):
            self.i += 2
            while self.i < len(s) and s[self.i] != "}":
                c = s[self.i]
                if c == "\\":
                    self.i += 2
                elif c in "$`":
                    self.expansion()
                elif c == '"':
                    self.i += 1
                    self.quoted('"')
                else:
                    self.i += 1
            self.i += 1
        elif s.startswith("$'", self.i):
            self.i += 2
            while self.i < len(s) and s[self.i] != "'":
                self.i += 2 if s[self.i] == "\\" else 1
            self.i += 1
        else:
            self.i += 2 if self.i + 1 < len(s) and s[self.i + 1] in "?#@*$!-0123456789" else 1
            while self.i < len(s) and (s[self.i].isalnum() or s[self.i] == "_"):
                self.i += 1

    def sub(self, text):
        lx = Lexer(text)
        lx.commands("")
        self.cmds += lx.cmds
        self.funcs |= lx.funcs

    def word(self):  # -> (text or None when dynamic, was_quoted)
        out, dyn, q, s = "", False, False, self.s
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\n;&|<>()" and not (c == "(" and out.endswith("=")):
                break
            if c == "\\":
                if s[self.i + 1 : self.i + 2] == "\n":
                    self.i += 2
                    continue
                out += s[self.i + 1 : self.i + 2]
                self.i += 2
            elif c in "'\"":
                self.i += 1
                q = True
                t = self.quoted(c)
                dyn, out = dyn or t is None, out + (t or "")
            elif c in "$`":
                dyn = True
                self.expansion()
            elif c == "(":  # array literal a=( ... )
                self.i += 1
                while self.i < len(s) and s[self.i] != ")":
                    if s[self.i] in " \t\n":
                        self.i += 1
                    elif s[self.i] == "#":
                        self.eol()
                    elif s[self.i] in ";&|<>(":
                        self.i += 1
                    else:
                        self.word()
                self.i += 1
            else:
                out += c
                self.i += 1
        return (None if dyn and not ASSIGN.match(out) else out), q

    def eol(self):
        while self.i < len(self.s) and self.s[self.i] != "\n":
            self.i += 1

    def newline(self):
        self.i += 1
        for delim, strip, literal in self.heredocs:
            at = self.i
            while self.i < len(self.s):
                j = self.s.find("\n", self.i)
                j = len(self.s) if j < 0 else j
                ln = self.s[self.i : j]
                self.i = j + 1
                if (ln.lstrip("\t") if strip else ln) == delim:
                    break
            if not literal:  # an unquoted here-document runs its substitutions
                body = Lexer(self.s[at : self.i].replace("'", " "))
                while body.i < len(body.s):
                    if body.s[body.i] == "\\":
                        body.i += 2
                    elif body.s[body.i] in "$`":
                        body.expansion()
                    else:
                        body.i += 1
                self.cmds += body.cmds
        self.heredocs = []

    def redirect(self):
        s = self.s
        m = re.match(r"<<<|<<-?|<>|>>|>\||[<>]&|&>>?|[<>]", s[self.i :])
        self.i += len(m[0])
        if s.startswith("(", self.i) and m[0] in "<>":  # process substitution
            self.i += 1
            self.commands(")")
            return
        while self.i < len(s) and s[self.i] in " \t":
            self.i += 1
        if s.startswith(("<(", ">("), self.i):
            self.i += 2
            self.commands(")")
            return
        w, q = self.word()
        if m[0] in ("<<", "<<-") and w is not None:
            self.heredocs.append((w, m[0] == "<<-", q or "\\" in s[self.i - len(w) - 1 : self.i]))

    def commands(self, end):
        """Parse a list until `end` (")", "esac" or end of text)."""
        s, argv, start = self.s, [], True

        def flush():
            nonlocal argv, start
            if argv:
                self.cmds.append(argv)
            argv, start = [], True

        while self.i < len(s):
            c = s[self.i]
            if c in " \t":
                self.i += 1
            elif c == "\\" and s[self.i + 1 : self.i + 2] == "\n":
                self.i += 2
            elif c == "\n":
                flush()
                self.newline()
            elif c == "#":
                self.eol()
            elif s.startswith("&>", self.i):
                self.redirect()
            elif c in ";&|":
                flush()
                self.i += 1
            elif c in "<>":
                if argv and argv[-1] is not None and argv[-1].isdigit() and s[self.i - 1].isdigit():
                    argv.pop()
                self.redirect()
            elif c == "(":
                if s.startswith("((", self.i) and start:
                    depth, self.i = 2, self.i + 2
                    while self.i < len(s) and depth:
                        if s.startswith("$(", self.i) and not s.startswith("$((", self.i):
                            self.expansion()
                            continue
                        depth += {"(": 1, ")": -1}.get(s[self.i], 0)
                        self.i += 1
                    continue
                m = re.match(r"\(\s*\)", s[self.i :])
                if m and len(argv) == 1 and argv[0]:
                    self.funcs.add(argv[0])
                    argv, start = [], True
                    self.i += len(m[0])
                    continue
                flush()
                self.i += 1
                self.commands(")")
            elif c == ")":
                flush()
                self.i += 1
                if end == ")":
                    return
            else:
                w, q = self.word()
                if start and not q and w == "esac" and end == "esac":
                    flush()
                    return
                if start and not q and w in RESERVED:
                    continue
                if start and not q and w == "[[":
                    while self.i < len(s) and not re.match(r"\]\](?=[\s;&|)]|$)", s[self.i :]):
                        if s[self.i] in " \t\n;&|<>()":
                            self.i += 1
                        else:
                            self.word()
                    self.i += 2
                    continue
                if start and not q and w == "case":
                    self.case()
                    continue
                if start and not q and w == "for" or start and not q and w == "select":
                    self.forhead()
                    continue
                if start and not q and w == "function":
                    while s[self.i : self.i + 1] in (" ", "\t"):
                        self.i += 1
                    f, _ = self.word()
                    self.funcs.add(f)
                    m = re.match(r"\s*\(\s*\)", s[self.i :])
                    self.i += len(m[0]) if m else 0
                    continue
                if start and w is not None and ASSIGN.match(w):
                    continue
                argv.append(w)
                start = False
        flush()

    def forhead(self):
        s = self.s
        m = re.match(r"\s*\(\(", s[self.i :])
        if m:
            self.i += len(m[0])
            j = s.find("))", self.i)
            self.i = len(s) if j < 0 else j + 2
            return
        while self.i < len(s) and s[self.i] not in ";\n":
            if s[self.i] in " \t":
                self.i += 1
            elif s[self.i] == "\\":
                self.i += 2
            elif s[self.i] == "#":
                self.eol()
            elif s[self.i] in "&|<>()":
                self.i += 1
            else:
                self.word()

    def case(self):
        s = self.s
        while self.i < len(s) and s[self.i] in " \t":
            self.i += 1
        self.word()
        m = re.match(r"\s*in\b", s[self.i :])
        self.i += len(m[0]) if m else 0
        while self.i < len(s):
            m = re.match(r"(\s|#[^\n]*)*", s[self.i :])
            self.i += len(m[0])
            if re.match(r"esac(?=[\s;&|)]|$)", s[self.i :]):
                self.i += 4
                return
            if s.startswith("(", self.i):
                self.i += 1
            while self.i < len(s) and s[self.i] != ")":  # patterns
                if s[self.i] in " \t\n|":
                    self.i += 1
                elif s[self.i] in ";&<>(":
                    self.i += 1
                else:
                    self.word()
            self.i += 1
            # body up to ;; (or esac)
            depth = self.body_end()
            body = s[self.i : depth]
            self.sub(body)
            self.i = depth
            m = re.match(r";;&?|;&", s[self.i :])
            self.i += len(m[0]) if m else 0

    def body_end(self):
        """Index of the `;;` or closing `esac` that ends the current case arm."""
        probe = Lexer(self.s)
        probe.i = self.i
        start, s = True, self.s
        while probe.i < len(s):
            c = s[probe.i]
            if s.startswith(";;", probe.i) or s.startswith(";&", probe.i):
                return probe.i
            if c in " \t":
                probe.i += 1
            elif c == "\n":
                probe.newline()
                start = True
            elif c == "#":
                probe.eol()
            elif c in ";&|":
                probe.i += 1
                start = True
            elif c in "<>":
                probe.redirect()
            elif c == "(":
                probe.i += 1
                probe.commands(")")
                start = True
            elif c == ")":
                probe.i += 1
            else:
                at = probe.i
                w, q = probe.word()
                if start and not q and w == "esac":
                    return at
                if start and not q and w == "case":
                    probe.case()
                start = start and not q and (w in RESERVED or w is not None and bool(ASSIGN.match(w)))
        return len(s)


def argv0(argv):
    """The commands one simple command runs: itself and what a wrapper runs."""
    out = []
    while argv:
        a, rest = argv[0], argv[1:]
        if a is None:
            return out
        out.append(a)
        base = os.path.basename(a)
        if base == "command" and rest[:1] and rest[0] in ("-v", "-V"):
            return out
        if base == "flock":
            rest = [r for r in rest if r is None or not r.startswith("-")][1:]
        elif base in WRAPPERS or base == "command":
            skip = WRAPPERS.get(base, 0)
            while rest and rest[0] is not None and (rest[0].startswith("-") or base == "env" and ASSIGN.match(rest[0])):
                opt, rest = rest[0], rest[1:]
                if re.fullmatch(r"-[nckLPIsd]", opt) and base in ("nice", "ionice", "timeout", "xargs"):
                    rest = rest[1:]
            rest = rest[skip:]
        else:
            return out
        argv = rest
    return out


def analyse(text):
    """-> (commands called, commands probed)"""
    lx = Lexer(text)
    lx.commands("")
    called, probed = set(), set()
    for argv in lx.cmds:
        a = argv[0]
        if a in ("command", "type", "which", "hash") and len(argv) > 1:
            names = [x for x in argv[1:] if x and not x.startswith("-")]
            if a != "command" or argv[1] in ("-v", "-V"):
                probed |= set(names)
                if a == "which":
                    called.add(a)
                continue
        if a in ("[", "test") and "-x" in argv:
            k = argv.index("-x")
            if len(argv) > k + 1 and argv[k + 1]:
                probed |= {argv[k + 1], os.path.basename(argv[k + 1])}
        if a == "trap" and len(argv) > 1 and argv[1]:
            sub = Lexer(argv[1])
            sub.commands("")
            for x in sub.cmds:
                called |= set(argv0(x))
        called |= set(argv0(argv))
    called = {c for c in called if NAME.match(c) and c not in BUILTINS and c not in lx.funcs and not c.startswith("-")}
    called = {c for c in called if not c.isdigit() and not c.startswith("./") and c not in (".", "..")}
    return called, probed


def functions(text):
    lx = Lexer(text)
    lx.commands("")
    return lx.funcs


def is_shell(p):
    try:
        head = p.read_bytes()[:80].split(b"\n")[0]
    except OSError:
        return False
    return bool(re.match(rb"#!\s*(/usr/bin/env\s+)?(/usr)?(/bin/)?(ba|da|a)?sh\b", head))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", required=True)
    ap.add_argument("--target")
    ap.add_argument("--list")
    ap.add_argument("--plus", action="append", default=[])
    ap.add_argument("--repo", default=str(pathlib.Path(__file__).resolve().parents[1]))
    ap.add_argument("--allow")
    ap.add_argument("--min-scripts", type=int, default=40)
    ap.add_argument("--dump", action="store_true")
    a = ap.parse_args()
    repo = pathlib.Path(a.repo)
    if a.target:
        t = pathlib.Path(a.target)
        files = {str(p.relative_to(t)) for p in t.rglob("*") if p.is_symlink() or p.is_file()} if t.is_dir() else set()
    elif a.list:
        files = {ln.strip() for ln in open(a.list) if ln.strip()}
    else:
        ap.error("--target or --list")
    dirs = ("usr/bin/", "usr/sbin/", "bin/", "sbin/")
    have = {f.rsplit("/", 1)[1] for f in files if f.startswith(dirs) and f.count("/") == f[: f.rindex("/")].count("/") + 1}
    if len(have) < 300:
        print(f"check-rootfs-commands: FATAL: only {len(have)} commands in the rootfs, refusing to judge")
        return 2
    have |= set(a.plus)
    paths = {"/" + f for f in files}
    names = {os.path.basename(f) for f in files}
    ext, board = repo / "buildroot-external", repo / f"buildroot-{a.board}"
    overlays = [ext / "rootfs-overlay"] + sorted(p for p in board.rglob("rootfs-overlay") if p.is_dir())
    scripts = []
    for o in overlays:
        for p in sorted(o.rglob("*")):
            if p.is_file():
                paths.add("/" + str(p.relative_to(o)))
                if str(p.relative_to(o)).startswith(dirs):
                    have.add(p.name)
                if is_shell(p):
                    scripts.append(p)
    scripts += [p for d in (ext / "package", board / "package") if d.is_dir() for p in sorted(d.rglob("*")) if p.is_file() and is_shell(p) and p.name in names]
    if len(scripts) < a.min_scripts:
        print(f"check-rootfs-commands: FATAL: only {len(scripts)} scripts found (min {a.min_scripts})")
        return 2
    allow, expired = [], 0
    af = pathlib.Path(a.allow) if a.allow else repo / "buildroot-external/rootfs-commands.allow"
    for ln in af.read_text().splitlines():
        if ln.strip() and not ln.startswith("#"):
            f = ln.split("\t")
            until = f[3].strip() if len(f) == 4 else ""
            if len(f) not in (3, 4) or not f[2].strip() or len(f) == 4 and not re.fullmatch(r"until \d{4}-\d\d-\d\d", until):
                print(f"check-rootfs-commands: FATAL: {af.name}: need command<TAB>glob<TAB>reason: {ln!r}")
                return 2
            today = os.environ.get("GA_TODAY") or datetime.date.today().isoformat()
            if until and until[6:] < today:
                print(f"  EXPIRED   allowlist entry {f[0]} / {f[1]}: {until}")
                expired += 1
                continue
            allow.append((f[0], f[1], f[2], f[0] + "\t" + f[1]))
    # functions of the shared libraries a script sources (named in it by file name)
    libs = {}
    for p in scripts + [q for o in overlays for q in o.rglob("*.sh") if q.is_file()]:
        libs.setdefault(p.name, set()).update(functions(p.read_text(errors="replace")))
    used, missing, optional, total = set(), {}, {}, 0
    for p in scripts:
        rel = str(p.relative_to(repo))
        text = p.read_text(errors="replace")
        called, probed = analyse(text)
        sourced = [ln for ln in text.splitlines() if re.search(r"(^|[;&|({\s])(\.|source)\s+\S", ln) or re.search(r"\.sh\b", ln)]
        for lib, fn in libs.items():
            if lib != p.name and any(lib in ln for ln in sourced):
                called -= fn
        total += len(called)
        if a.dump:
            for c in sorted(called):
                print(f"{rel}\t{c}")
        for c in called:
            base = os.path.basename(c)
            ok = (c in paths or "/usr" + c in paths or c.startswith(("/bin/", "/sbin/")) and base in have) if c.startswith("/") else c in have
            if ok:
                continue
            hit = [x for x in allow if x[0] == c and fnmatch.fnmatch(rel, x[1])]
            if hit:
                used |= {x[3] for x in hit}
            elif c in probed or base in probed:
                optional.setdefault(c, []).append(rel)
            else:
                missing.setdefault(c, []).append(rel)
    if a.dump:
        return 0
    for c, fs in sorted(optional.items()):
        print(f"  optional  {c}: probed and absent ({', '.join(sorted(fs))})")
    for c, fs in sorted(missing.items()):
        print(f"  MISSING   {c}: called by {', '.join(sorted(fs))}")
    # an entry for another board's directory is not stale on this board
    stale = [x for x in allow if x[3] not in used and not (x[1].startswith("buildroot-") and not x[1].startswith(("buildroot-external", f"buildroot-{a.board}/", "buildroot-*")))]
    for x in stale:
        print(f"  STALE     allowlist entry {x[0]} / {x[1]} excuses nothing")
    print(f"check-rootfs-commands: {a.board}: {len(scripts)} scripts, {total} calls, {len(have)} commands; {len(missing)} missing, {len(optional)} optional-absent, {len(used)} allowed, {len(stale)} stale")
    if total < a.min_scripts:
        print("check-rootfs-commands: FATAL: parsed almost no calls")
        return 2
    return 1 if missing or stale or expired else 0


if __name__ == "__main__":
    sys.exit(main())
