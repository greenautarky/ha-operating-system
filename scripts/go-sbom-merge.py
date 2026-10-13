#!/usr/bin/env python3
"""Add Go module components to a CycloneDX SBOM.

Input is the text `go version -m <dir>` prints (produced by ga_go_scan_mods in
scripts/lib/go-toolchain.sh - the same reader GOTC-05 uses; this file parses its
output, it never runs a second reader). One header line per Go binary
("usr/bin/netbird: go1.26.9"), then tab-indented build-info lines:
    path <main package>   mod <module> <version>   dep <module> <version> <sum>
    =>  <replacement> <version> <sum>   (applies to the dep line above it)

Each module becomes a component with purl pkg:golang/<module>@<version>, and the
Buildroot package that installed the binary (packages-file-list.txt) gets a
dependsOn entry for it. Components are de-duplicated by (module, version).

Exit codes (fail loudly, never silently):
  0  merged; the summary line is printed
  1  Go binaries exist but ZERO modules were extracted (the reader is broken, not the image)
  2  ZERO Go binaries in the input (a scan over nothing), or unreadable input
"""
import argparse
import json
import re
import sys
from urllib.parse import quote

HEADER = re.compile(r"^(\S.*): (go\S+)(?: .*)?$")


def parse_mods(text):
    """-> list of (binary, goversion, [(module, version, replaced_from_or_None)])"""
    bins = []
    cur = None
    last = None  # index of the last dep/mod entry in cur's list
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            m = HEADER.match(line)
            if not m:
                continue  # stderr noise / unrecognised line: not a binary header
            cur = (m.group(1), m.group(2), [])
            bins.append(cur)
            last = None
            continue
        if cur is None:
            continue
        f = line.lstrip("\t ").split("\t")
        kind = f[0]
        if kind == "mod":
            last = None  # the main module is the shipping package itself, not a dependency
        elif kind == "dep" and len(f) >= 3:
            cur[2].append([f[1], f[2], None])
            last = len(cur[2]) - 1
        elif kind == "=>" and last is not None and len(f) >= 2:
            ent = cur[2][last]
            # What is LINKED is the replacement. A local-path replacement has no
            # version: keep the original coordinates, record that it was replaced.
            if len(f) >= 3 and f[2].startswith("v"):
                ent[2] = ent[0]
                ent[0], ent[1] = f[1], f[2]
            else:
                ent[2] = "local:" + f[1]
    return [(b, v, [tuple(e) for e in ents]) for b, v, ents in bins]


def purl(module, version):
    # purl-spec: golang names are lowercase; '+' in the version must be encoded.
    return "pkg:golang/%s@%s" % (quote(module.lower(), safe="/"), quote(version, safe=""))


def load_file_list(path):
    """packages-file-list.txt: 'pkg,./usr/bin/x' -> {'usr/bin/x': 'pkg'}"""
    m = {}
    with open(path) as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if "," not in ln:
                continue
            pkg, p = ln.split(",", 1)
            m[p[2:] if p.startswith("./") else p.lstrip("/")] = pkg
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sbom")
    ap.add_argument("--mods", required=True, help="file with `go version -m` output")
    ap.add_argument("--file-list", required=True, help="buildroot packages-file-list.txt")
    a = ap.parse_args()

    try:
        with open(a.sbom) as fh:
            bom = json.load(fh)
        with open(a.mods) as fh:
            bins = parse_mods(fh.read())
        owner = load_file_list(a.file_list)
    except (OSError, ValueError) as e:
        print("GO-SBOM ERROR: cannot read input: %s" % e, file=sys.stderr)
        return 2

    if not bins:
        print("GO-SBOM ERROR: zero Go binaries in the scan - a scan over nothing is not a pass", file=sys.stderr)
        return 2

    comps = bom.setdefault("components", [])
    deps = bom.setdefault("dependencies", [])
    have = {c.get("bom-ref") for c in comps}
    dep_by_ref = {d["ref"]: d for d in deps}
    root = (bom.get("metadata", {}).get("component") or {}).get("bom-ref")
    modules = {}  # bom-ref -> component
    unattributed = []

    for binary, gover, ents in bins:
        pkg = owner.get(binary)
        if pkg is None or pkg not in have:
            unattributed.append(binary)
            pkg = root
        for module, version, repl in ents:
            if not re.match(r"^v\d", version):
                continue  # pseudo/unversioned (e.g. "(devel)"): no purl version to state
            ref = purl(module, version)
            if ref not in modules:
                c = {
                    "bom-ref": ref,
                    "type": "library",
                    "name": module,
                    "version": version,
                    "purl": ref,
                    "properties": [{"name": "ga:go-module", "value": "true"}],
                }
                if repl:
                    c["properties"].append({"name": "ga:go-replaces", "value": repl})
                modules[ref] = c
            props = modules[ref]["properties"]
            tag = {"name": "ga:go-binary", "value": binary}
            if tag not in props:
                props.append(tag)
            if pkg is not None:
                d = dep_by_ref.get(pkg)
                if d is None:
                    d = {"ref": pkg, "dependsOn": []}
                    deps.append(d)
                    dep_by_ref[pkg] = d
                if ref not in d["dependsOn"]:
                    d["dependsOn"] = sorted(d["dependsOn"] + [ref])

    if not modules:
        print("GO-SBOM ERROR: %d Go binaries but ZERO modules extracted - the reader is broken, not the image" % len(bins), file=sys.stderr)
        return 1

    added = 0
    for ref, c in modules.items():
        if ref not in have:
            comps.append(c)
            added += 1

    with open(a.sbom, "w") as fh:
        json.dump(bom, fh, indent=2)
        fh.write("\n")
    print("GO-SBOM: binaries=%d modules=%d components_added=%d unattributed_binaries=%d%s"
          % (len(bins), len(modules), added, len(unattributed),
             (" (" + ", ".join(unattributed) + ")") if unattributed else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
