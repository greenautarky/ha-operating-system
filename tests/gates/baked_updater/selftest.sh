#!/usr/bin/env bash
# selftest.sh -- scripts/check-baked-updater.sh (the LIVE script) goes red on a built updater.json that
# does not carry what version.json says and green on a full seed (Odoo #2067/#2065).
# Fixtures: version.json (the iHost rc3 channel set); must-fail/*.json and must-pass/*.json are updater.json
# contents (the first is the REAL BOSv1.6.0-rc13 Core-only seed), each put into a throwaway ext4 at
# /supervisor/updater.json. A fake images dir (empty files named like the bake's tars) says what is baked.
# Also: the LIVE generator (gen-updater-json.sh) output must be green, and a missing file / image is red.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-baked-updater.sh"; GEN="$ROOT/buildroot-external/package/hassio/gen-updater-json.sh"
[ -x "$GATE" ] || { echo "FATAL: $GATE missing"; exit 1; }
[ -x "$GEN" ] || { echo "FAIL: live generator $GEN not found -- extraction stopped finding the definition"; exit 1; }
for t in debugfs mkfs.ext4 python3 jq; do command -v $t >/dev/null || { echo "FATAL: $t missing"; exit 1; }; done
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0; ran=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); echo "  FAIL  $1"; }
mkdir "$W/imgs"
for n in audio cli dns multicast observer; do v=$(jq -r ".$n" "$HERE/version.json"); : > "$W/imgs/ghcr.io_greenautarky_armv7-hassio-${n}_${v}@sha256_0.tar"; done
: > "$W/imgs/ghcr.io_greenautarky_armv7-hassio-supervisor_$(jq -r .supervisor "$HERE/version.json")@sha256_0.tar"
: > "$W/imgs/ghcr.io_greenautarky_home-assistant-armv7_$(jq -r .core "$HERE/version.json")@sha256_0.tar"
mk() { local d="$W/t.$RANDOM"; mkdir -p "$d/supervisor"; cp "$1" "$d/supervisor/updater.json"; mkfs.ext4 -q -d "$d" "$2" 8M >/dev/null 2>&1 || { echo FATAL mkfs; exit 1; }; rm -rf "$d"; }
run() { OUT="$("$GATE" --data-img "$1" --version-json "$HERE/version.json" --images-dir "$W/imgs" 2>&1)"; RC=$?; }
n=0
for verdict in must-fail must-pass; do
  for f in "$HERE/$verdict"/*.json; do
    n=$((n+1)); name="$(basename "$f" .json)"; mk "$f" "$W/$verdict-$name.ext4"; run "$W/$verdict-$name.ext4"
    if [ "$verdict" = must-fail ]; then [ "$RC" = 1 ] && grep -q ' BAD ' <<<"$OUT" && ok "$verdict/$name -> red" || bad "$verdict/$name rc=$RC :: $OUT"
    else [ "$RC" = 0 ] && grep -q ' 0 problem' <<<"$OUT" && ok "$verdict/$name -> green" || bad "$verdict/$name rc=$RC :: $OUT"; fi
  done
done
# the auto_update rule itself fires, not some other check (the rest of these fixtures is a full seed)
for f in "$HERE"/must-fail/auto-update-*.json; do
  run "$W/must-fail-$(basename "$f" .json).ext4"
  [ "$(grep -c ' BAD ' <<<"$OUT")" = 1 ] && grep -q 'BAD   auto_update is' <<<"$OUT" && ok "$(basename "$f" .json): only the auto_update rule" || bad "$(basename "$f" .json) :: $OUT"
done
[ "$n" -ge 11 ] || bad "only $n fixtures ran"
# the live generator's own output must satisfy the gate (generator and gate agree)
"$GEN" "$HERE/version.json" "$W/imgs" stable > "$W/gen.json" 2>/dev/null && mk "$W/gen.json" "$W/gen.ext4" && run "$W/gen.ext4"
[ "$RC" = 0 ] && ok "output of the live gen-updater-json.sh -> green" || bad "live generator output rc=$RC :: $OUT"
# a board without the Supervisor/Core image baked is not asked for them
mkdir "$W/imgs2"; cp -a "$W"/imgs/*hassio-{audio,cli,dns,multicast,observer}_* "$W/imgs2/"
"$GEN" "$HERE/version.json" "$W/imgs2" stable > "$W/gen2.json" 2>/dev/null && mk "$W/gen2.json" "$W/gen2.ext4"
OUT="$("$GATE" --data-img "$W/gen2.ext4" --version-json "$HERE/version.json" --images-dir "$W/imgs2" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "no Supervisor/Core baked -> not required, green" || bad "skip-board rc=$RC :: $OUT"
# fail closed
d="$W/nofile"; mkdir -p "$d/supervisor"; mkfs.ext4 -q -d "$d" "$W/nofile.ext4" 8M >/dev/null 2>&1; run "$W/nofile.ext4"
[ "$RC" = 1 ] && ok "no updater.json in the image -> red" || bad "no file rc=$RC :: $OUT"
run "$W/missing.ext4"; [ "$RC" = 1 ] && ok "missing data image -> red" || bad "missing image rc=$RC"
OUT="$("$GATE" --data-img "$W/gen.ext4" --version-json "$W/none.json" 2>&1)"; [ $? = 1 ] && ok "missing version.json -> red" || bad "missing version.json"
echo "$ran cases, $fails failed"; [ "$ran" -gt 0 ] && exit $((fails > 0)); exit 1
