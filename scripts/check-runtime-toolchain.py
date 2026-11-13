#!/usr/bin/env python3
# =============================================================================
# check-runtime-toolchain.py — no baked container may ship a build toolchain.
# =============================================================================
# WHY THIS EXISTS (Odoo #1975, ADR-0044 §2.2 + Amendment 2026-11-12)
# ------------------------------------------------------------------
# ADR-0044 decided on 2026-10-12 that runtime images carry no build toolchain.
# A month later the Core image still shipped ~650 MB of one (Rust, LLVM, gcc,
# cmake; dpkg Installed-Size, measured 2026-11-12) and ga_hmvapp_addon 198 MB,
# and nothing turned red, because nothing looked. A decision with no check is a
# note; this is the check.
#
# WHAT IT READS
# -------------
# Every image tar the bake put into the data partition (OCI layout, as
# fetch-addon-images.sh / skopeo write it, or docker-archive). The layers are
# applied in order INCLUDING whiteouts, so a toolchain a later layer deletes is
# NOT reported (that image does not ship it), and one a later layer leaves in
# place IS reported even if the Dockerfile "cleaned up" something else.
#
# WHAT COUNTS AS A TOOLCHAIN  (TOOLCHAIN_RULES below — the one definition)
# --------------------------
# The compiler proper, not its runtime libraries: gcc's cc1/cc1plus/lto1, rustc/
# cargo and the Rust standard library rlibs, cmake, the binutils assembler and
# linker, a Go toolchain. libgcc_s / libstdc++ are runtime libraries and are NOT
# flagged.
#
# POLICY  (.runtime-toolchain-gate at the repo root)
# ------
#   mode report|enforce   report: findings are ::warning:: lines and the build
#                         stays green; enforce: an unallowlisted finding or an
#                         expired allowlist entry that still matches = exit 1.
#   allow <image> <until YYYY-MM-DD> <#ticket> <reason>
#                         <image> is the repository's last path segment, e.g.
#                         home-assistant-armv7. Matching is exact.
# The mode is a setting so the 1.7 switch to enforce is a one-line, reviewable
# config change, not a code change (Manager, 2026-11-12).
#
# EXIT CODES
# ----------
#   0  nothing blocking (or mode=report)
#   1  mode=enforce and a toolchain is not allowlisted, or its entry expired
#   2  BROKEN — unreadable tar, no or wrong-shaped manifest, zero images, bad
#      config, or ANY unexpected exception. Always fatal, in BOTH modes: an
#      image that was not inspected must not ship as inspected. Exit 1 means
#      exactly one thing — a toolchain finding in enforce mode — so a crash can
#      never be read as "ships a build toolchain" (Manager review, 2026-11-12:
#      a manifest.json of `[1]` raised AttributeError and exited 1).
import argparse
import datetime
import io
import json
import shutil
import subprocess
import os
import posixpath
import re
import sys
import tarfile

# (category, regex on the path inside the image, no leading slash)
TOOLCHAIN_RULES = [
    ("gcc", re.compile(r"^usr/(lib|libexec)/gcc/[^/]+/[^/]+/(cc1|cc1plus|cc1obj|lto1|f951)$")),
    ("rust", re.compile(r"^(usr/bin|usr/local/bin|usr/local/cargo/bin|root/\.cargo/bin)/(rustc|cargo)$")),
    ("rust", re.compile(r"^usr/(local/)?lib/rustlib/[^/]+/lib/libstd-[^/]+\.rlib$")),
    ("cmake", re.compile(r"^usr/(local/)?bin/cmake$")),
    ("binutils", re.compile(r"^usr/bin/([A-Za-z0-9_]+(-[A-Za-z0-9_.]+){1,3}-)?(ld|ld\.bfd|ld\.gold|as)$")),
    ("go", re.compile(r"^usr/(local/go|lib/go[^/]*)/bin/go$")),
]
# Size accounting only (what the toolchain costs), never a finding on its own.
TOOLCHAIN_TREES = re.compile(
    r"^(usr/(lib|libexec)/gcc/|usr/(local/)?lib/rustlib/|usr/local/go/|usr/lib/go[^/]*/|usr/share/cmake[^/]*/)")

OCI_INDEX = ("application/vnd.oci.image.index.v1+json",
             "application/vnd.docker.distribution.manifest.list.v2+json")


class Broken(Exception):
    pass


ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def zstd_trivial_decode(data):
    """Decode a zstd stream made only of Raw/RLE blocks (and skippable frames).

    Why this exists: BOSv1.6.0-rc13's Core image carries a 16-byte zstd blob
    (labelled tar+gzip in its manifest) that is an EMPTY layer — one RLE block
    of 1024 zero bytes. Python < 3.14 has no zstd and the build container has no
    zstd binary, yet that layer must be read, not skipped. A Compressed block
    raises Broken: real zstd content is never guessed at.
    """
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        magic = data[i:i + 4]
        if len(magic) == 4 and 0x184D2A50 <= int.from_bytes(magic, "little") <= 0x184D2A5F:
            size = int.from_bytes(data[i + 4:i + 8], "little")
            i += 8 + size
            continue
        if magic != ZSTD_MAGIC:
            raise Broken("zstd: bad frame magic")
        fhd = data[i + 4]
        i += 5
        fcs_flag, single, checksum, dict_flag = fhd >> 6, (fhd >> 5) & 1, (fhd >> 2) & 1, fhd & 3
        if not single:
            i += 1  # window descriptor
        i += (0, 1, 2, 4)[dict_flag]
        i += ((1 if single else 0), 2, 4, 8)[fcs_flag]
        while True:
            if i + 3 > n:
                raise Broken("zstd: truncated block header")
            bh = int.from_bytes(data[i:i + 3], "little")
            i += 3
            last, btype, bsize = bh & 1, (bh >> 1) & 3, bh >> 3
            if btype == 0:      # Raw
                out += data[i:i + bsize]
                i += bsize
            elif btype == 1:    # RLE
                out += data[i:i + 1] * bsize
                i += 1
            else:
                raise Broken("zstd: compressed block (needs a zstd decoder)")
            if last:
                break
        if checksum:
            i += 4
    return bytes(out)


def zstd_open(fobj, size):
    """Return a file object with the decompressed zstd stream."""
    try:
        from compression import zstd  # Python 3.14+
        return zstd.ZstdFile(fobj)
    except ImportError:
        pass
    if size <= 1 << 20:
        try:
            return io.BytesIO(zstd_trivial_decode(fobj.read()))
        except Broken:
            fobj.seek(0)
    if shutil.which("zstd"):
        r = subprocess.run(["zstd", "-dc"], input=fobj.read(), capture_output=True)
        if r.returncode == 0:
            return io.BytesIO(r.stdout)
        raise Broken(f"zstd -dc failed: {r.stderr[:200]!r}")
    raise Broken("zstd layer with compressed blocks and no zstd decoder (python < 3.14, no zstd binary)")


def categorize(path):
    for cat, rx in TOOLCHAIN_RULES:
        if rx.search(path):
            return cat
    return None


def _blob(tf, digest):
    name = "blobs/" + digest.replace(":", "/", 1)
    try:
        return tf.extractfile(name).read()
    except (KeyError, AttributeError):
        raise Broken(f"blob {digest} named by the manifest is not in the tar")


# Board arch (BR2_PACKAGE_HASSIO_ARCH) -> OCI platform (architecture, variant)
ARCH_PLATFORM = {"armv7": ("arm", "v7"), "armhf": ("arm", "v6"), "aarch64": ("arm64", None),
                 "amd64": ("amd64", None), "i386": ("386", None)}


def _desc(d, what):
    if not isinstance(d, dict) or not isinstance(d.get("digest"), str) or ":" not in d["digest"]:
        raise Broken(f"{what}: descriptor is not an object with a digest")
    return d


def _platform_ok(desc, arch):
    plat = desc.get("platform")
    if not arch or not isinstance(plat, dict):
        return True
    want_a, want_v = ARCH_PLATFORM[arch]
    if plat.get("architecture") != want_a:
        return False
    return want_v is None or plat.get("variant", want_v) == want_v


def _pick_manifest(tf, desc, arch, depth=0):
    if depth > 3:
        raise Broken("image index nested deeper than 3")
    data = json.loads(_blob(tf, _desc(desc, "index entry")["digest"]))
    if not isinstance(data, dict):
        raise Broken("manifest blob is not a JSON object")
    if desc.get("mediaType") in OCI_INDEX or data.get("mediaType") in OCI_INDEX or "manifests" in data:
        ms = data.get("manifests")
        if not isinstance(ms, list) or not ms:
            raise Broken("image index lists no manifest")
        ms = [_desc(m, "image index") for m in ms]
        if len(ms) == 1:
            pick = ms
        elif not arch:
            raise Broken(f"multi-arch image index ({len(ms)} manifests) and no --arch to choose one")
        else:
            pick = [m for m in ms if isinstance(m.get("platform"), dict) and _platform_ok(m, arch)]
            if len(pick) != 1:
                raise Broken(f"multi-arch image index: {len(pick)} manifests match --arch {arch} (need exactly 1)")
        if not _platform_ok(pick[0], arch):
            raise Broken(f"the only manifest is for {pick[0].get('platform')}, not --arch {arch}")
        return _pick_manifest(tf, pick[0], arch, depth + 1)
    return data


def read_image(path, arch=None):
    """Return (tarfile, ref name, [layer member names]) for an OCI or docker-archive tar.

    Every JSON shape is checked; a wrong shape is Broken, never an exception."""
    try:
        tf = tarfile.open(path, "r:")
    except (tarfile.TarError, OSError) as e:
        raise Broken(f"not a readable tar: {e}")
    names = set(tf.getnames())
    if "index.json" in names:
        idx = json.loads(tf.extractfile("index.json").read())
        ms = idx.get("manifests") if isinstance(idx, dict) else None
        if not isinstance(ms, list) or not ms:
            raise Broken("index.json lists no manifest")
        top = _desc(ms[0], "index.json")
        ann = top.get("annotations") if isinstance(top.get("annotations"), dict) else {}
        name = ann.get("org.opencontainers.image.ref.name", "")
        man = _pick_manifest(tf, top, arch)
        lay = man.get("layers")
        if not isinstance(lay, list):
            raise Broken("manifest has no layers list")
        layers = ["blobs/" + _desc(l, "manifest layer")["digest"].replace(":", "/", 1) for l in lay]
    elif "manifest.json" in names:
        man = json.loads(tf.extractfile("manifest.json").read())
        if not isinstance(man, list) or not man or not isinstance(man[0], dict):
            raise Broken("manifest.json is not a non-empty list of objects")
        tags = man[0].get("RepoTags")
        name = tags[0] if isinstance(tags, list) and tags and isinstance(tags[0], str) else ""
        layers = man[0].get("Layers")
        if not isinstance(layers, list) or not all(isinstance(x, str) for x in layers):
            raise Broken("manifest.json Layers is not a list of paths")
    else:
        raise Broken("neither index.json (OCI) nor manifest.json (docker-archive) in the tar")
    if not layers:
        raise Broken("manifest names zero layers")
    return tf, name, layers


def image_key(ref_name, path):
    """Repository's last path segment without tag/digest: ghcr.io/x/home-assistant-armv7:1 -> home-assistant-armv7."""
    if ref_name:
        repo = ref_name.split("@", 1)[0]
        last = repo.rsplit("/", 1)[-1]
        return last.split(":", 1)[0], "ref.name"
    return os.path.basename(path), "filename"


def scan_image(path, arch=None):
    tf, ref, layers = read_image(path, arch)
    present = {}  # path -> size (regular files and links)
    for lname in layers:
        try:
            fobj = tf.extractfile(lname)
        except KeyError:
            fobj = None
        if fobj is None:
            raise Broken(f"layer {lname} named by the manifest is not in the tar")
        # Stream (r|*): the Core's largest layer is ~600 MB uncompressed and must
        # not be held in memory. r|* handles gzip and uncompressed layers; zstd is
        # sniffed by its magic, because manifests have been seen to label a zstd
        # blob tar+gzip (rc13 Core).
        if fobj.read(4) == ZSTD_MAGIC:
            fobj.seek(0)
            fobj = zstd_open(fobj, tf.getmember(lname).size)
        else:
            fobj.seek(0)
        try:
            lt = tarfile.open(fileobj=fobj, mode="r|*")
        except tarfile.TarError as e:
            raise Broken(f"layer {lname} is not a tar: {e}")
        for m in lt:
            p = m.name
            while p.startswith("./"):
                p = p[2:]
            p = p.lstrip("/")
            d, base = posixpath.split(p)
            if base == ".wh..wh..opq":
                pref = d + "/"
                for k in [k for k in present if k.startswith(pref)]:
                    del present[k]
                continue
            if base.startswith(".wh."):
                tgt = posixpath.join(d, base[4:])
                for k in [k for k in present if k == tgt or k.startswith(tgt + "/")]:
                    del present[k]
                continue
            if m.isfile() or m.issym() or m.islnk():
                present[p] = m.size if m.isfile() else 0
            elif m.isdir() and p in present:
                del present[p]
    tf.close()
    found = {}
    tree_bytes = 0
    for p, size in present.items():
        c = categorize(p)
        if c:
            found.setdefault(c, []).append(p)
        if TOOLCHAIN_TREES.search(p) or c:
            tree_bytes += size
    return ref, found, tree_bytes, len(present)


def load_config(path):
    if not os.path.isfile(path):
        raise Broken(f"config {path} not found")
    mode, allow = None, {}
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("allow"):  # an allow line's ticket starts with '#'
            line = line.split("#", 1)[0].strip()
        parts = line.split()
        if parts[0] == "mode":
            if len(parts) != 2 or parts[1] not in ("report", "enforce"):
                raise Broken(f"{path}:{n}: mode must be 'report' or 'enforce'")
            if mode is not None:
                raise Broken(f"{path}:{n}: mode set twice")
            mode = parts[1]
        elif parts[0] == "allow":
            if len(parts) < 5:
                raise Broken(f"{path}:{n}: allow needs <image> <until YYYY-MM-DD> <#ticket> <reason>")
            img, until, ticket = parts[1], parts[2], parts[3]
            try:
                until_d = datetime.date.fromisoformat(until)
            except ValueError:
                raise Broken(f"{path}:{n}: until '{until}' is not YYYY-MM-DD")
            if not re.fullmatch(r"#\d+", ticket):
                raise Broken(f"{path}:{n}: ticket must look like #1234, got '{ticket}'")
            if img in allow:
                raise Broken(f"{path}:{n}: {img} allowlisted twice")
            allow[img] = (until_d, ticket, " ".join(parts[4:]))
        else:
            raise Broken(f"{path}:{n}: unknown keyword '{parts[0]}'")
    if mode is None:
        raise Broken(f"{path}: no 'mode' line")
    return mode, allow


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--image-tars", required=True, help="directory with the baked image tars")
    ap.add_argument("--config", required=True, help=".runtime-toolchain-gate")
    ap.add_argument("--summary-json", help="write a machine-readable summary here")
    ap.add_argument("--arch", choices=sorted(ARCH_PLATFORM),
                    help="board arch (BR2_PACKAGE_HASSIO_ARCH); picks the manifest of a multi-arch index")
    ap.add_argument("--today", help="YYYY-MM-DD; tests only")
    a = ap.parse_args()
    try:
        mode, allow = load_config(a.config)
        today = datetime.date.fromisoformat(a.today) if a.today else datetime.date.today()
        if not os.path.isdir(a.image_tars):
            raise Broken(f"{a.image_tars} is not a directory")
        tars = sorted(f for f in os.listdir(a.image_tars) if f.endswith(".tar"))
        if not tars:
            raise Broken(f"zero image tars in {a.image_tars} — a check that inspected nothing proved nothing")
        results = []
        for t in tars:
            try:
                ref, found, tbytes, nfiles = scan_image(os.path.join(a.image_tars, t), a.arch)
            except Broken as e:
                raise Broken(f"{t}: {e}")
            except Exception as e:  # noqa: BLE001 — ANY failure to inspect is BROKEN (exit 2), never exit 1
                raise Broken(f"{t}: {type(e).__name__}: {e}")
            if nfiles == 0:
                raise Broken(f"{t}: zero files after applying the layers")
            key, src = image_key(ref, t)
            results.append({"tar": t, "image": key, "name_from": src, "files": nfiles,
                            "toolchain": {c: len(v) for c, v in found.items()},
                            "evidence": sorted(p for v in found.values() for p in v)[:4],
                            "toolchain_bytes": tbytes})
    except Broken as e:
        print(f"::error::runtime toolchain gate BROKEN: {e}")
        print("Runtime toolchain gate: BROKEN — the baked images were NOT inspected")
        return 2

    blocking = 0
    n_allowed = n_new = n_expired = 0
    seen = set()
    for r in results:
        if not r["toolchain"]:
            continue
        seen.add(r["image"])
        what = ", ".join(f"{c}" for c in sorted(r["toolchain"]))
        mb = r["toolchain_bytes"] / 1e6
        ev = "; ".join(r["evidence"])
        entry = allow.get(r["image"])
        if entry and entry[0] >= today:
            n_allowed += 1
            r["verdict"] = "allowlisted"
            print(f"ALLOWLISTED {r['image']}: build toolchain ({what}; ~{mb:.0f} MB in the compiler trees alone, not counting -dev packages/LLVM) — {entry[1]} until {entry[0]} ({entry[2]})")
            continue
        if entry:
            n_expired += 1
            r["verdict"] = "expired"
            msg = (f"{r['image']}: build toolchain ({what}; ~{mb:.0f} MB in the compiler trees alone) and its allowlist entry EXPIRED on {entry[0]} "
                   f"({entry[1]}). Remove the toolchain or renew the entry with a reason. Evidence: {ev}")
        else:
            n_new += 1
            r["verdict"] = "not_allowlisted"
            msg = (f"{r['image']}: the baked container ships a build toolchain ({what}; ~{mb:.0f} MB in the compiler trees alone) — runtime images carry "
                   f"no compiler (ADR-0044 §2.2). Build in a builder stage. Evidence: {ev}")
        if mode == "enforce":
            blocking += 1
            print(f"::error::{msg}")
        else:
            print(f"::warning::REPORT MODE (would FAIL in enforce): {msg}")
    for img, (until, ticket, _) in sorted(allow.items()):
        if img not in seen:
            present = any(r["image"] == img for r in results)
            why = "ships no toolchain any more" if present else "is not baked into this image"
            print(f"NOTICE: allowlist entry {img} ({ticket}, until {until}) is unused — the image {why}; remove the entry")

    with_tc = sum(1 for r in results if r["toolchain"])
    summary = (f"Runtime toolchain gate (mode={mode}): {len(results)} images inspected, {with_tc} with a build toolchain "
               f"({n_allowed} allowlisted, {n_new} not allowlisted, {n_expired} expired), {blocking} blocking")
    if a.summary_json:
        with open(a.summary_json, "w") as fh:
            json.dump({"mode": mode, "today": str(today), "images": results,
                       "counts": {"inspected": len(results), "with_toolchain": with_tc, "allowlisted": n_allowed,
                                  "not_allowlisted": n_new, "expired": n_expired, "blocking": blocking}}, fh, indent=1)
    print(summary)
    return 1 if blocking else 0


def guarded_main():
    """Exit 1 is reserved for an enforce-mode finding; anything else that goes wrong is 2."""
    try:
        return main()
    except SystemExit as e:  # argparse usage errors exit 2 already; keep any explicit code
        return e.code if isinstance(e.code, int) else 2
    except Exception as e:  # noqa: BLE001
        print(f"::error::runtime toolchain gate BROKEN: unexpected {type(e).__name__}: {e}")
        print("Runtime toolchain gate: BROKEN — the baked images were NOT inspected")
        return 2


if __name__ == "__main__":
    sys.exit(guarded_main())
