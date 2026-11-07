#!/usr/bin/env bash
# selftest: scripts/archive-extract-file.py (reads the baked Supervisor image's dns.py for BLD-SUP-DNS / INT-05 /
# SVC-09*, Odoo #1649). Drives the LIVE script on scratch archives:
#   must-pass: docker-archive and OCI archive, gzip and plain layers, the LAST layer wins
#   must-flag: file absent -> rc 3, whiteout deletes it -> rc 3, unreadable archive / no layers -> rc 2
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
X="$ROOT/scripts/archive-extract-file.py"
[ -f "$X" ] || { echo "FAIL: $X not found"; exit 1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/ax-XXXXXX")"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
python3 - "$W" <<'PY'
import gzip, hashlib, io, json, sys, tarfile
w = sys.argv[1]
def add(t, n, d):
    ti = tarfile.TarInfo(n); ti.size = len(d); t.addfile(ti, io.BytesIO(d))
def layer(files, gz=False):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w") as t:
        for n, d in files: add(t, n, d)
    r = b.getvalue(); return gzip.compress(r) if gz else r
P = "usr/src/supervisor/supervisor/plugins/dns.py"
def docker(path, layers):
    with tarfile.open(path, "w") as t:
        names = []
        for i, l in enumerate(layers): add(t, f"l{i}/layer.tar", l); names.append(f"l{i}/layer.tar")
        add(t, "manifest.json", json.dumps([{"Config": "c.json", "Layers": names}]).encode())
def oci(path, layers):
    with tarfile.open(path, "w") as t:
        ds = []
        for l in layers:
            d = hashlib.sha256(l).hexdigest(); add(t, "blobs/sha256/" + d, l); ds.append("sha256:" + d)
        m = json.dumps({"layers": [{"digest": d} for d in ds]}).encode(); md = hashlib.sha256(m).hexdigest()
        add(t, "blobs/sha256/" + md, m)
        add(t, "index.json", json.dumps({"manifests": [{"digest": "sha256:" + md}]}).encode())
docker(f"{w}/d-gz.tar",   [layer([("etc/x", b"x")], True), layer([(P, b"OLD")], True), layer([(P, b"NEW")], True)])
oci(f"{w}/o-plain.tar",   [layer([(P, b"OLD")]), layer([(P, b"NEW")])])
docker(f"{w}/absent.tar", [layer([("etc/x", b"x")])])
docker(f"{w}/wh.tar",     [layer([(P, b"OLD")]), layer([("usr/src/supervisor/supervisor/plugins/.wh.dns.py", b"")])])
docker(f"{w}/nolayer.tar", [])
open(f"{w}/garbage.tar", "wb").write(b"not an archive")
PY
chk() { # <label> <archive> <want rc> [<want content>]
  local out rc; out="$(python3 "$X" "$W/$2" usr/src/supervisor/supervisor/plugins/dns.py 2>/dev/null)"; rc=$?
  if [ "$rc" = "$3" ] && { [ -z "${4:-}" ] || [ "$out" = "$4" ]; }; then ok "$1"; else bad "$1 (rc=$rc out='${out:0:20}')"; fi
}
chk "docker-archive, gzip layers, last layer wins" d-gz.tar 0 NEW
chk "OCI archive, plain layers, last layer wins"   o-plain.tar 0 NEW
chk "path absent -> rc 3"                          absent.tar 3
chk "whiteout deletes it -> rc 3"                  wh.tar 3
chk "archive without layers -> rc 2 (broken check)" nolayer.tar 2
chk "unreadable archive -> rc 2 (broken check)"    garbage.tar 2
[ "$ran" -ge 6 ] || { echo "FAIL: only $ran cases"; exit 1; }
echo "$ran cases ran, $fails failed"; exit $((fails>0))
