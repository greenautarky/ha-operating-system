#!/bin/sh
# ga-mesh-watchdog — the LIVE script, run for real against stub commands and a
# movable clock. No device, no network.
#
# The subject is buildroot-external/rootfs-overlay/usr/sbin/ga-mesh-watchdog
# itself, never a copy of its rules. `curl`, `netbird`, `systemctl`, `ip`,
# `busctl` and `date` are stubs on a private PATH: the test decides what
# ga-tools answers, whether the NetBird cloud is reachable, whether an OS
# install or a reboot is in progress and what time it is, and reads back every
# action the script took.
#
# Fixture families (working-method rule 51):
#   MUST-NOT-ACT  a path that answers (also with "connection refused"); a dead
#                 path while the NetBird cloud is unreachable; an OS install in
#                 progress; a reboot already queued; a route that is not wt0.
#   MUST-ACT      a dead path with the cloud up escalates downup -> restart ->
#                 reboot in that order, each after its cooldown, at most one
#                 reboot per 24 h, and the ladder never loops.
#   REPORT        every action is a warning line with its reason; the return
#                 of the path is "RECOVERED by <step>" at warning.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
# The shared ga-services.conf loader the scripts under test source (device path: /usr/libexec).
export GA_SERVICES_CONF_LIB="${GA_SERVICES_CONF_LIB:-$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/ga-services-conf.sh}"

suite_start "ga-mesh-watchdog ladder (live script, stub commands)"

ROOT="$SCRIPT_DIR/../../.."
WD="${GA_MESH_WATCHDOG_BIN:-$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-mesh-watchdog}"
PUB="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish"

run_test "MWD-00" "the watchdog script exists and is executable" "test -x '$WD'"
command -v jq >/dev/null 2>&1 || { echo "jq missing — cannot run"; suite_end; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/mesh_wd.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/share" "$W/stage" "$W/state" "$W/sysnet"

# ------------------------------------------------------------------ stubs
# curl: mesh probes go to 127.0.0.1 (from the fixture ga-services.conf), the
# cloud probes to the management/signal URLs. $W/mesh = ok|refused|dead,
# $W/cloud = up|down.
cat > "$W/bin/curl" <<STUB
#!/bin/sh
for a in "\$@"; do url="\$a"; done
echo "\$url" >> "$W/curl.log"
case "\$url" in
  http://203.0.113.50:*)
    [ "\$(cat "$W/fallback" 2>/dev/null)" = ok ] && exit 0
    echo "curl: (28) Connection timed out" >&2; exit 28 ;;
  http://127.0.0.1:*)
    case "\$(cat "$W/mesh")" in
      ok) exit 0 ;;
      refused) echo "curl: (7) Failed to connect to 127.0.0.1 port 8090: Connection refused" >&2; exit 7 ;;
      *) echo "curl: (28) Connection timed out" >&2; exit 28 ;;
    esac ;;
  *) [ "\$(cat "$W/cloud")" = up ] && exit 0; exit 6 ;;
esac
STUB
# netbird: status JSON; down/up recorded as actions.
cat > "$W/bin/netbird" <<STUB
#!/bin/sh
case "\$*" in
  *status*) cat "$W/nb_json" 2>/dev/null ;;
  *" down"*) echo "netbird down" >> "$W/actions.log" ;;
  *" up"*) echo "netbird up" >> "$W/actions.log" ;;
esac
STUB
# systemctl: queries answered from fixture files; actions recorded.
cat > "$W/bin/systemctl" <<STUB
#!/bin/sh
case "\$1" in
  is-active) cat "$W/ota_state" 2>/dev/null || echo inactive ;;
  is-system-running) cat "$W/sys_state" 2>/dev/null || echo running ;;
  list-jobs) cat "$W/jobs" 2>/dev/null ;;
  restart|reboot) echo "systemctl \$*" >> "$W/actions.log"; exit \$(cat "$W/systemctl_rc" 2>/dev/null || echo 0) ;;
esac
STUB
cat > "$W/bin/nmcli" <<STUB
#!/bin/sh
cat "$W/nm" 2>/dev/null || echo full
STUB
cat > "$W/bin/busctl" <<STUB
#!/bin/sh
echo "s \"\$(cat "$W/rauc_op" 2>/dev/null || echo idle)\""
STUB
cat > "$W/bin/ip" <<STUB
#!/bin/sh
echo "127.0.0.1 dev \$(cat "$W/route_dev") src 203.0.113.10 uid 0"
STUB
cat > "$W/bin/date" <<STUB
#!/bin/sh
[ "\$1" = "+%s" ] && { cat "$W/now"; exit 0; }
exec /bin/date "\$@"
STUB
chmod +x "$W"/bin/*

# The fixture conf mirrors the baked default: no GA_MESH_WD_REBOOT line at all
# (the script must default to OFF), enable_reboot / with_fallback add lines.
base_conf() { printf 'GA_SERVICES_IP=127.0.0.1\nGA_FLEET_PORT=8090\n' > "$W/ga-services.conf"; }
enable_reboot() { echo 'GA_MESH_WD_REBOOT=1' >> "$W/ga-services.conf"; }
with_fallback() { echo 'GA_MESH_FALLBACK_PEER=203.0.113.50' >> "$W/ga-services.conf"; echo "$1" > "$W/fallback"; }
NB_UP='{"daemonStatus":"Connected","management":{"url":"https://mgmt.example:443","connected":true},"signal":{"url":"https://signal.example:443","connected":true}}'

T0=1790000000
reset_all() {
  rm -f "$W"/actions.log "$W"/curl.log "$W"/state/* "$W"/share/* "$W"/ota_state "$W"/sys_state "$W"/jobs "$W"/rauc_op "$W"/systemctl_rc "$W"/out.all "$W"/nm "$W"/wifi_last "$W"/ledger
  echo "$T0" > "$W/now"; echo ok > "$W/mesh"; echo up > "$W/cloud"; echo wt0 > "$W/route_dev"
  printf '%s' "$NB_UP" > "$W/nb_json"
  base_conf; rm -f "$W/fallback" "$W/override.conf"; unset OVR DFL
  mkdir -p "$W/sysnet/wt0"
}
at()   { echo $(( T0 + $1 )) > "$W/now"; }          # at SECONDS-since-T0
tick() {
  PATH="$W/bin:/usr/bin:/bin" \
  GA_MESH_CONF_OVERRIDE="${OVR:-$W/ga-services.conf}" GA_MESH_CONF_DEFAULT="${DFL:-$W/ga-services.conf}" \
  GA_MESH_SYS_NET="$W/sysnet" GA_MESH_STATE_DIR="$W/state" GA_MESH_STATE_FILE="$W/state/wd.state" \
  GA_MESH_SHARE_FILE="$W/share/ga-mesh-watchdog.json" GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$W/stage" \
  GA_MESH_WIFI_LAST_ACTION="$W/wifi_last" GA_MESH_REBOOT_LEDGER="$W/ledger" \
  sh "$WD" > "$W/out" 2>&1
  cat "$W/out" >> "$W/out.all"
}
# ticks FROM TO [STEP] — one tick every STEP (default 120) s in [FROM, TO]; long
# holds use a coarser step to keep the suite fast, never across a threshold
ticks() { _t="$1"; while [ "$_t" -le "$2" ]; do at "$_t"; tick; _t=$(( _t + ${3:-120} )); done; }
actions() { [ -f "$W/actions.log" ] && tr '\n' '|' < "$W/actions.log" || true; }
st() { jq -r ".$1" "$W/share/ga-mesh-watchdog.json" 2>/dev/null; }

# ═════════════════════════════════════════════ MUST-NOT-ACT
reset_all; ticks 0 3600
run_test "MWD-01" "path OK for an hour: no action, state alive" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = alive ]"
run_test "MWD-02" "…and the healthy tick says nothing at warning (nothing shipped)" \
  "! grep -q '^<[0-4]>' '$W/out.all'"

run_test "MWD-02b" "a healthy device still proves its cloud probe works — at most hourly (2 in [0 s, 3600 s])" \
  "[ \"\$(st cloud_reachable)\" = true ] && [ \"\$(grep -c mgmt.example '$W/curl.log')\" -le 2 ]"
reset_all; echo down > "$W/cloud"; ticks 0 7200
run_test "MWD-02c" "path OK but the cloud probe fails: no action, ONE warning that the watchdog could not act" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = alive ] && [ \"\$(st cloud_reachable)\" = false ] \
   && [ \"\$(grep -c '^<4>ga-mesh-watchdog: the mesh path works but the NetBird cloud probe fails' '$W/out.all')\" = 1 ]"

reset_all; echo refused > "$W/mesh"; ticks 0 3600
run_test "MWD-03" "'connection refused' from ga-tools = packets crossed = alive, no action" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = alive ]"

reset_all; echo dead > "$W/mesh"; echo down > "$W/cloud"; ticks 0 86400 1200
run_test "MWD-04" "path dead 24 h while the NetBird cloud is unreachable: NO action at all" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = cloud_down ] && [ \"\$(st cloud_reachable)\" = false ]"
run_test "MWD-05" "…reported once at warning (on the transition), not every tick" \
  "[ \"\$(grep -c '^<4>ga-mesh-watchdog: cloud_down' '$W/out.all')\" = 1 ]"

reset_all; echo dead > "$W/mesh"; ticks 0 120; echo down > "$W/cloud"; at 240; tick; echo up > "$W/cloud"; ticks 360 480
run_test "MWD-06" "a cloud outage resets the streak: 2 dead + cloud down + 2 dead does not act" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st consecutive_dead)\" = 2 ]"

reset_all; echo dead > "$W/mesh"; echo activating > "$W/ota_state"; ticks 0 14400 600
run_test "MWD-07" "an OS install in progress (ga-rauc-install activating): no action" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = held ]"
reset_all; echo dead > "$W/mesh"; echo installing > "$W/rauc_op"; ticks 0 14400 600
run_test "MWD-08" "RAUC reports an operation: no action" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = held ]"
reset_all; echo dead > "$W/mesh"; echo '42 reboot.target start waiting' > "$W/jobs"; ticks 0 14400 600
run_test "MWD-09" "a reboot already queued (user-initiated): no action" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = held ]"
reset_all; echo dead > "$W/mesh"; echo stopping > "$W/sys_state"; ticks 0 14400 600
run_test "MWD-10" "the system is shutting down: no action" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = held ]"
reset_all; echo dead > "$W/mesh"; echo eth0 > "$W/route_dev"; ticks 0 14400 600
run_test "MWD-11" "ga-tools routes outside wt0: unknown, no action (fail closed)" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = unknown ]"

# ── interaction with the layers below / the other watchdogs
reset_all; echo dead > "$W/mesh"; echo none > "$W/nm"; ticks 0 14400 600
run_test "MWD-12" "link/WAN down (NM connectivity none): no action — ga-wifi-watchdog's domain" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = wan_down ] && [ \"\$(st state)\" = outage ]"
reset_all; echo dead > "$W/mesh"; echo limited > "$W/nm"; ticks 0 14400 600
run_test "MWD-13" "NM connectivity limited (not full): no action" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = wan_down ]"
reset_all; echo dead > "$W/mesh"; echo "reload $((T0 + 300))" > "$W/wifi_last"; ticks 0 1080
run_test "MWD-14" "ga-wifi-watchdog reloaded the radio 5 min before: the mesh ladder stays out for 15 min" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st verdict)\" = held ]"
ticks 1200 1440
run_test "MWD-15" "…and acts once the wifi quiet period is over (fresh streak of 3)" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|' ]"
reset_all; enable_reboot; echo dead > "$W/mesh"; echo $((T0 - 3600)) > "$W/ledger"; ticks 0 9000
run_test "MWD-16" "ga-wifi-watchdog rebooted 1 h ago (shared ledger): the mesh ladder does NOT reboot" \
  "[ \"\$(grep -c reboot '$W/actions.log')\" = 0 ] && [ \"\$(st verdict)\" = reboot_capped ] && [ \"\$(grep -c . '$W/ledger')\" = 1 ]"
reset_all; enable_reboot; echo dead > "$W/mesh"; echo wifi-stub > "$W/ledger"; chmod 444 "$W/ledger"; ticks 0 9000; chmod 644 "$W/ledger"
run_test "MWD-17" "shared ledger not writable: no reboot (the limit could not hold), error logged" \
  "[ \"\$(grep -c reboot '$W/actions.log')\" = 0 ] && grep -q '^<3>ga-mesh-watchdog: cannot write the shared reboot ledger' '$W/out.all'"

# ═════════════════════════════════════════════ MUST-ACT: the ladder (reboot ENABLED)
reset_all; enable_reboot; echo dead > "$W/mesh"
ticks 0 120
run_test "MWD-20" "two dead ticks: counted, no action yet" \
  "[ -z \"\$(actions)\" ] && [ \"\$(st consecutive_dead)\" = 2 ] && [ \"\$(st verdict)\" = dead ]"
at 240; tick
run_test "MWD-21" "third dead tick: step 1 = netbird down + up, nothing else" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|' ] && [ \"\$(st last_action)\" = downup ]"
run_test "MWD-22" "…logged at warning with its reason" \
  "grep -q '^<4>ga-mesh-watchdog: action downup: nothing answered over wt0' '$W/out'"
ticks 360 720
run_test "MWD-23" "inside the downup cooldown (600 s): no further action" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|' ]"
at 840; tick
run_test "MWD-24" "after the cooldown: step 2 = systemctl restart netbird" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|systemctl restart netbird|' ] && [ \"\$(st last_action)\" = restart ]"
ticks 960 2640
run_test "MWD-25" "inside the restart cooldown (1800 s): no further action" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|systemctl restart netbird|' ]"
ticks 2760 6720
run_test "MWD-26" "cooldown over but dead < 2 h: still no reboot" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|systemctl restart netbird|' ]"
ticks 6840 7320
run_test "MWD-27" "dead >= 2 h: step 3 = ONE systemctl reboot" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|systemctl restart netbird|systemctl reboot|' ] && [ \"\$(st reboots_24h)\" = 1 ]"
run_test "MWD-28" "the reboot is written to the SHARED ledger (ga-wifi-watchdog's) before it is issued" \
  "[ \"\$(grep -c . '$W/ledger')\" = 1 ] && grep -q '^STAGE=3' '$W/state/wd.state'"

# still dead after the reboot: the ladder may restart only after 6 h, and the
# second reboot inside 24 h must be refused
ticks 7440 28800 600
run_test "MWD-29" "after the reboot, still dead: nothing more inside the 6 h ladder reset" \
  "[ \"\$(grep -c . '$W/actions.log')\" = 4 ]"
ticks 28920 36000
run_test "MWD-30" "after 6 h the ladder runs again: downup, then restart" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|systemctl restart netbird|systemctl reboot|netbird down|netbird up|systemctl restart netbird|' ]"
run_test "MWD-31" "…and the second reboot inside 24 h is refused (reboot_capped, warned)" \
  "[ \"\$(grep -c reboot '$W/actions.log')\" = 1 ] && [ \"\$(st verdict)\" = reboot_capped ] \
   && grep -q '^<4>ga-mesh-watchdog: reboot_capped' '$W/out.all'"
ticks 36120 86400 600
run_test "MWD-32" "a full day dead: at most one reboot, and downup/restart bounded by the 6 h reset (no loop)" \
  "[ \"\$(grep -c 'systemctl reboot' '$W/actions.log')\" = 1 ] && [ \"\$(grep -c 'systemctl restart' '$W/actions.log')\" -le 5 ]"
ticks 86520 115200 600
run_test "MWD-33" "once the first reboot is > 24 h old, a reboot is allowed again" \
  "[ \"\$(grep -c 'systemctl reboot' '$W/actions.log')\" = 2 ]"

# ═════════════════════════════════════════════ REPORT: RECOVERED by <step>
reset_all; echo dead > "$W/mesh"; ticks 0 840
echo ok > "$W/mesh"; at 960; tick
run_test "MWD-40" "the path returns after the restart: 'RECOVERED by restart' at warning" \
  "grep -q '^<4>ga-mesh-watchdog: RECOVERED by restart' '$W/out' && [ \"\$(st verdict)\" = alive ] && [ \"\$(st stage)\" = 0 ]"
at 1080; tick
run_test "MWD-41" "…reported once: the next healthy tick is quiet" \
  "! grep -q '^<[0-4]>' '$W/out'"

reset_all; enable_reboot; echo dead > "$W/mesh"; ticks 0 7320
echo ok > "$W/mesh"; at 7500; tick
run_test "MWD-42" "back after the reboot (state on /mnt/data): 'RECOVERED by reboot'" \
  "grep -q '^<4>ga-mesh-watchdog: RECOVERED by reboot' '$W/out'"

# ═════════════════════════════════════════════ edge cases
reset_all; echo dead > "$W/mesh"; rmdir "$W/sysnet/wt0"; printf '' > "$W/nb_json"; ticks 0 240
run_test "MWD-50" "wt0 absent and the client silent, cloud up: dead, and step 1 runs" \
  "[ \"\$(actions)\" = 'netbird down|netbird up|' ]"

reset_all; echo dead > "$W/mesh"; echo 1 > "$W/systemctl_rc"; ticks 0 3600
run_test "MWD-51" "a failed restart is logged at error and NOT retried every tick" \
  "grep -q '^<3>ga-mesh-watchdog: action restart FAILED' '$W/out.all' && [ \"\$(grep -c 'systemctl restart' '$W/actions.log')\" = 1 ]"

# ═════════════════════════════════════════════ reboot stage OFF by default (BOSv1.5.1)
reset_all; echo dead > "$W/mesh"; ticks 0 86400 600
run_test "MWD-60" "DEFAULT (no GA_MESH_WD_REBOOT): a day dead -> down/up + restart only, NEVER a reboot" \
  "[ \"\$(grep -c 'systemctl reboot' '$W/actions.log')\" = 0 ] && grep -q 'systemctl restart netbird' '$W/actions.log' \
   && [ ! -s '$W/ledger' ]"
reset_all; echo dead > "$W/mesh"; ticks 0 9000
run_test "MWD-61" "…and the state says reboot_disabled, warned once" \
  "[ \"\$(st verdict)\" = reboot_disabled ] && [ \"\$(grep -c '^<4>ga-mesh-watchdog: reboot_disabled' '$W/out.all')\" = 1 ]"
reset_all; echo 'GA_MESH_WD_REBOOT=0' >> "$W/ga-services.conf"; echo dead > "$W/mesh"; ticks 0 9000
run_test "MWD-62" "explicit GA_MESH_WD_REBOOT=0: no reboot" \
  "[ \"\$(grep -c 'systemctl reboot' '$W/actions.log')\" = 0 ] && [ \"\$(st verdict)\" = reboot_disabled ]"
reset_all; enable_reboot; with_fallback ok; echo dead > "$W/mesh"; ticks 0 9000
run_test "MWD-63" "enabled, but the fallback peer answers over wt0 (ga-tools down, tunnel fine): no reboot" \
  "[ \"\$(grep -c 'systemctl reboot' '$W/actions.log')\" = 0 ] && [ \"\$(st verdict)\" = fallback_alive ]"
reset_all; enable_reboot; with_fallback dead; echo dead > "$W/mesh"; ticks 0 9000
run_test "MWD-64" "enabled, fallback peer silent too: the one reboot happens" \
  "[ \"\$(grep -c 'systemctl reboot' '$W/actions.log')\" = 1 ]"
grep -q '^GA_MESH_WD_REBOOT=0$' "$ROOT/buildroot-external/rootfs-overlay/etc/ga-services.conf"
run_test "MWD-65" "the baked ga-services.conf ships the reboot stage OFF" "[ $? = 0 ]"

# ═════════════════════════════════════════════ ga-services.conf layering (BOSv1.5.1)
# The override is layered ON TOP of the baked default. It used to be read INSTEAD
# of it, so the partial override the staging seed writes (fleet values only) hid
# GA_SERVICES_IP and the watchdog sat at "unknown" on every such device.
# Here DFL = the baked default (full), OVR = the /mnt/data override (separate file).
DFL_REAL() { DFL="$W/baked.conf"; OVR="$W/override.conf"; printf 'GA_SERVICES_IP=127.0.0.1\nGA_FLEET_PORT=8090\n' > "$DFL"; }
reset_all; DFL_REAL; printf 'GA_FLEET_HOST=fleet.example\nGA_FLEET_PORT=8091\nGA_FLEET_ENV=staging\n' > "$OVR"; ticks 0 3600
run_test "MWD-70" "PARTIAL override (fleet values only): the baked GA_SERVICES_IP still applies -> measured, alive (not unknown)" \
  "[ \"\$(st verdict)\" = alive ] && [ -z \"\$(actions)\" ]"
run_test "MWD-71" "…and a key the override DOES set wins (GA_FLEET_PORT=8091 probed, not the baked 8090)" \
  "grep -q 'http://127.0.0.1:8091/' '$W/curl.log' && ! grep -q 'http://127.0.0.1:8090/' '$W/curl.log'"
reset_all; DFL_REAL; rm -f "$OVR"; ticks 0 3600
run_test "MWD-72" "NO override file: the baked default alone is enough -> alive" "[ \"\$(st verdict)\" = alive ]"
reset_all; DFL_REAL; printf 'GA_SERVICES_IP=127.0.0.1\nGA_FLEET_PORT=8092\n' > "$OVR"; ticks 0 3600
run_test "MWD-73" "FULL override: its values win -> alive, probes the override port" \
  "[ \"\$(st verdict)\" = alive ] && grep -q 'http://127.0.0.1:8092/' '$W/curl.log'"
reset_all; DFL="$W/baked.conf"; OVR="$W/override.conf"; printf 'GA_FLEET_PORT=8090\n' > "$DFL"; printf 'GA_FLEET_HOST=x\n' > "$OVR"; ticks 0 120
run_test "MWD-74" "GA_SERVICES_IP set in NEITHER file: unknown, no action, and LOUD — an error-level line on EVERY tick (not once)" \
  "[ \"\$(st verdict)\" = unknown ] && [ -z \"\$(actions)\" ] && [ \"\$(grep -c '^<3>ga-mesh-watchdog: unknown: GA_SERVICES_IP is set in neither' '$W/out.all')\" = 2 ]"
run_test "MWD-75" "…and the published detail names the missing address" "[ \"\$(st detail)\" != '' ] && st detail | grep -q GA_SERVICES_IP"
reset_all; DFL="$W/nonexistent-a"; OVR="$W/nonexistent-b"; ticks 0 120
run_test "MWD-76" "NO config file at all: unknown + error-level on every tick, no action" \
  "[ \"\$(st verdict)\" = unknown ] && [ -z \"\$(actions)\" ] && [ \"\$(grep -c '^<3>ga-mesh-watchdog: unknown:' '$W/out.all')\" = 2 ]"
reset_all; _LIB_SAVE="$GA_SERVICES_CONF_LIB"; export GA_SERVICES_CONF_LIB="$W/no-such-lib.sh"; ticks 0 120; export GA_SERVICES_CONF_LIB="$_LIB_SAVE"
run_test "MWD-77" "the shared loader missing: unknown + error-level (blind, but loudly), no action" \
  "[ \"\$(st verdict)\" = unknown ] && [ -z \"\$(actions)\" ] && grep -q '^<3>ga-mesh-watchdog: unknown: cannot load' '$W/out.all'"

# ═════════════════════════════════════════════ MESH-04 (the device suite's own check)
# MESH-04 runs ON the device; its command is extracted from the LIVE test.sh
# (MESH04_CMD) and run against a stub systemctl that answers like systemd does
# for an OnBootSec/OnUnitActiveSec timer: NextElapseUSecRealtime is ALWAYS empty
# (only OnCalendar sets it), NextElapseUSecMonotonic carries the time (humanised, as on K31: "2h 37.127221s"). The old
# check asked for Realtime and could not pass on any device (K31 BOSv1.5.1-rc1/rc3).
# If the extraction finds nothing, that is a FAILURE, never a skip.
DEVTEST="$SCRIPT_DIR/test.sh"
M4="$(sed -n "s/^MESH04_CMD='\(.*\)'\$/\1/p" "$DEVTEST")"
run_test "MWD-80" "MESH-04's command is found in the live device test.sh (extraction must not silently find nothing)" "[ -n '$(printf '%s' "$M4" | head -c1)' ]"
mkdir -p "$W/m4bin"
cat > "$W/m4bin/systemctl" <<STUB
#!/bin/sh
case "\$*" in
  *NextElapseUSecRealtime*) cat "$W/m4_realtime" 2>/dev/null ;;
  *NextElapseUSecMonotonic*) cat "$W/m4_mono" 2>/dev/null ;;
esac
STUB
chmod +x "$W/m4bin/systemctl"
m4() { # <realtime> <monotonic> <cmd> -> rc
  printf '%s' "$1" > "$W/m4_realtime"; printf '%s' "$2" > "$W/m4_mono"
  PATH="$W/m4bin:$PATH" sh -c "$3" >/dev/null 2>&1
}
M4_OLD='systemctl show -p NextElapseUSecRealtime --value ga-mesh-watchdog.timer 2>/dev/null | grep -qv "^$" && systemctl show -p NextElapseUSecRealtime --value ga-mesh-watchdog.timer'
# green: a healthy OnBootSec/OnUnitActiveSec timer (realtime empty, monotonic set)
run_test "MWD-81" "MESH-04 PASSES on a healthy monotonic timer (realtime empty, monotonic set)" "m4 '' '2h 37.127221s' '$M4'"
# the same state is exactly what the OLD check failed on - red proof of the defect
run_test "MWD-82" "the OLD realtime check FAILS on that same healthy timer (the defect this fixes)" "! m4 '' '2h 37.127221s' '$M4_OLD'"
# red: nothing scheduled
run_test "MWD-83" "MESH-04 FAILS when no next elapse is scheduled (monotonic 0)" "! m4 '' 0 '$M4'"
run_test "MWD-84" "MESH-04 FAILS when the property is empty / the unit is unknown" "! m4 '' '' '$M4'"
run_test "MWD-85" "MESH-04 FAILS on n/a and infinity (nothing will elapse)" "! m4 '' 'n/a' '$M4' && ! m4 '' infinity '$M4'"
run_test "MWD-86" "MESH-04 does not take a realtime value as proof (realtime set, monotonic empty)" "! m4 'Tue 2026-10-13 10:00:00 CEST' '' '$M4'"

suite_end
