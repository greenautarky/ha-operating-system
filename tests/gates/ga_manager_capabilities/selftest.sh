#!/usr/bin/env bash
# =============================================================================
# selftest.sh — a baked ga_manager that lacks what the OS relies on must go RED.
# =============================================================================
# Drives the LIVE scripts/check-ga-manager-capabilities.py (not a copy) over
# docker-archive tars built here, in the layout the bake writes
# (manifest.json + one tar per layer, named exactly as fetch-container-image.sh
# names the file). No registry, no network.
#
# must-fail: the BOSv1.4.0-rc2 shape (ga_manager 0.219.0/0.220.0 pinned: no
# ha_influxdb reconciler), a pin raised without the image following, a module
# shipped but never registered, a capability deleted again by a later layer
# (whiteout), an image whose own version disagrees with the pin, and no tar at
# all. must-pass: the capability present (also with gzip layers and with the
# file overridden in a later layer). cannot-judge (exit 2): no pin, a tar that
# is not a docker-archive. A gate that flags everything is overridden by reflex
# — must-pass is not padding.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-ga-manager-capabilities.py"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -f "$GATE" ]] || { echo "FATAL: $GATE missing"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mk <dir> <pinned-version> <image-version> <layers-spec> [gzip]
# layers-spec: ';'-separated layers, each ','-separated path=content entries
# (content tokens: CAP = the full ha_influxdb module text, REG = the registry
# line, DF = the dataflow constant, VER = source-config with <image-version>,
# OLD = a module without the capability, WH = a whiteout entry).
mk() {
  local dir="$1" pin="$2" imgver="$3" spec="$4" gz="${5:-}"
  mkdir -p "$dir/images"
  cat > "$dir/pins.json" <<JSON
{"addons": {"ga_manager": {"image": "ghcr.io/greenautarky/ga_manager-{arch}", "version": "$pin"},
            "mosquitto": {"image": "ghcr.io/greenautarky/ga_mosquitto-{arch}", "version": "7.2.4"}}}
JSON
  python3 - "$dir/images" "$pin" "$imgver" "$spec" "$gz" <<'PY'
import io, json, sys, tarfile
out, pin, imgver, spec, gz = sys.argv[1:6]
TEXT = {
    "CAP": 'DATABASE = "ga_homeassistant_db"\nUSERNAME = "ga_ha_influx_user"\nasync def reconcile(sup): ...\n',
    "REG": 'RECONCILERS = [\n    Reconciler(\n        name="ha_influxdb",\n    ),\n]\n',
    "OLDREG": 'RECONCILERS = [\n    Reconciler(\n        name="http_settings",\n    ),\n]\n',
    "DF": 'CORE_DATABASE = "ga_homeassistant_db"\nCORE_MEASUREMENT = "°C"\n',
    "OLDDF": 'INFLUX_DATABASE = "gd_data"\n',
    "VER": f'name: "GA Manager"\nversion: "{imgver}"\nslug: "ga_manager"\n',
    "WH": "",
}
def layer(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz" if gz else "w") as t:
        for e in entries:
            path, tok = e.split("=", 1)
            data = TEXT[tok].encode()
            ti = tarfile.TarInfo(path); ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()
layers = [layer([e for e in l.split(",") if e]) for l in spec.split(";")]
name = f"ghcr.io_greenautarky_ga_manager-armv7_{pin}@sha256_{'1'*64}.tar"
with tarfile.open(f"{out}/{name}", "w") as t:
    names = []
    for i, data in enumerate(layers):
        n = f"{i:064x}.tar"; names.append(n)
        ti = tarfile.TarInfo(n); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    m = json.dumps([{"Config": "cfg.json", "RepoTags": [], "Layers": names}]).encode()
    ti = tarfile.TarInfo("manifest.json"); ti.size = len(m); t.addfile(ti, io.BytesIO(m))
# an unrelated add-on tar, as in a real bake — must not be mistaken for ga_manager
open(f"{out}/ghcr.io_greenautarky_ga_mosquitto-armv7_7.2.4@sha256_{'2'*64}.tar", "wb").close()
PY
}

G=usr/bin/ga_manager
BASE="opt/ga-manager/source-config.yaml=VER"
GOOD="$G/ha_influxdb.py=CAP,$G/desired_state.py=REG,$G/healthchecks/dataflow.py=DF,$BASE"
RC2="$G/desired_state.py=OLDREG,$G/healthchecks/dataflow.py=OLDDF,$BASE"

# expect <name> <rc> <must-contain> [--pin-only]
expect() {
  local name="$1" want="$2" needle="$3" mode="${4:-}"
  local d="$WORK/$name" out rc
  ran=$((ran + 1))
  if [[ "$mode" == "--pin-only" ]]; then
    out="$(python3 "$GATE" --pins "$d/pins.json" 2>&1)"; rc=$?
  else
    out="$(python3 "$GATE" --pins "$d/pins.json" --images-dir "$d/images" 2>&1)"; rc=$?
  fi
  if [[ "$rc" -eq "$want" ]] && grep -qF -- "$needle" <<<"$out"; then
    ok "$name: rc=$rc — $needle"
  else
    bad "$name: rc=$rc (want $want), wanted '$needle' in:"; sed 's/^/          /' <<<"$out"
  fi
}

echo "=== ga_manager capability gate — must-fail ==="
mk "$WORK/rc2-pin-0219"      0.219.0 0.219.0 "$RC2"
expect rc2-pin-0219 1 "ga_manager 0.219.0 is pinned, core_influxdb needs >= 0.221.0"
expect rc2-pin-0219 1 "core_influxdb not in the baked image — usr/bin/ga_manager/ha_influxdb.py absent"
mk "$WORK/rc3-pin-0220"      0.220.0 0.220.0 "$RC2"
expect rc3-pin-0220 1 "ga_manager 0.220.0 is pinned, core_influxdb needs >= 0.221.0" --pin-only
mk "$WORK/pin-raised-image-old" 0.221.0 0.220.0 "$RC2"
expect pin-raised-image-old 1 "the image says it is ga_manager 0.220.0, the pin says 0.221.0"
mk "$WORK/module-not-registered" 0.221.0 0.221.0 "$G/ha_influxdb.py=CAP,$G/desired_state.py=OLDREG,$G/healthchecks/dataflow.py=DF,$BASE"
expect module-not-registered 1 "lacks 'name=\"ha_influxdb\"'"
mk "$WORK/whiteout-later-layer" 0.221.0 0.221.0 "$GOOD;$G/.wh.ha_influxdb.py=WH"
expect whiteout-later-layer 1 "usr/bin/ga_manager/ha_influxdb.py absent"
mkdir -p "$WORK/no-tar/images"; cp "$WORK/module-not-registered/pins.json" "$WORK/no-tar/"
expect no-tar 1 "expected exactly one ghcr.io_greenautarky_ga_manager-armv7_0.221.0@sha256_*.tar"

echo "=== must-pass ==="
mk "$WORK/fixed"             0.221.0 0.221.0 "$GOOD"
expect fixed 0 "core_influxdb present in the baked image"
mk "$WORK/fixed-gzip-layers" 0.221.0 0.221.0 "$GOOD" gz
expect fixed-gzip-layers 0 "core_influxdb present in the baked image"
mk "$WORK/override-later"    0.222.0 0.222.0 "$RC2;$GOOD"
expect override-later 0 "core_influxdb present in the baked image"
expect override-later 0 "pin ga_manager 0.222.0 >= 0.221.0" --pin-only

echo "=== cannot judge ==="
mkdir -p "$WORK/no-pin/images"; echo '{"addons": {}}' > "$WORK/no-pin/pins.json"
expect no-pin 2 "CANNOT JUDGE: no ga_manager pin readable"
mk "$WORK/not-an-archive" 0.221.0 0.221.0 "$GOOD"
printf 'not a tar' > "$WORK/not-an-archive/images/$(ls "$WORK/not-an-archive/images" | grep ga_manager)"
expect not-an-archive 2 "CANNOT JUDGE"

echo
if [[ "$ran" -lt 13 ]]; then echo "FAIL: only $ran cases ran — coverage dropped"; exit 1; fi
if [[ "$fails" -gt 0 ]]; then echo "ga_manager capability gate selftest: $fails/$ran FAILED"; exit 1; fi
echo "ga_manager capability gate selftest: $ran/$ran as expected"
