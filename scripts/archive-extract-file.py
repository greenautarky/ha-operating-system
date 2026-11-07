#!/usr/bin/env python3
"""Print one file out of a container image archive (docker-archive or OCI archive), the way the
image would show it: layers applied in order, the LAST layer that carries the path wins, a whiteout
deletes it.

  archive-extract-file.py <archive.tar> <path-inside-image>   # file content on stdout

Exit: 0 found, 3 the image does not contain the path, 2 BROKEN CHECK (archive unreadable / no layers
at all -- "I could not look" is not "it is not there"). Used by the build tests that read the baked
Supervisor image (BLD-SUP-DNS, INT-05, SVC-09*), Odoo #1649."""
import io, json, sys, tarfile


def die(msg, rc=2):
    print(f"archive-extract-file: {msg}", file=sys.stderr)
    sys.exit(rc)


def layer_names(t):
    names = {m.name for m in t.getmembers()}
    if "manifest.json" in names:  # docker-archive
        man = json.load(t.extractfile("manifest.json"))
        return list(man[0]["Layers"])
    if "index.json" in names:  # OCI archive: index -> manifest -> layers
        idx = json.load(t.extractfile("index.json"))
        dg = idx["manifests"][0]["digest"].split(":", 1)[1]
        man = json.load(t.extractfile("blobs/sha256/" + dg))
        return ["blobs/sha256/" + l["digest"].split(":", 1)[1] for l in man.get("layers", [])]
    die("neither manifest.json nor index.json in the archive")


def main():
    if len(sys.argv) != 3:
        die("usage: archive-extract-file.py <archive.tar> <path>")
    arch, want = sys.argv[1], sys.argv[2].lstrip("./")
    dirn, base = want.rsplit("/", 1) if "/" in want else ("", want)
    try:
        t = tarfile.open(arch)
        layers = layer_names(t)
    except (OSError, tarfile.TarError, KeyError, ValueError, IndexError) as e:
        die(f"cannot read {arch}: {e}")
    if not layers:
        die(f"{arch} has no layers - nothing was inspected")
    found = None
    for ln in layers:
        raw = t.extractfile(ln).read()
        try:
            lt = tarfile.open(fileobj=io.BytesIO(raw), mode="r:*")  # gzip or plain
            for m in lt.getmembers():
                n = m.name.lstrip("./")
                if n == want and m.isfile():
                    found = lt.extractfile(m).read()
                elif n == (dirn + "/.wh." + base if dirn else ".wh." + base):
                    found = None
        except tarfile.TarError as e:
            die(f"layer {ln} unreadable: {e}")
    if found is None:
        die(f"{want} is not in the image", 3)
    sys.stdout.buffer.write(found)


main()
