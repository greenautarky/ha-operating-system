#!/bin/bash
# make-fixture.sh BOARD WORKDIR -- build, from the committed capture of a REAL bake (fixtures/BOARD/,
# see capture-fixture.py), the tree the build tests run on, the way ga_build.sh leaves it:
#   WORKDIR/src                the source tree (symlinks to this checkout + the synced Tier-2 files)
#   WORKDIR/src/ga_output      the build output (OUT; the runner finds the source tree as OUT/..)
#   WORKDIR/buildroot          BUILDROOT_DIR with the one pinned Go version line
# Prints nothing but the path of OUT on the last line.
set -eu
BOARD="${1:?board}"; W="${2:?workdir}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
FX="$HERE/fixtures/$BOARD"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$ROOT/scripts/lib/tree-paths.sh"
[ -d "$FX" ] || { echo "make-fixture: no fixture for board '$BOARD' ($FX)" >&2; exit 2; }
rm -rf "$W"; mkdir -p "$W/src" "$W/buildroot/package/go"
# source tree: everything is this checkout, except buildroot-external (the synced files land in it)
# HIDE_BOARDS="ihost ..." leaves those boards' directories OUT of the source tree (the isolation probe)
_hide="^(\.git|buildroot-external|ga_output.*"
for _hb in ${HIDE_BOARDS:-}; do _hide="$_hide|$(ga_board_var BOARD_DIR "$_hb")"; done
for e in $(ls -A "$ROOT" | grep -vE "$_hide)\$"); do ln -s "$ROOT/$e" "$W/src/$e"; done
cp -a "$ROOT/buildroot-external" "$W/src/buildroot-external"
tar -xJf "$FX/synced.tar.xz" -C "$W/src/buildroot-external/rootfs-overlay" --strip-components=1
OUT="$W/src/ga_output"
tar -xJf "$FX/ga_output.tar.xz" -C "$W/src"
cp "$FX/go.mk" "$W/buildroot/package/go/go.mk"
HV="$OUT/build/hassio-1.0.0"; IMG="$HV/images"; mkdir -p "$IMG" "$OUT/host/bin"
cp "$FX/version.json" "$HV/version.json"
# the baked image archives (names exactly as the real bake wrote them); content only where a test reads it
while IFS= read -r n; do [ -n "$n" ] && : > "$IMG/$n"; done < "$FX/images.txt"
python3 - "$FX" "$IMG" <<'PY'
import glob, hashlib, io, json, sys, tarfile
fx, img = sys.argv[1], sys.argv[2]
def add(t, name, data):
    ti = tarfile.TarInfo(name); ti.size = len(data); ti.mtime = 1_700_000_000; t.addfile(ti, io.BytesIO(data))
# Core: an OCI archive (HAOS 18.x skopeo oci-archive): index.json -> manifest -> config (labels)
cfg = open(f"{fx}/core-image.json", "rb").read()
cd = hashlib.sha256(cfg).hexdigest()
man = json.dumps({"schemaVersion": 2, "config": {"digest": "sha256:" + cd, "size": len(cfg), "mediaType": "application/vnd.oci.image.config.v1+json"}, "layers": []}).encode()
md = hashlib.sha256(man).hexdigest()
(core,) = glob.glob(f"{img}/ghcr.io_greenautarky_home-assistant-*.tar")
with tarfile.open(core, "w") as t:
    add(t, "index.json", json.dumps({"schemaVersion": 2, "manifests": [{"digest": "sha256:" + md, "mediaType": "application/vnd.oci.image.manifest.v1+json", "size": len(man)}]}).encode())
    add(t, "blobs/sha256/" + md, man); add(t, "blobs/sha256/" + cd, cfg)
# ga_manager: a docker-archive with ONE layer holding the files the capability checker inspects
(gm,) = glob.glob(f"{img}/ghcr.io_greenautarky_ga_manager-*.tar")
layer = io.BytesIO()
with tarfile.open(fx + "/ga_manager-files.tar") as src, tarfile.open(fileobj=layer, mode="w") as lt:
    for m in src.getmembers():
        add(lt, m.name, src.extractfile(m).read())
with tarfile.open(gm, "w") as t:
    add(t, "cfg.json", b"{}"); add(t, "layer0.tar", layer.getvalue())
    add(t, "manifest.json", json.dumps([{"Config": "cfg.json", "RepoTags": [], "Layers": ["layer0.tar"]}]).encode())
PY
# release artefacts: only their existence/age is reproduced (a signed multi-hundred-MB bundle and a disk
# image cannot live in a fixture); the checks that open them are the pinned NOT_COVERED set in selftest.sh
mkdir -p "$OUT/images"
while read -r sz nm; do case "$nm" in *.sha256) ;; images/*) : > "$OUT/$nm" ;; esac; done < "$FX/sizes.txt"
touch -d '2026-01-01' "$OUT"/images/rootfs.erofs 2>/dev/null || : > "$OUT/images/rootfs.erofs"; touch -d '2026-01-01' "$OUT/images/rootfs.erofs"
touch "$OUT"/images/*.raucb "$OUT"/images/*.img.xz
# the Buildroot .config of the build (the real ga_output/.config; images/configs/buildroot.config is its archived copy)
[ -f "$OUT/images/configs/buildroot.config" ] && cp "$OUT/images/configs/buildroot.config" "$OUT/.config"
# host Go: replays what the real `go version [-m] target/` printed in this bake; the verdict code is the real one
cat > "$OUT/host/bin/go" <<GO
#!/bin/bash
M="$FX/go-version-m.txt"
V="\$(sed -n 's/^[^ ]*: \(go[0-9][^ ]*\).*/\1/p' "\$M" | head -1)"
[ "\${1:-}" = version ] || exit 2
shift
case "\${1:-}" in
  "") echo "go version \$V linux/amd64" ;;
  -m) sed "s#^target/#\${2%/}/#" "\$M" ;;
  *)  grep -E '^target/[^ ]*: go[0-9]' "\$M" | sed "s#^target/#\${1%/}/#" ;;
esac
GO
chmod +x "$OUT/host/bin/go"
[ -x "$FX/reconstruct.sh" ] && [ -z "${FIXTURE_NO_RECONSTRUCT:-}" ] && "$FX/reconstruct.sh" "$OUT"
echo "$OUT"
