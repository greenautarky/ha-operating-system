#!/bin/sh
# Host-side selftest of baked_boot_device/test.sh against fixture updater.json files (the
# must-pass one is the gate's own fixture tests/gates/baked_updater/must-pass, the must-fail
# ones its must-fail set, so this suite and VER-14 judge the same shapes), a stub docker for
# the plugin containers and a fixture Supervisor log.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
GATE="$DS_ROOT/gates/baked_updater"
GOOD="$GATE/must-pass/full-seed.json"
[ -s "$GOOD" ] && ls "$GATE"/must-fail/*.json >/dev/null 2>&1 || { echo "FATAL: gate fixtures missing under $GATE"; exit 2; }

cat > "$W/bin/docker" <<'STUB'
#!/bin/sh
# docker inspect -f '{{.Config.Image}}' hassio_<p>: tag = version of $FAKE/plugins ("<p> <ver>" lines)
for a in "$@"; do last="$a"; done
p="${last#hassio_}"
v=$(awk -v p="$p" '$1==p {print $2}' "$FAKE/plugins")
[ -n "$v" ] && echo "ghcr.io/greenautarky/aarch64-hassio-$p:$v" || exit 1
STUB
chmod +x "$W/bin/docker"
F="$W/f"; mkdir -p "$F"
mkplugins() {   # versions of the running plugin containers, from an updater.json
  jq -r '"cli \(.cli)\ndns \(.dns)\naudio \(.audio)\nmulticast \(.multicast)\nobserver \(.observer)"' "$1" > "$F/plugins"
}
quiet='22-11-17 10:00:01 INFO (MainThread) [supervisor.docker.manager] Starting docker
22-11-17 10:00:02 INFO (MainThread) [supervisor.plugins.cli] Plugin cli started'
dl='22-11-17 10:00:03 INFO (MainThread) [supervisor.docker.interface] Downloading docker image ghcr.io/greenautarky/aarch64-hassio-cli with tag 2025.10.2.'

echo "== known-good: baked seed, containers on it, quiet log (fresh boot)"
printf '%s\n' "$quiet" > "$W/suplog"; mkplugins "$GOOD"
ds_run baked_boot_device GA_BKD_UPDATER="$GOOD" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F" GA_TEST_FRESH_BOOT=1
for i in BKD-01 BKD-02 BKD-03 BKD-04; do ds_expect "$i" PASS "baked, fresh, no downloads"; done

echo "== must-flag: every must-fail updater.json of the build gate is red on the device side too"
for f in "$GATE"/must-fail/*.json; do
  mkplugins "$GOOD"
  ds_run baked_boot_device GA_BKD_UPDATER="$f" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F"
  if grep -qE '^ *FAIL +BKD-0[123]:' "$W/out"; then DS_PASS=$((DS_PASS + 1)); echo "  ok    $(basename "$f") -> a BKD-01..03 check fails"
  else DS_FAIL=$((DS_FAIL + 1)); echo "  FAIL  $(basename "$f") passed the device-side updater.json checks"; fi
done
ds_run baked_boot_device GA_BKD_UPDATER="$W/absent.json" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F"
ds_expect BKD-01 FAIL "no updater.json at all"

echo "== running plugin on another version than updater.json"
mkplugins "$GOOD"; sed -i 's/^dns .*/dns 1999.01.1/' "$F/plugins"
ds_run baked_boot_device GA_BKD_UPDATER="$GOOD" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F"
ds_expect BKD-03 FAIL "dns container on another version"
: > "$F/plugins"
ds_run baked_boot_device GA_BKD_UPDATER="$GOOD" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F"
ds_expect BKD-03 FAIL "zero containers inspected is a FAIL, never a pass"

echo "== the Supervisor log"
mkplugins "$GOOD"; printf '%s\n%s\n' "$quiet" "$dl" > "$W/suplog"
ds_run baked_boot_device GA_BKD_UPDATER="$GOOD" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F" GA_TEST_FRESH_BOOT=1
ds_expect BKD-04 FAIL "a registry download on a FRESH boot"
ds_run baked_boot_device GA_BKD_UPDATER="$GOOD" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F"
ds_expect BKD-04 SKIP "a download on a device not declared fresh: reported, not a false red"
ds_run baked_boot_device GA_BKD_UPDATER="$GOOD" GA_BKD_SUPLOG_CMD="false" FAKE="$F" GA_TEST_FRESH_BOOT=1
ds_expect BKD-04 FAIL "unreadable log: nothing inspected is a FAIL"
: > "$W/suplog"
ds_run baked_boot_device GA_BKD_UPDATER="$GOOD" GA_BKD_SUPLOG_CMD="cat $W/suplog" FAKE="$F" GA_TEST_FRESH_BOOT=1
ds_expect BKD-04 FAIL "an empty log is not evidence of zero downloads"

ds_done
