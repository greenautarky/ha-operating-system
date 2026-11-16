#!/usr/bin/env bash
# =============================================================================
# check-baked-updater.sh -- the BUILT updater.json in data.ext4 carries what version.json says.
# =============================================================================
# WHY: a fresh device has not fetched the channel yet; an updater.json that lacks a plugin (or the
# Supervisor/Core) puts the Supervisor on the UPSTREAM image name, which is not baked, so without
# internet the plugin install retries forever (Odoo #2065). BOSv1.6.0-rc1 seeded Core only and the
# source-level test SRC-06 (a grep of the script) passed. In 2026-11 a failing gen-updater-json.sh
# behind `| tee` even left a 0-byte updater.json with the bake going on (Odoo #2067).
#
# WHAT: reads /supervisor/updater.json from the finished data.ext4 (debugfs, read-only, no mount) and
# compares it with the version.json the bake read (the INPUT, never derived from the artefact):
#   cli dns audio multicast observer   version AND image, ALWAYS required
#   supervisor, homeassistant (Core)   version AND image, required when --images-dir holds that image
#                                      (a board may skip them, GA_HASSIO_SKIP_IMAGES)
#   channel                            must be present
# FAIL CLOSED: data.ext4 / updater.json missing, empty or not a JSON object, version.json unreadable.
#
#   check-baked-updater.sh --data-img data.ext4 --version-json version.json [--images-dir DIR]
set -uo pipefail
IMG=""; VJ=""; IMAGES_DIR=""
while [ $# -gt 0 ]; do
	case "$1" in
		--data-img) IMG="${2:-}"; shift 2 ;;
		--version-json) VJ="${2:-}"; shift 2 ;;
		--images-dir) IMAGES_DIR="${2:-}"; shift 2 ;;
		*) echo "usage: $0 --data-img data.ext4 --version-json version.json [--images-dir DIR]" >&2; exit 2 ;;
	esac
done
for t in debugfs python3; do command -v "$t" >/dev/null 2>&1 || { echo "check-baked-updater: FAIL: $t missing" >&2; exit 1; }; done
[ -f "$IMG" ] || { echo "check-baked-updater: FAIL: no data image '${IMG}'" >&2; exit 1; }
[ -f "$VJ" ] || { echo "check-baked-updater: FAIL: no version.json '${VJ}'" >&2; exit 1; }

upd=$(debugfs -R "cat /supervisor/updater.json" "$IMG" 2>/dev/null)
python3 -I - "$VJ" "$IMAGES_DIR" "$upd" <<'PY'
import glob, json, sys
vj_path, images_dir, upd_raw = sys.argv[1:4]
bad = []
def finding(m): bad.append(m); print("  BAD   " + m)
try:
    vj = json.load(open(vj_path))
except Exception as e:
    print("check-baked-updater: FAIL: version.json unreadable: %s" % e); sys.exit(1)
checked = 0
try:
    upd = json.loads(upd_raw) if upd_raw.strip() else None
except Exception:
    upd = None
if not isinstance(upd, dict):
    finding("/supervisor/updater.json is missing, empty or not a JSON object (%d bytes)" % len(upd_raw))
else:
    def baked(pat):
        return bool(images_dir) and bool(glob.glob(images_dir + "/*" + pat + "@*"))
    if not upd.get("channel"):
        finding("updater.json has no channel")
    want = [("cli", True), ("dns", True), ("audio", True), ("multicast", True), ("observer", True)]
    for p, req in want:
        want_v, want_i = vj.get(p), (vj.get("images") or {}).get(p)
        got_v, got_i = upd.get(p), (upd.get("image") or {}).get(p)
        checked += 1
        if not want_v or not want_i:
            finding("version.json has no %s version/image (the bake input itself is incomplete)" % p)
        elif got_v != want_v or got_i != want_i:
            finding("%s: updater.json has %s / %s, version.json says %s / %s" % (p, got_v, got_i, want_v, want_i))
    sv, si = vj.get("supervisor"), (vj.get("images") or {}).get("supervisor")
    if sv and baked("hassio-supervisor_" + sv):
        checked += 1
        if upd.get("supervisor") != sv or (upd.get("image") or {}).get("supervisor") != si:
            finding("supervisor: updater.json has %s / %s, version.json says %s / %s" % (upd.get("supervisor"), (upd.get("image") or {}).get("supervisor"), sv, si))
    cv, ci = vj.get("core"), (vj.get("images") or {}).get("core")
    if cv and cv != "landingpage" and baked(cv):
        checked += 1
        if upd.get("homeassistant") != cv or (upd.get("image") or {}).get("homeassistant") != ci:
            finding("homeassistant: updater.json has %s / %s, version.json says %s / %s" % (upd.get("homeassistant"), (upd.get("image") or {}).get("homeassistant"), cv, ci))
print("baked updater.json: %d component(s) compared with version.json, %d problem(s)" % (checked, len(bad)))
sys.exit(1 if bad else 0)
PY
