#!/usr/bin/env python3
"""Write a synthetic image tar in the bake's layout, for the toolchain gate's fixtures.

usage: make_image.py OUT.tar NAME FORMAT LAYER [LAYER ...]
  FORMAT  oci | docker | oci-zstd-empty (OCI, plus the rc13 Core's 16-byte zstd
          empty layer labelled tar+gzip, inserted before the given layers) |
          oci-multiarch (index: arm64 clean first, arm/v7 with the layers) |
          docker-manifest=<json> | oci-index=<json> (wrong-shaped JSON only)
  LAYER   comma-separated paths; a path ending in '/' is a directory, '.wh.X'
          a whiteout, '.wh..wh..opq' an opaque marker, 'sym:PATH' a symlink.
          An empty string is an empty layer.
"""
import gzip
import hashlib
import io
import json
import sys
import tarfile

# The exact 16-byte blob found in BOSv1.6.0-rc13's Core image (one RLE block of
# 1024 zero bytes = an empty tar), labelled tar+gzip by its manifest.
RC13_ZSTD_EMPTY = bytes.fromhex("28b52ffd4408000303200000cdac85f0")


def layer_tar(spec):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for p in [x for x in spec.split(",") if x]:
            if p.startswith("sym:"):
                ti = tarfile.TarInfo(p[4:]); ti.type = tarfile.SYMTYPE; ti.linkname = "target"
                t.addfile(ti)
            elif p.endswith("/"):
                ti = tarfile.TarInfo(p.rstrip("/")); ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            else:
                data = b"x" * 64
                ti = tarfile.TarInfo(p); ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def add(t, name, data):
    ti = tarfile.TarInfo(name); ti.size = len(data)
    t.addfile(ti, io.BytesIO(data))


def raw(out, member, text):
    with tarfile.open(out, "w") as t:
        add(t, member, text.encode())


def oci_multiarch(out, name, v7_specs):
    """Index of two images: arm64 (clean) FIRST, arm/v7 (the given layers) second."""
    with tarfile.open(out, "w") as t:
        def blob(b):
            d = "sha256:" + hashlib.sha256(b).hexdigest(); add(t, "blobs/sha256/" + d[7:], b); return d
        def image(specs):
            ls = [gzip.compress(layer_tar(x), mtime=0) for x in specs]
            descs = [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": blob(b), "size": len(b)} for b in ls]
            cd = blob(b"{}")
            m = json.dumps({"schemaVersion": 2, "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                                                         "digest": cd, "size": 2}, "layers": descs}).encode()
            return blob(m), len(m)
        a64, a64n = image(["bin/sh"])
        v7, v7n = image(v7_specs)
        ix = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
            {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": a64, "size": a64n,
             "platform": {"architecture": "arm64", "os": "linux"}},
            {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": v7, "size": v7n,
             "platform": {"architecture": "arm", "variant": "v7", "os": "linux"}}]}).encode()
        ixd = blob(ix)
        add(t, "index.json", json.dumps({"schemaVersion": 2, "manifests": [{
            "mediaType": "application/vnd.oci.image.index.v1+json", "digest": ixd, "size": len(ix),
            "annotations": {"org.opencontainers.image.ref.name": name}}]}).encode())


def main():
    out, name, fmt, specs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    # Wrong-shaped but structurally valid JSON (Manager review 2026-11-12):
    #   docker-manifest=<json>  only a manifest.json with that content
    #   oci-index=<json>        only an index.json with that content
    if fmt.startswith("docker-manifest="):
        return raw(out, "manifest.json", fmt.split("=", 1)[1])
    if fmt.startswith("oci-index="):
        return raw(out, "index.json", fmt.split("=", 1)[1])
    if fmt == "oci-multiarch":
        return oci_multiarch(out, name, specs)
    layers = [gzip.compress(layer_tar(s), mtime=0) for s in specs]
    if fmt == "oci-zstd-empty":
        layers = [RC13_ZSTD_EMPTY] + layers
    with tarfile.open(out, "w") as t:
        if fmt == "docker":
            names = []
            for i, b in enumerate(layers):
                n = f"layer{i}/layer.tar"
                add(t, n, gzip.decompress(b)); names.append(n)
            add(t, "manifest.json", json.dumps([{"Config": "c.json", "RepoTags": [name], "Layers": names}]).encode())
            return
        descs = []
        for b in layers:
            d = "sha256:" + hashlib.sha256(b).hexdigest()
            add(t, "blobs/sha256/" + d[7:], b)
            descs.append({"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": d, "size": len(b)})
        cfg = b"{}"
        cd = "sha256:" + hashlib.sha256(cfg).hexdigest()
        add(t, "blobs/sha256/" + cd[7:], cfg)
        man = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                          "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": cd, "size": 2},
                          "layers": descs}).encode()
        md = "sha256:" + hashlib.sha256(man).hexdigest()
        add(t, "blobs/sha256/" + md[7:], man)
        add(t, "oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
        add(t, "index.json", json.dumps({"schemaVersion": 2, "manifests": [{
            "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": md, "size": len(man),
            "annotations": {"org.opencontainers.image.ref.name": name}}]}).encode())


if __name__ == "__main__":
    main()
