#!/bin/sh
# ga-mesh-watchdog — the LIVE script, run for real against stub commands and a
# movable clock. No device, no network.
#
# The subject is buildroot-ihost/rootfs-overlay/usr/sbin/ga-mesh-watchdog
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

suite_start "ga-mesh-watchdog ladder (live script, stub commands)"

ROOT="$SCRIPT_DIR/../../.."
WD="${GA_MESH_WATCHDOG_BIN:-$ROOT/buildroot-ihost/rootfs-overlay/usr/sbin/ga-mesh-watchdog}"
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
echo "127.0.0.1 dev \$(cat "$W/route_dev") src 100.64.0.2 uid 0"
STUB
cat > "$W/bin/date" <<STUB
#!/bin/sh
[ "\$1" = "+%s" ] && { cat "$W/now"; exit 0; }
exec /bin/date "\$@"
STUB
chmod +x "$W"/bin/*

printf 'GA_SERVICES_IP=127.0.0.1\nGA_FLEET_PORT=8090\n' > "$W/ga-services.conf"
NB_UP='{"daemonStatus":"Connected","management":{"url":"https://mgmt.example:443","connected":true},"signal":{"url":"https://signal.example:443","connected":true}}'

T0=1790000000
reset_all() {
  rm -f "$W"/actions.log "$W"/curl.log "$W"/state/* "$W"/share/* "$W"/ota_state "$W"/sys_state "$W"/jobs "$W"/rauc_op "$W"/systemctl_rc "$W"/out.all "$W"/nm "$W"/wifi_last "$W"/ledger
  echo "$T0" > "$W/now"; echo ok > "$W/mesh"; echo up > "$W/cloud"; echo wt0 > "$W/route_dev"
  printf '%s' "$NB_UP" > "$W/nb_json"
  mkdir -p "$W/sysnet/wt0"
}
at()   { echo $(( T0 + $1 )) > "$W/now"; }          # at SECONDS-since-T0
tick() {
  PATH="$W/bin:/usr/bin:/bin" \
  GA_MESH_CONF_OVERRIDE="$W/ga-services.conf" GA_MESH_CONF_DEFAULT="$W/ga-services.conf" \
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
reset_all; echo dead > "$W/mesh"; echo $((T0 - 3600)) > "$W/ledger"; ticks 0 9000
run_test "MWD-16" "ga-wifi-watchdog rebooted 1 h ago (shared ledger): the mesh ladder does NOT reboot" \
  "[ \"\$(grep -c reboot '$W/actions.log')\" = 0 ] && [ \"\$(st verdict)\" = reboot_capped ] && [ \"\$(grep -c . '$W/ledger')\" = 1 ]"
reset_all; echo dead > "$W/mesh"; echo wifi-stub > "$W/ledger"; chmod 444 "$W/ledger"; ticks 0 9000; chmod 644 "$W/ledger"
run_test "MWD-17" "shared ledger not writable: no reboot (the limit could not hold), error logged" \
  "[ \"\$(grep -c reboot '$W/actions.log')\" = 0 ] && grep -q '^<3>ga-mesh-watchdog: cannot write the shared reboot ledger' '$W/out.all'"

# ═════════════════════════════════════════════ MUST-ACT: the ladder
reset_all; echo dead > "$W/mesh"
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

reset_all; echo dead > "$W/mesh"; ticks 0 7320
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

suite_end
