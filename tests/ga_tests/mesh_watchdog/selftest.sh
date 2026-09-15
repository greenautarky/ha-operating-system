#!/bin/sh
# ga-mesh-watchdog — the LIVE script, run for real against stub commands.
#
# The subject under test is /usr/sbin/ga-mesh-watchdog itself, never a copy of
# its logic. `curl`, `netbird`, `systemctl`, `ip` and `date` are stubs on a
# private PATH, so the test dictates what the mesh answers, what the client
# claims, what the routing table says and what time it is — and can see whether
# a restart was issued. A self-test that re-declared the rules here would test
# the copy and stay green while the real script rotted, which is the exact
# failure class the watchdog exists to catch.
#
# Two fixture families (working-method rule 51):
#
#   MUST-FIRE      the incident shape — WAN up, the client claims Connected
#                  and management up, nothing answers over the mesh — must end
#                  in EXACTLY ONE `systemctl restart netbird` after three
#                  consecutive dead ticks, and the cooldown must then hold.
#   MUST-NOT-FIRE  WAN down; a client that reports itself down; a mesh that
#                  answers; any input that cannot be read. A restart in any of
#                  those is the bug this suite exists to keep out — must-pass
#                  is not padding: a watchdog that restarts on everything gets
#                  masked or removed, which is a slower way of having none.
#
# Needs sh, jq, curl-less (curl is stubbed), coreutils. No device, no network.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-mesh-watchdog (live script, stub commands)"

ROOT="$SCRIPT_DIR/../../.."
# On a device the script is installed; in CI it is read from the overlay. The
# override exists so the red proof can point this suite at a tree that predates
# the change.
WD="${GA_MESH_WATCHDOG_BIN:-}"
if [ -z "$WD" ]; then
  WD="/usr/sbin/ga-mesh-watchdog"
  [ -x "$WD" ] || WD="$ROOT/buildroot-ihost/rootfs-overlay/usr/sbin/ga-mesh-watchdog"
fi
PUB="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish"
RESOLVE="${GA_RESOLVE_OTA_BIN:-$ROOT/buildroot-ihost/rootfs-overlay/usr/sbin/ga-resolve-ota}"

run_test "MWD-S00" "the watchdog script exists and is executable" "test -x '$WD'"
command -v jq >/dev/null 2>&1 || { echo "jq missing — cannot run"; suite_end; exit 2; }

W="$(mktemp -d 2>/dev/null || echo /tmp/mesh_wd_$$)"
mkdir -p "$W/bin" "$W/share" "$W/stage" "$W/state"

# ---------------------------------------------------------------- the stubs
# curl: the mesh probe. $W/curl_rc dictates the exit code, i.e. what the far
# end did. 7 = could not connect, 28 = timed out, 0 = answered, 52 = connected
# but sent nothing — packets crossed, so the mesh is alive.
cat > "$W/bin/curl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$W/curl.log"
exit \$(cat "$W/curl_rc" 2>/dev/null || echo 7)
STUB

# netbird: what the client CLAIMS. Empty file = the client answered nothing.
cat > "$W/bin/netbird" <<STUB
#!/bin/sh
cat "$W/nb_json" 2>/dev/null
STUB

# systemctl: records the action instead of taking it.
cat > "$W/bin/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$W/restarts.log"
exit \${SYSTEMCTL_RC:-0}
STUB

# ip: the routing table. \$W/route_dev is the device the probe address leaves by.
cat > "$W/bin/ip" <<STUB
#!/bin/sh
dev=\$(cat "$W/route_dev" 2>/dev/null || echo wt0)
[ "\$dev" = "none" ] && exit 2
echo "203.0.113.9 dev \$dev src 203.0.113.10 uid 0"
STUB

# date: a movable clock, so the one-restart-per-hour limit can actually be
# tested instead of asserted. Only `+%s` is intercepted.
cat > "$W/bin/date" <<STUB
#!/bin/sh
if [ "\$1" = "+%s" ]; then
  echo \$(( \$(/bin/date +%s) + \$(cat "$W/clock_offset" 2>/dev/null || echo 0) ))
else
  exec /bin/date "\$@"
fi
STUB
chmod +x "$W/bin/curl" "$W/bin/netbird" "$W/bin/systemctl" "$W/bin/ip" "$W/bin/date"

# A ga-services.conf with no address in it beyond the loopback the stubs use.
printf 'GA_SERVICES_IP=127.0.0.1\nGA_FLEET_PORT=8090\n' > "$W/ga-services.conf"

CLAIMS_UP='{"daemonStatus":"Connected","management":{"url":"https://api.example","connected":true},"peers":{"total":23,"connected":23}}'
CLAIMS_DOWN='{"daemonStatus":"Connecting","management":{"url":"https://api.example","connected":false},"peers":{"total":23,"connected":0}}'
CLAIMS_DRIFT='{"daemonStatus":"Connected","peers":{"total":23,"connected":23}}'

now() { echo $(( $(/bin/date +%s) + $(cat "$W/clock_offset" 2>/dev/null || echo 0) )); }

# write_ota <wan_up true|false|null> [age_s]
write_ota() {
  _age="${2:-0}"
  printf '{"schema_version":1,"ts":%s,"host":"ota.example","chosen":"203.0.113.9","reachable":true,"wan_up":%s,"mesh_up":false,"mesh_iface":"wt0","paths":[]}\n' \
    "$(( $(now) - _age ))" "$1" > "$W/ota.state"
}

# tick [curl_rc] [claims-json] — run the live script once
tick() {
  printf '%s' "${1:-7}" > "$W/curl_rc"
  # ${2-…} and not ${2:-…}: an EMPTY second argument means "the client
  # answered nothing", which is a fixture in its own right.
  printf '%s' "${2-$CLAIMS_UP}" > "$W/nb_json"
  PATH="$W/bin:/usr/bin:/bin" \
  GA_MESH_CONF_OVERRIDE="$W/ga-services.conf" GA_MESH_CONF_DEFAULT="$W/ga-services.conf" \
  GA_OTA_STATE_FILE="$W/ota.state" \
  GA_MESH_STATE_DIR="$W/state" GA_MESH_STATE_FILE="$W/state/wd.state" \
  GA_MESH_SHARE_FILE="$W/share/ga-mesh-watchdog.json" \
  GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$W/stage" \
  GA_MESH_RESTART_UNIT=netbird SYSTEMCTL_RC="${SYSTEMCTL_RC:-0}" \
  sh "$WD" > "$W/out" 2>&1
  echo $? > "$W/rc"
}

reset_all() {
  rm -f "$W/restarts.log" "$W/state/wd.state" "$W/share/ga-mesh-watchdog.json" "$W/curl.log"
  printf 'wt0' > "$W/route_dev"
  printf '0' > "$W/clock_offset"
  SYSTEMCTL_RC=0
  write_ota true
}
j()        { jq -r "$1" "$W/share/ga-mesh-watchdog.json" 2>/dev/null; }
restarts() { [ -f "$W/restarts.log" ] && wc -l < "$W/restarts.log" | tr -d ' ' || echo 0; }

# ═══════════════════════════════════════════════════ MUST-FIRE
echo ""
echo "--- MUST-FIRE: the client claims a mesh that carries no packets ---"

reset_all
tick 7
run_test "MWD-S01" "one dead tick is dead, counted, and does NOT restart yet" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = dead ] \
   && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 1 ] \
   && [ \"\$(jq -r .wan_up '$W/share/ga-mesh-watchdog.json')\" = true ] \
   && [ \"\$(jq -r .client_claims_connected '$W/share/ga-mesh-watchdog.json')\" = true ] \
   && [ ! -f '$W/restarts.log' ]"
run_test "MWD-S01b" "…and the dead tick is logged at err priority (<3>), not info" \
  "grep -q '^<3>ga-mesh-watchdog: dead:' '$W/out'"

tick 7
run_test "MWD-S02" "two dead ticks: counter at 2, still no restart" \
  "[ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 2 ] && [ ! -f '$W/restarts.log' ]"

tick 7
run_test "MWD-S03" "the third dead tick restarts the mesh client EXACTLY ONCE" \
  "[ \"\$(restarts)\" = 1 ] && grep -qx 'restart netbird' '$W/restarts.log'"
run_test "MWD-S04" "…the counter resets, the cooldown starts, and the tick says so" \
  "[ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 0 ] \
   && [ \"\$(jq -r .last_restart_ts '$W/share/ga-mesh-watchdog.json')\" -gt 0 ] \
   && [ \"\$(jq -r .restarts_24h '$W/share/ga-mesh-watchdog.json')\" = 1 ] \
   && jq -e '.detail | test(\"restarted netbird\")' '$W/share/ga-mesh-watchdog.json' >/dev/null"
run_test "MWD-S04b" "…and the restart is logged at err priority (<3>)" \
  "grep -q '^<3>ga-mesh-watchdog: restarted netbird' '$W/out'"

for _i in 1 2 3 4 5; do tick 7; done
run_test "MWD-S05" "five more dead ticks inside the hour: the cooldown HOLDS, still one restart" \
  "[ \"\$(restarts)\" = 1 ] && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 5 ]"

# The hour passes while the mesh is STILL dead. The three-tick threshold is
# about not acting on a transient, and after five more dead ticks that question
# is long settled — so the first tick past the cooldown restarts, and it must
# restart only once.
printf '3700' > "$W/clock_offset"; write_ota true
tick 7
run_test "MWD-S06" "the first tick past the cooldown restarts again — the streak already stands" \
  "[ \"\$(restarts)\" = 2 ] && [ \"\$(jq -r .restarts_24h '$W/share/ga-mesh-watchdog.json')\" = 2 ]"
tick 7; tick 7; tick 7
run_test "MWD-S07" "…and the new cooldown immediately holds the next three" \
  "[ \"\$(restarts)\" = 2 ] && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 3 ]"

# A fresh streak, however, must still take three ticks: after a recovery the
# counter is back at zero and the threshold applies from scratch.
reset_all; printf '7300' > "$W/clock_offset"; write_ota true
tick 0                    # alive: streak cleared
tick 7; tick 7
run_test "MWD-S07b" "a streak that starts from zero still needs all three ticks" \
  "[ ! -f '$W/restarts.log' ] && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 2 ]"
tick 7
run_test "MWD-S07c" "…and fires on the third" \
  "[ \"\$(restarts)\" = 1 ]"

tick 0
run_test "MWD-S08" "a mesh that answers again is alive; the restart history survives" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = alive ] \
   && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 0 ] \
   && [ \"\$(jq -r .last_restart_ts '$W/share/ga-mesh-watchdog.json')\" -gt 0 ] \
   && [ \"\$(jq -r .restarts_24h '$W/share/ga-mesh-watchdog.json')\" = 1 ]"

reset_all
SYSTEMCTL_RC=1
tick 7; tick 7; tick 7
run_test "MWD-S09" "a restart that FAILS is recorded, does not start the cooldown, and keeps the streak" \
  "[ \"\$(restarts)\" = 1 ] \
   && [ \"\$(jq -r .last_restart_ts '$W/share/ga-mesh-watchdog.json')\" = 0 ] \
   && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 3 ] \
   && [ \"\$(jq -r .restarts_24h '$W/share/ga-mesh-watchdog.json')\" = 0 ] \
   && grep -q 'restart of netbird FAILED' '$W/share/ga-mesh-watchdog.json'"
SYSTEMCTL_RC=0

# ═══════════════════════════════════════════════════ MUST-NOT-FIRE
echo ""
echo "--- MUST-NOT-FIRE: everything that is NOT a lying client ---"

reset_all; write_ota false
for _i in 1 2 3 4 5; do tick 7; done
run_test "MWD-S10" "WAN down: the site is offline, not the client — outage, never a restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = outage ] \
   && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 0 ] \
   && [ ! -f '$W/restarts.log' ]"

reset_all; write_ota null
for _i in 1 2 3 4 5; do tick 7; done
run_test "MWD-S11" "WAN never probed (null): unproven is not up — outage, never a restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = outage ] && [ ! -f '$W/restarts.log' ]"

reset_all
for _i in 1 2 3 4 5; do tick 7 "$CLAIMS_DOWN"; done
run_test "MWD-S12" "the client reports itself down: its own reconnect owns it — no restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = outage ] \
   && [ \"\$(jq -r .client_claims_connected '$W/share/ga-mesh-watchdog.json')\" = false ] \
   && [ ! -f '$W/restarts.log' ]"

reset_all
for _i in 1 2 3 4 5; do tick 0; done
run_test "MWD-S13" "a mesh that answers is alive — no restart, ever" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = alive ] && [ ! -f '$W/restarts.log' ]"

reset_all
for _i in 1 2 3 4 5; do tick 52; done
run_test "MWD-S14" "an empty reply still proves packets crossed — alive, no restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = alive ] && [ ! -f '$W/restarts.log' ]"

reset_all; rm -f "$W/ota.state"
for _i in 1 2 3 4 5; do tick 7; done
run_test "MWD-S15" "no WAN verdict at all: unknown, one err line, no restart (fail closed)" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = unknown ] \
   && grep -q '^<3>ga-mesh-watchdog: unknown:' '$W/out' && [ ! -f '$W/restarts.log' ]"

reset_all; write_ota true 4000
for _i in 1 2 3 4 5; do tick 7; done
run_test "MWD-S16" "a STALE WAN verdict is unknown, not up — no restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = unknown ] \
   && grep -q 'stopped probing' '$W/out' && [ ! -f '$W/restarts.log' ]"

reset_all
for _i in 1 2 3 4 5; do tick 7 ''; done
run_test "MWD-S17" "the client answers nothing: cannot tell down from lying — unknown, no restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = unknown ] && [ ! -f '$W/restarts.log' ]"

reset_all
for _i in 1 2 3 4 5; do tick 7 "$CLAIMS_DRIFT"; done
run_test "MWD-S18" "client status without management.connected: schema drift — unknown, no restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = unknown ] \
   && grep -q 'schema drift' '$W/out' && [ ! -f '$W/restarts.log' ]"

reset_all; printf 'eth0' > "$W/route_dev"
for _i in 1 2 3 4 5; do tick 7; done
run_test "MWD-S19" "the peer does not route over the mesh: this is not a mesh probe — unknown, no restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = unknown ] \
   && grep -q \"not wt0\" '$W/out' && [ ! -f '$W/restarts.log' ]"

reset_all; printf 'none' > "$W/route_dev"
for _i in 1 2 3; do tick 7; done
run_test "MWD-S20" "no route at all: unknown, no restart" \
  "[ \"\$(jq -r .state '$W/share/ga-mesh-watchdog.json')\" = unknown ] && [ ! -f '$W/restarts.log' ]"

# The fail-closed branch must not merely skip: it must also drop the streak, or
# a restart could ride on two dead ticks separated by a blind spell.
reset_all
tick 7; tick 7
rm -f "$W/ota.state"; tick 7             # one blind tick
write_ota true; tick 7; tick 7
run_test "MWD-S21" "an unknown tick RESETS the streak — a restart never rides across a blind spell" \
  "[ ! -f '$W/restarts.log' ] && [ \"\$(jq -r .consecutive_dead '$W/share/ga-mesh-watchdog.json')\" = 2 ]"

# ═══════════════════════════════════════════════════ the surface itself
echo ""
echo "--- the /share surface and the disclosure rule ---"

reset_all; tick 7
run_test "MWD-S22" "the /share bridge file carries every field the fleet needs" \
  "jq -e 'has(\"ts\") and has(\"state\") and has(\"consecutive_dead\") and has(\"restarts_24h\") \
          and has(\"last_restart_ts\") and has(\"wan_up\") and has(\"client_claims_connected\")' \
     '$W/share/ga-mesh-watchdog.json' >/dev/null"
run_test "MWD-S23" "…published through ga-share-publish, so a planted symlink cannot redirect it" \
  "grep -q 'GA_SHARE_PUBLISH\|ga-share-publish' '$WD'"

# Rule 7 / the public-repository disclosure rule: the probe target comes from
# the routing table and ga-services.conf, never from an address written here.
# `test -f` first, deliberately: a `! grep` over a file that does not exist
# succeeds, and a check that passes over nothing is a false green (rule 9).
# It did exactly that in the red proof for this suite.
run_test "MWD-S24" "the watchdog hardcodes no address — it asks the routing table" \
  "test -f '$WD' && ! grep -v '^[[:space:]]*#' '$WD' | grep -qE '([0-9]{1,3}\\.){3}[0-9]{1,3}'"

# ═══════════════════════════════════════ the WAN half, in the producer
echo ""
echo "--- ga-resolve-ota publishes the verdict the watchdog reads ---"

run_test "MWD-S25" "ga-resolve-ota exists and publishes a state file" \
  "test -f '$RESOLVE' && grep -q 'STATE_FILE' '$RESOLVE'"

# Drive the REAL resolver with a stub curl: the mesh path fails, the public one
# answers. That is the incident shape, and it must come out as wan_up=true.
cat > "$W/bin/curl" <<STUB
#!/bin/sh
for a in "\$@"; do case "\$a" in *:443:*) ip=\${a##*:} ;; esac; done
grep -qx "\$ip" "$W/ota_reachable" 2>/dev/null
STUB
chmod +x "$W/bin/curl"
cat > "$W/bin/ip" <<STUB
#!/bin/sh
# 198.51.100.x is the mesh in this fixture, 203.0.113.x is the public path.
case "\$3" in 198.51.100.*) d=wt0 ;; *) d=eth0 ;; esac
echo "\$3 dev \$d src 203.0.113.10 uid 0"
STUB
chmod +x "$W/bin/ip"
printf 'GA_OTA_HOST=ota.example\nGA_OTA_IPS="198.51.100.1 203.0.113.9"\n' > "$W/ota-conf"
# The resolver sources its own conf; the fixture is handed to it as the runtime
# override it already supports, with ACTIVE_FILE redirected out of /run.
cp "$W/ota-conf" "$W/mnt-ga-services.conf"

run_one() {   # $1.. = reachable ips
  printf '%s\n' "$@" > "$W/ota_reachable"
  rm -f "$W/resolved.state" "$W/active"
  ( PATH="$W/bin:/usr/bin:/bin"; export PATH
    GA_OTA_STATE_FILE="$W/resolved.state"; export GA_OTA_STATE_FILE
    GA_MESH_IFACE=wt0; export GA_MESH_IFACE
    sed -e "s#^CONF_OVERRIDE=.*#CONF_OVERRIDE=\"$W/mnt-ga-services.conf\"#" \
        -e "s#^ACTIVE_FILE=.*#ACTIVE_FILE=\"$W/active\"#" "$RESOLVE" > "$W/resolve.sh"
    sh "$W/resolve.sh" ) > "$W/resolve.out" 2>&1
}

run_one 203.0.113.9
run_test "MWD-S26" "mesh path dead + public path answers → wan_up=true, mesh_up=false (the incident shape)" \
  "[ \"\$(jq -r .wan_up '$W/resolved.state')\" = true ] \
   && [ \"\$(jq -r .mesh_up '$W/resolved.state')\" = false ] \
   && [ \"\$(jq -r .reachable '$W/resolved.state')\" = true ]"

run_one 198.51.100.1 203.0.113.9
run_test "MWD-S27" "mesh path answers first → wan_up=null (NOT probed is not NOT reachable)" \
  "[ \"\$(jq -r .wan_up '$W/resolved.state')\" = null ] \
   && [ \"\$(jq -r .mesh_up '$W/resolved.state')\" = true ]"

run_one
run_test "MWD-S28" "nothing answers → reachable=false, wan_up=false, and it is PUBLISHED (it used to exit silently)" \
  "test -f '$W/resolved.state' \
   && [ \"\$(jq -r .reachable '$W/resolved.state')\" = false ] \
   && [ \"\$(jq -r .wan_up '$W/resolved.state')\" = false ]"

run_one 203.0.113.9
run_test "MWD-S29" "…and 'via' comes from the routing table, per path" \
  "[ \"\$(jq -r '.paths[0].via' '$W/resolved.state')\" = wt0 ] \
   && [ \"\$(jq -r '.paths[1].via' '$W/resolved.state')\" = eth0 ]"

rm -rf "$W" 2>/dev/null
suite_end
