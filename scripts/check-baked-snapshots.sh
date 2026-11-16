#!/usr/bin/env bash
# =============================================================================
# check-baked-snapshots.sh -- the baked container images are UNPACKED in the data partition.
# =============================================================================
# WHY: BOSv1.6.0-rc13 carried all 15 baked images as compressed content only; the containerd
# snapshot store (overlayfs/snapshots) was EMPTY. The device therefore unpacked every image at its
# first container create / add-on install: Home Assistant Core alone took 9 min 04 s of a ~15 min
# first boot, every add-on install 35-72 s (Odoo #2067 / #2065). The cause is the bake's plain
# `docker load` of a foreign-platform archive on an amd64 builder (fix: `docker load --platform`,
# patch 0135). Nothing in the build looked at the snapshot store.
#
# WHAT: reads the finished data.ext4 (read-only, debugfs -- no mount, no root) and counts the
# committed snapshots in
#   /docker/containerd/daemon/io.containerd.snapshotter.v1.overlayfs/snapshots
# A committed snapshot is a numeric directory with an `fs` subdirectory. FAIL when
#   * the snapshot directory is missing or holds fewer than MIN_SNAPSHOTS (pinned constant below,
#     never derived from the artefact being judged), or
#   * --images-dir is given and there are fewer snapshots than the number of DISTINCT image layer
#     chains in the baked archives (the INPUTS: chainID = sha256(parent " " diffID) over every
#     rootfs.diff_ids, shared base layers counted once) -- i.e. some baked image has no
#     committed snapshot for one of its layers.
# FAIL CLOSED: an unreadable data.ext4, an unreadable archive, or zero archives with
# --images-dir is a failure, never a pass.
#
#   check-baked-snapshots.sh --data-img data.ext4 [--images-dir DIR] [--mode enforce|report]
# MODE (env GA_SNAPSHOT_GATE_MODE, default below): enforce = exit 1 on a finding; report = print
# the finding loudly and exit 0 (used until the bake unpacks, i.e. until patch 0135 is in).
# The selftest is tests/gates/baked_snapshots/selftest.sh and always passes --mode explicitly.
set -uo pipefail

SNAP_DIR=/docker/containerd/daemon/io.containerd.snapshotter.v1.overlayfs/snapshots
# Pinned floor: Home Assistant Core alone is 27 layers (rc13), the Supervisor and the add-on bases
# add more; an unpacked bake has well over 100. 40 separates "unpacked" from "empty / one image"
# with a wide margin and survives Core shrinking (epic #1964).
MIN_SNAPSHOTS=40
DEFAULT_MODE=report

IMG=""; IMAGES_DIR=""; MODE="${GA_SNAPSHOT_GATE_MODE:-$DEFAULT_MODE}"
while [ $# -gt 0 ]; do
	case "$1" in
		--data-img) IMG="${2:-}"; shift 2 ;;
		--images-dir) IMAGES_DIR="${2:-}"; shift 2 ;;
		--mode) MODE="${2:-}"; shift 2 ;;
		*) echo "usage: $0 --data-img data.ext4 [--images-dir DIR] [--mode enforce|report]" >&2; exit 2 ;;
	esac
done
case "$MODE" in enforce|report) ;; *) echo "check-baked-snapshots: --mode must be enforce or report (got '${MODE}')" >&2; exit 2 ;; esac

problems=0
finding() { echo "  BAD   $*"; problems=$((problems + 1)); }
finish() {
	echo "baked snapshots: ${n_snap:-0} committed, floor ${MIN_SNAPSHOTS}${expected:+, ${expected} distinct layer chain(s) in the archives}, ${problems} problem(s) [mode ${MODE}]"
	if [ "$problems" -gt 0 ] && [ "$MODE" = report ]; then
		echo "check-baked-snapshots: REPORT-ONLY: the images are NOT unpacked in this data partition -- first boot unpacks them on the device (Odoo #2067); enforcing once patch 0135 is baked" >&2
		exit 0
	fi
	[ "$problems" -eq 0 ]; exit $?
}

command -v debugfs >/dev/null 2>&1 || { echo "check-baked-snapshots: FAIL: debugfs missing" >&2; exit 1; }
[ -f "$IMG" ] || { echo "check-baked-snapshots: FAIL: no data image '${IMG}'" >&2; exit 1; }

n_snap=0; expected=""
if ! out=$(debugfs -R "ls -p ${SNAP_DIR}" "$IMG" 2>/dev/null) || [ -z "$out" ]; then
	finding "cannot list ${SNAP_DIR} in ${IMG} (no containerd overlayfs snapshot directory)"
	finish
fi
# ls -p lines: /inode/mode/uid/gid/name/size/ ; keep numeric names, and require an fs/ directory in each
names=$(printf '%s\n' "$out" | awk -F/ '$6 ~ /^[0-9]+$/ {print $6}')
for n in $names; do
	# debugfs exits 0 even for a missing path: judge its output, not its status
	if debugfs -R "stat ${SNAP_DIR}/${n}/fs" "$IMG" 2>&1 | grep -q '^Inode: '; then n_snap=$((n_snap + 1))
	else finding "snapshot ${n} has no fs/ directory (not committed)"; fi
done
[ "$n_snap" -ge "$MIN_SNAPSHOTS" ] || finding "${n_snap} committed snapshot(s), need at least ${MIN_SNAPSHOTS} -- the baked images are not unpacked"

if [ -n "$IMAGES_DIR" ]; then
	command -v python3 >/dev/null 2>&1 || { echo "check-baked-snapshots: FAIL: python3 missing" >&2; exit 1; }
	[ -d "$IMAGES_DIR" ] || { echo "check-baked-snapshots: FAIL: no images dir '${IMAGES_DIR}'" >&2; exit 1; }
	if ! expected=$(python3 -I - "$IMAGES_DIR" <<'PY'
import glob, hashlib, json, sys, tarfile
chains = set()
files = sorted(glob.glob(sys.argv[1] + "/*.tar"))
if not files:
    sys.exit("no archive in " + sys.argv[1])
for f in files:
    t = tarfile.open(f)
    names = {n[2:] if n.startswith("./") else n: n for n in t.getnames()}
    def get(n):
        return json.load(t.extractfile(names[n]))
    def blob(d):
        return get("blobs/sha256/" + d.split(":")[1])
    try:
        if "index.json" in names:                              # OCI archive
            man = blob(get("index.json")["manifests"][0]["digest"])
            cfg = blob(man["config"]["digest"])
        else:                                                  # docker-archive
            cfg = get(get("manifest.json")[0]["Config"])
        diffs = cfg["rootfs"]["diff_ids"]
    except Exception as e:
        sys.exit("unreadable archive %s: %s" % (f, e))
    prev = None
    for d in diffs:
        prev = d if prev is None else "sha256:" + hashlib.sha256((prev + " " + d).encode()).hexdigest()
        chains.add(prev)
print(len(chains))
PY
	); then
		finding "cannot read the layer chains of the archives in ${IMAGES_DIR}"
	elif [ "$n_snap" -lt "$expected" ]; then
		finding "${n_snap} committed snapshot(s) for ${expected} distinct layer chain(s) in the archives -- at least one baked image is not (fully) unpacked"
	fi
fi
finish
