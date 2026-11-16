#!/usr/bin/env bash
# selftest.sh -- scripts/check-baked-snapshots.sh (the LIVE script) goes red on a data partition
# whose containerd snapshot store is empty / not committed and green on an unpacked one
# (Odoo #2067: BOSv1.6.0-rc13 baked 15 images with ZERO snapshots; first boot unpacked them).
# Fixtures: must-fail/ and must-pass/ hold layout specs (one directive per line):
#   mkdir PATH | file PATH | snap N (N committed snapshots 1..N, each with fs/) | snapnofs N
# Each is built into a throwaway ext4 (mkfs.ext4 -d, no root) and handed to the gate.
# The floor is READ from the live script (MIN_SNAPSHOTS), never copied here; if it cannot be
# found the self-test FAILS. Also proven: the --images-dir cross-check (distinct layer chains,
# shared base layers counted once), fail-closed cases, and that report mode exits 0 but loudly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-baked-snapshots.sh"
[ -x "$GATE" ] || { echo "FATAL: $GATE missing"; exit 1; }
for t in debugfs mkfs.ext4 python3 sha256sum; do command -v $t >/dev/null || { echo "FATAL: $t missing"; exit 1; }; done
FLOOR="$(sed -n 's/^MIN_SNAPSHOTS=\([0-9][0-9]*\)$/\1/p' "$GATE")"
[ -n "$FLOOR" ] || { echo "FAIL: cannot extract MIN_SNAPSHOTS from the live gate -- extraction stopped finding the definition"; exit 1; }
SNAP=docker/containerd/daemon/io.containerd.snapshotter.v1.overlayfs/snapshots
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }

# build SPECFILE OUT.ext4
build() {
  local root="$W/tree.$$.$RANDOM"; mkdir -p "$root"
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) ;;
      mkdir\ *) mkdir -p "$root${line#mkdir }" ;;
      file\ *)  mkdir -p "$(dirname "$root${line#file }")"; echo x > "$root${line#file }" ;;
      snap\ *)  for i in $(seq 1 "${line#snap }"); do mkdir -p "$root/$SNAP/$i/fs"; done ;;
      snapnofs\ *) for i in $(seq 1 "${line#snapnofs }"); do mkdir -p "$root/$SNAP/$i"; done ;;
      *) echo "FATAL: bad directive '$line' in $1"; exit 1 ;;
    esac
  done < "$1"
  mkfs.ext4 -q -d "$root" "$2" 16M >/dev/null 2>&1 || { echo "FATAL: mkfs.ext4 failed for $1"; exit 1; }
  rm -rf "$root"
}
# spec_n N -> temp spec with N committed snapshots
spec_n() { echo "snap $1" > "$W/spec.$1"; echo "$W/spec.$1"; }
run() { OUT="$("$GATE" "$@" 2>&1)"; RC=$?; }

cases=0
for verdict in must-fail must-pass; do
  for f in "$HERE/$verdict"/*.txt; do
    cases=$((cases+1)); name="$(basename "$f" .txt)"; img="$W/$verdict-$name.ext4"; build "$f" "$img"
    run --data-img "$img" --mode enforce
    if [ "$verdict" = must-fail ]; then
      [ "$RC" = 1 ] && grep -q ' BAD ' <<<"$OUT" && ok "$verdict/$name -> red" || bad "$verdict/$name rc=$RC :: $OUT"
    else
      [ "$RC" = 0 ] && grep -q ' 0 problem' <<<"$OUT" && ok "$verdict/$name -> green" || bad "$verdict/$name rc=$RC :: $OUT"
    fi
  done
done
[ "$cases" -ge 7 ] || bad "only $cases fixtures ran"

# the pinned floor, read from the live gate: floor-1 red, floor green
build "$(spec_n $((FLOOR-1)))" "$W/below.ext4"; run --data-img "$W/below.ext4" --mode enforce
[ "$RC" = 1 ] && ok "floor-1 (${FLOOR}-1) snapshots -> red" || bad "floor-1 rc=$RC :: $OUT"
build "$(spec_n "$FLOOR")" "$W/at.ext4"; run --data-img "$W/at.ext4" --mode enforce
[ "$RC" = 0 ] && ok "floor ($FLOOR) snapshots -> green" || bad "floor rc=$RC :: $OUT"

# --images-dir cross-check. mkoci DIR NAME BASE_LAYERS OWN_LAYERS: an OCI archive whose config lists
# the BASE layers shared by all images plus OWN unique layers.
mkoci() { python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import hashlib, io, json, sys, tarfile, os
d, name, nb, no = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
os.makedirs(d, exist_ok=True)
diffs = ["sha256:" + hashlib.sha256(("base%d" % i).encode()).hexdigest() for i in range(nb)] + \
        ["sha256:" + hashlib.sha256((name + str(i)).encode()).hexdigest() for i in range(no)]
cfg = json.dumps({"architecture": "arm", "os": "linux", "variant": "v7", "rootfs": {"type": "layers", "diff_ids": diffs}}).encode()
cd = hashlib.sha256(cfg).hexdigest()
man = json.dumps({"schemaVersion": 2, "config": {"digest": "sha256:" + cd, "size": len(cfg)}, "layers": []}).encode()
md = hashlib.sha256(man).hexdigest()
idx = json.dumps({"schemaVersion": 2, "manifests": [{"digest": "sha256:" + md}]}).encode()
with tarfile.open(os.path.join(d, name + ".tar"), "w") as t:
    for n, b in (("index.json", idx), ("blobs/sha256/" + md, man), ("blobs/sha256/" + cd, cfg)):
        ti = tarfile.TarInfo(n); ti.size = len(b); t.addfile(ti, io.BytesIO(b))
PY
}
# 2 images, 45 shared base layers + 10 own each = 45 + 20 = 65 distinct chains
mkoci "$W/imgs" a 45 10; mkoci "$W/imgs" b 45 10
build "$(spec_n 65)" "$W/s65.ext4"; build "$(spec_n 64)" "$W/s64.ext4"; build "$(spec_n 110)" "$W/s110.ext4"
run --data-img "$W/s65.ext4" --images-dir "$W/imgs" --mode enforce
[ "$RC" = 0 ] && grep -q '65 distinct' <<<"$OUT" && ok "65 snapshots for 65 distinct chains (shared base counted once) -> green" || bad "65/65 rc=$RC :: $OUT"
run --data-img "$W/s64.ext4" --images-dir "$W/imgs" --mode enforce
[ "$RC" = 1 ] && grep -q 'at least one baked image' <<<"$OUT" && ok "64 snapshots for 65 chains (above the floor, one layer missing) -> red" || bad "64/65 rc=$RC :: $OUT"
run --data-img "$W/s110.ext4" --images-dir "$W/imgs" --mode enforce
[ "$RC" = 0 ] && ok "more snapshots than chains -> green" || bad "110/65 rc=$RC :: $OUT"
mkdir "$W/noimgs"; run --data-img "$W/s65.ext4" --images-dir "$W/noimgs" --mode enforce
[ "$RC" = 1 ] && ok "--images-dir with zero archives -> red (fail closed)" || bad "zero archives rc=$RC :: $OUT"
mkdir "$W/junk"; echo notatar > "$W/junk/x.tar"; run --data-img "$W/s65.ext4" --images-dir "$W/junk" --mode enforce
[ "$RC" = 1 ] && ok "unreadable archive -> red" || bad "junk rc=$RC :: $OUT"

# fail closed on the artefact itself
run --data-img "$W/does-not-exist.ext4" --mode enforce; [ "$RC" = 1 ] && ok "missing data image -> red" || bad "missing img rc=$RC"
echo notext4 > "$W/notext4.img"; run --data-img "$W/notext4.img" --mode enforce
[ "$RC" = 1 ] && ok "not an ext4 image -> red" || bad "not ext4 rc=$RC :: $OUT"
run --data-img "$W/at.ext4" --mode bogus; [ "$RC" = 2 ] && ok "unknown mode -> usage error" || bad "bogus mode rc=$RC"

# report mode: same finding, exit 0, loud
build "$HERE/must-fail/rc13-empty-snapshot-store.txt" "$W/rep.ext4"
run --data-img "$W/rep.ext4" --mode report
[ "$RC" = 0 ] && grep -q 'REPORT-ONLY' <<<"$OUT" && grep -q ' BAD ' <<<"$OUT" && ok "report mode: finding printed, exit 0, REPORT-ONLY announced" || bad "report mode rc=$RC :: $OUT"
GA_SNAPSHOT_GATE_MODE=enforce run --data-img "$W/rep.ext4"
[ "$RC" = 1 ] && ok "GA_SNAPSHOT_GATE_MODE=enforce overrides the default" || bad "env enforce rc=$RC :: $OUT"

[ "$ran" -gt 0 ] || { echo "FAIL: zero cases"; exit 1; }
echo "$ran cases, $fails failed (floor read from the gate: $FLOOR)"; exit $((fails > 0))
