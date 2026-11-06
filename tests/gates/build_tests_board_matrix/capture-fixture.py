#!/usr/bin/env python3
"""capture-fixture.py -- turn a REAL bake output into the committed matrix fixture of one board.

NOT run in CI. Run by a person when a board's fixture is (re)captured:

  1. copy the pieces of a finished bake's ga_output next to each other (the builder keeps them),
        <REAL>/ga_output/{target,images/{configs,reports,boot},build/hassio-1.0.0,build/linux-*/...}
        <REAL>/synced/        = the git-ignored files scripts/sync-components.sh pulled into
                                buildroot-external/rootfs-overlay (Tier-2 components)
        <REAL>/ga_output/.ls  = `ls -l` of images/*.raucb *.img.xz rootfs.erofs (sizes only)
        <REAL>/extras/core.json  = {index, manifest, config} of the baked Core image archive
        <REAL>/extras/ga_manager.tar = the baked ga_manager image archive
        <REAL>/extras/go-version-m.txt = `GOTOOLCHAIN=local host/bin/go version -m target`
  2. capture-fixture.py <board> <REAL> <FIXTURE_DIR>

What is kept (everything the build tests can look at, nothing they cannot):
  * every symlink, directory, file name, mode;
  * the CONTENT of regular files that are not ELF, up to 64 KiB (config, units, scripts, json,
    small web assets): the tests grep these;
  * ELF binaries, kernel modules and big blobs as EMPTY files of the same mode, except the few
    a test looks INSIDE (PROJECT below): those keep only the matching strings, as text;
  * the kernel/u-boot configs and image configs complete;
  * secrets are replaced by a fixed, obviously fake value (SCRUB below). The fixture is committed to
    a PUBLIC repository: tests/gates/build_tests_board_matrix/selftest.sh refuses a fixture that holds
    a value shaped like a key, a password hash or a PSK.
"""
import sys
sys.dont_write_bytecode = True
import io, json, os, re, shutil, stat, sys, tarfile, tempfile
sys.dont_write_bytecode = True   # the checker is imported below: leave no .pyc in the tracked tree
from pathlib import Path

board, real, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
CAP = 64 * 1024
WEBTEXT = re.compile(r"\.(js|css|html|json)$")
_ROOT = Path(__file__).resolve().parents[3]
_NB = re.search(r'^NETBIRD_TAG="\$\{NETBIRD_TAG:-v?([0-9.]+)', (_ROOT / "scripts/ga_build.sh").read_text(), re.M)
#: what a test greps INSIDE a binary / big asset (path suffix -> regex over its printable strings);
#: only the matching strings are kept. The patterns are the readers' own needles.
PROJECT = {
    "usr/bin/fluent-bit": rb"Systemd \(Journal\) reader|Tail files|Kernel Log Buffer|Exec Input|grep events by specified field values|modify record|modify records by applying rules|Loki|FLB_HAVE_IN_STORAGE_BACKLOG|Forward \(Fluentd protocol\)|Fluentd in-forward",
    "usr/bin/netbird": re.escape(_NB.group(1).encode()),
}
#: big web assets: the references check-vendored-site-bundle.sh counts
WEB_PROJECT = rb"/[A-Za-z0-9_]+_static|/api/greenautarky[A-Za-z0-9_]*|0\.0\.0[.-]dev[0-9]*|(?:frontend_es5|frontend_latest)/greenautarky-setup\.[A-Za-z0-9]+\.js"
def project(data: bytes, rx: bytes, whole_runs: bool = False) -> bytes:
    """the matches of rx -- or, whole_runs, the whole printable runs (what `strings -a` prints, one
    per line) that contain one: a reader that matches whole lines needs the line, not the needle."""
    seen, out = set(), []
    it = (m.group(0) for m in re.finditer(rb"[\x20-\x7e\t]{4,}", data) if re.search(rx, m.group(0))) if whole_runs \
        else (m.group(0) for m in re.finditer(rx, data))
    for t in it:
        if t not in seen and len(t) < (4096 if whole_runs else 512):
            seen.add(t); out.append(t)
    return b"\n".join(out) + (b"\n" if out else b"")
FAKE_HASH = "$6$FIXTURE$" + "x" * 86
SCRUB = {
    "etc/shadow": lambda t: re.sub(r"^(root):[^:]*:", r"\1:" + FAKE_HASH.replace("\\", "\\\\") + ":", t, flags=re.M),
    "usr/share/ga-netbird/setup-key": lambda t: "00000000-0000-4000-8000-000000000000\n",
    "usr/share/ga-wifi/openstick-wifi.key": lambda t: "0123456789abcdef" * 4 + "\n",
    "usr/share/ga-wifi/GreenAutarky-Install.nmconnection": lambda t: re.sub(r"^(psk=).*$", r"\1fixture-wifi-psk", t, flags=re.M),
}

# mesh (CGNAT 100.64/10) addresses in shipped files are replaced by documentation-range ones (RFC 5737), one
# stable mapping per capture: the fixture is committed to a PUBLIC repository.
_CG = re.compile(rb"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b")
_cg_map: dict[bytes, bytes] = {}
_ID = re.compile(rb"KIB-SON-[0-9]+")
_MAIL = re.compile(rb"\b[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?!(?:service|target|socket|mount|timer|path|slice|device|swap|scope|automount)\b)[A-Za-z]{2,}\b")
def scrub_addrs(b: bytes) -> bytes:
    """mesh addresses -> RFC 5737 ones, device labels -> a zero label, e-mail addresses -> mail@example.invalid"""
    def sub(m):
        return _cg_map.setdefault(m.group(0), b"198.51.100.%d" % (len(_cg_map) + 1))
    return _MAIL.sub(b"mail@example.invalid", _ID.sub(b"KIB-SON-00000000", _CG.sub(sub, b)))

def is_elf(p: Path) -> bool:
    try:
        with open(p, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False

def add_tree(tf: tarfile.TarFile, root: Path, arc: str, filt=None, cap: int = CAP):
    for dirpath, dirs, files in os.walk(root):
        dirs.sort(); files.sort()
        rel_dir = os.path.relpath(dirpath, root)
        for name in dirs + files:
            p = Path(dirpath) / name
            rel = os.path.normpath(os.path.join(rel_dir, name))
            if filt and not filt(rel):
                continue
            ti = tf.gettarinfo(str(p), arcname=f"{arc}/{rel}")
            ti.uid = ti.gid = 0; ti.uname = ti.gname = ""
            ti.mtime = 1_700_000_000
            if ti.isreg():
                content = b""
                s = p.stat().st_size
                if "custom_components/" in rel and re.search(r"\.(js|css|map|json|png|svg|woff2?|gz|ico|jpg)$", name) and not name.startswith(("manifest", "BUILD", "strings", "translations", "cards")):
                    content = project(p.read_bytes(), WEB_PROJECT)
                elif rel in SCRUB:
                    content = SCRUB[rel](p.read_text(errors="replace")).encode()
                elif is_elf(p) or s > cap:
                    for k, rx in PROJECT.items():
                        if rel.endswith(k):
                            content = project(p.read_bytes(), rx, whole_runs=rel.endswith("fluent-bit"))
                    if not content and not is_elf(p) and WEBTEXT.search(name):
                        content = project(p.read_bytes(), WEB_PROJECT)
                elif re.match(r"usr/share/(zoneinfo|keymaps|consolefonts|consoletrans|unimaps|terminfo|locale|X11)/", rel):
                    content = b""
                else:
                    content = scrub_addrs(p.read_bytes())
                ti.size = len(content)
                tf.addfile(ti, io.BytesIO(content))
            else:
                tf.addfile(ti)

out.mkdir(parents=True, exist_ok=True)
ga = real / "ga_output"
with tarfile.open(out / "ga_output.tar.xz", "w:xz") as tf:
    add_tree(tf, ga / "target", "ga_output/target")
    # the sidecars the tests read; image archives are rebuilt by make-fixture.sh
    for sub, keep in (("images/configs", None), ("images/boot", None),
                      ("images/reports", lambda r: r in ("summary.json", "rootfs", "rootfs/summary.json"))):
        if (ga / sub).is_dir():
            add_tree(tf, ga / sub, f"ga_output/{sub}", filt=keep, cap=1 << 30 if sub == "images/configs" else CAP)
    for pat in ("build/linux-*/.config", "build/linux-*/arch/*/boot/dts/rockchip/*sonoff-ihost.dtsi", "build/uboot-*/.config"):
        for p in sorted(ga.glob(pat)):
            rel = p.relative_to(ga)
            ti = tf.gettarinfo(str(p), arcname=f"ga_output/{rel}"); ti.uid = ti.gid = 0; ti.uname = ti.gname = ""; ti.mtime = 1_700_000_000
            tf.addfile(ti, io.BytesIO(p.read_bytes()))
with tarfile.open(out / "synced.tar.xz", "w:xz") as tf:
    add_tree(tf, real / "synced", "synced")
shutil.copy(ga / "build/hassio-1.0.0/version.json", out / "version.json")
(out / "images.txt").write_text("\n".join(sorted(os.listdir(ga / "build/hassio-1.0.0/images"))) + "\n")
(out / "sizes.txt").write_text(Path(ga / ".ls").read_text() if (ga / ".ls").exists() else "")
core = json.loads((real / "extras/core.json").read_text())
core["config"].pop("history", None)
(out / "core-image.json").write_text(json.dumps(core["config"], indent=1, sort_keys=True) + "\n")
# ga_manager: only the files the capability checker inspects, read the way the checker reads them
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
import importlib.util
spec = importlib.util.spec_from_file_location("gmc", Path(__file__).resolve().parents[3] / "scripts/check-ga-manager-capabilities.py")
gmc = importlib.util.module_from_spec(spec); spec.loader.exec_module(gmc)
wanted = {gmc.SOURCE_CONFIG} | {p for c in gmc.CAPABILITIES for p in c["files"]}
got = gmc.read_layered(real / "extras/ga_manager.tar", wanted)
missing = [k for k, v in got.items() if v is None]
if missing:
    sys.exit(f"capture: ga_manager image lacks {missing}")
with tarfile.open(out / "ga_manager-files.tar", "w") as tf:
    for k, v in sorted(got.items()):
        ti = tarfile.TarInfo(k); ti.size = len(v); ti.mtime = 1_700_000_000
        tf.addfile(ti, io.BytesIO(v))
shutil.copy(real / "extras/go-version-m.txt", out / "go-version-m.txt")
print("captured", board, "->", out)
