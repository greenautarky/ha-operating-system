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
# version.yaml as it stood for the bake this fixture came from: the board's release marker is the
# PINNED one of that bake (fixtures/<board>/gaos_release.txt), not the live one, so bumping the
# marker for the next rc does not turn GA-REL-03 red against a fixture of the previous bake.
# Everything else in version.yaml stays the live file.
_key=gaos_release; [ "$BOARD" = ihost ] || _key="gaos_release_${BOARD}"
_rel="$(head -1 "$FX/gaos_release.txt" 2>/dev/null | tr -d '[:space:]')"
[ -n "$_rel" ] || { echo "make-fixture: $FX/gaos_release.txt missing or empty (pin the fixture's release marker)" >&2; exit 2; }
grep -qE "^${_key}:" "$ROOT/version.yaml" || { echo "make-fixture: version.yaml has no ${_key}" >&2; exit 2; }
rm -f "$W/src/version.yaml"
sed -E "s/^(${_key}:)[[:space:]]*[^#[:space:]]+/\\1 ${_rel}/" "$ROOT/version.yaml" > "$W/src/version.yaml"
cp -a "$ROOT/buildroot-external" "$W/src/buildroot-external"
tar -xJf "$FX/synced.tar.xz" -C "$W/src/buildroot-external/rootfs-overlay" --strip-components=1
OUT="$W/src/ga_output"
tar -xJf "$FX/ga_output.tar.xz" -C "$W/src"
# Verbatim overlay scripts whose RULE changed after the fixture's bake: the fixture target holds
# the old copy, and a check on it (e.g. RAUC-03/04 on ga-rauc-install, #1631) would judge the old
# file against today's rule. Only files listed in overlay-refresh.txt are refreshed from the live
# overlay; most overlay files are NOT copied 1:1 by the bake (keys, PSKs, perms), so no blanket copy.
# Drop an entry once the fixtures are re-captured from a bake that already carries it.
_ovl="$ROOT/buildroot-external/rootfs-overlay"; _tgt="$OUT/target"; _n=0
while IFS= read -r _f; do
  case "$_f" in ''|'#'*) continue ;; esac
  [ -f "$_ovl/$_f" ] && [ -f "$_tgt/$_f" ] || { echo "make-fixture: overlay-refresh entry '$_f' missing in overlay or fixture target" >&2; exit 2; }
  # keep the fixture file's own mtime: SRC-19 flags target files newer than the sealed rootfs
  cp "$_ovl/$_f" "$_tgt/$_f.new" && touch -r "$_tgt/$_f" "$_tgt/$_f.new" && chmod --reference="$_tgt/$_f" "$_tgt/$_f.new" && mv "$_tgt/$_f.new" "$_tgt/$_f" || exit 2; _n=$((_n+1))
done < "$HERE/overlay-refresh.txt"
[ "$_n" -gt 0 ] || { echo "make-fixture: overlay-refresh.txt lists no file" >&2; exit 2; }
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
import os
# Platform every baked image declares, per the board's arch (inferred from the archive names: the
# board's image refs carry armv7 / aarch64). The CAPTURED rc3 Core config has NO variant (the
# BOSv1.6.0-rc4 defect, Odoo #1637: the cached archive was written by skopeo 1.2.2); the fixture
# stands for a bake of the FIXED fetch, so the Core's variant is set here. FIXTURE_CORE_NO_VARIANT=1
# keeps the capture as it was (the red proof of VER-12).
names = " ".join(glob.glob(f"{img}/*.tar"))
plat = {"os": "linux", "architecture": "arm64"} if "aarch64" in names else {"os": "linux", "architecture": "arm", "variant": "v7"}
def with_plat(cfgj):
    c = json.loads(cfgj); c.update(plat); return json.dumps(c).encode()
def oci(path, cfgb):
    cd_ = hashlib.sha256(cfgb).hexdigest()
    m_ = json.dumps({"schemaVersion": 2, "config": {"digest": "sha256:" + cd_, "size": len(cfgb)}, "layers": []}).encode()
    md_ = hashlib.sha256(m_).hexdigest()
    with tarfile.open(path, "w") as t_:
        add(t_, "index.json", json.dumps({"schemaVersion": 2, "manifests": [{"digest": "sha256:" + md_}]}).encode())
        add(t_, "blobs/sha256/" + md_, m_); add(t_, "blobs/sha256/" + cd_, cfgb)
cfg = open(f"{fx}/core-image.json", "rb").read()
if not os.environ.get("FIXTURE_CORE_NO_VARIANT"):
    cfg = with_plat(cfg)
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
    add(t, "cfg.json", json.dumps(plat).encode()); add(t, "layer0.tar", layer.getvalue())
    add(t, "manifest.json", json.dumps([{"Config": "cfg.json", "RepoTags": [], "Layers": ["layer0.tar"]}]).encode())
# every other baked archive: a minimal OCI archive with the board's platform (content is read by no test)
for f_ in glob.glob(f"{img}/*.tar"):
    if os.path.getsize(f_) == 0:
        oci(f_, json.dumps(dict(plat, config={})).encode())
PY
# release artefacts: first only their existence/age (a signed multi-hundred-MB bundle and a disk image cannot
# live in a fixture) ...
mkdir -p "$OUT/images"
while read -r sz nm; do case "$nm" in *.sha256) ;; images/*) : > "$OUT/$nm" ;; esac; done < "$FX/sizes.txt"
touch -d '2026-01-01' "$OUT"/images/rootfs.erofs 2>/dev/null || : > "$OUT/images/rootfs.erofs"; touch -d '2026-01-01' "$OUT/images/rootfs.erofs"
touch "$OUT"/images/*.raucb "$OUT"/images/*.img.xz
# ... and then replaced by minimal SYNTHETIC ones the real checks can open (Odoo #1632)
"$HERE/synth-release-artefacts.sh" "$OUT" || { echo "make-fixture: synthetic release artefacts failed" >&2; exit 2; }
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
