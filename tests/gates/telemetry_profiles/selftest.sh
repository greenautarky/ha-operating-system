#!/usr/bin/env bash
# telemetry_profiles/selftest.sh — the telemetry profiles (ADR-0045) keep every
# error flowing, drop only what they are meant to drop, and are applied the way
# the seam contract says.
#
# PART A — the data path (the subject, not a model of it)
#   The REAL fluent-bit the image builds runs over a fixture journal with:
#     tier0/normal  the config fluent-bit-tier0.service loads (+ its @INCLUDE,
#                   ga-telemetry-config at the version.yaml pin)
#     tier0/lte     what the LIVE ga-telemetry-profile-apply renders for lte_saver
#     tier1/normal  the shipped fluent-bit.conf
#     tier1/lte     its lte_saver rendering
#   Only what cannot run off-device is rewritten (journal Path, scratch DB and
#   storage, Loki -> stdout, Flush 1 — the rendered Flush 900 is asserted
#   statically instead, a test cannot wait 15 min). Fixture ids:
#     E*  errors       MUST ship in every profile   (errors always reach the centre)
#     L*  lifecycle    MUST ship in every profile   (RAUC/OTA, failed logins: CRA)
#     N*  routine      ship in normal, MUST be dropped in lte_saver
#   Mutants (each must fail on exactly its case):
#     strict    lte converge filter keeps CRITICAL only   -> E3 lost
#     nofilter  lte rendering without its converge filter -> N1 shipped
#
# PART B — the apply logic (live script, systemctl stubbed, scratch dirs)
#   path change normal -> lte_saver -> lte_saver -> normal, minimal, missing,
#   invalid, symlinked and unknown requests; drop-ins, reloads, restarts and the
#   read-back in ga_manager's data directory.
#
# PART C — the rendered telegraf config loads in the pinned telegraf and
#   gathers only the essentials (mem, disk, temp).
#
# Exit 0 = all green, 1 = a verdict failed, 2 = could not check (never green).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APPLY="$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-telemetry-profile-apply"
T0_UNIT="$ROOT/buildroot-external/rootfs-overlay/etc/systemd/system/fluent-bit-tier0.service"
OVERLAY_ETC="$ROOT/buildroot-external/rootfs-overlay/etc/fluent-bit"
PKG_FB="$ROOT/buildroot-external/package/fluent-bit-config"
TG_CONF="$ROOT/buildroot-external/package/telegraf/telegraf.conf"
VERSION_YAML="$ROOT/version.yaml"
FB_IMAGE="${FLUENT_BIT_IMAGE:-fluent/fluent-bit@sha256:d6dec000c4929a439562525728c708f6e99800d7ddc82efd6aa4f45f3a20b562}"
TG_VERSION="$(sed -n 's/^TELEGRAF_VERSION[[:space:]]*=[[:space:]]*//p' "$ROOT/buildroot-external/package/telegraf/telegraf.mk" | head -1)"
TG_IMAGE="${TELEGRAF_IMAGE:-telegraf:${TG_VERSION}}"

die2() { echo "ERROR (could not check): $*" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/tprof.XXXXXX")"; chmod 755 "$W"
trap 'rm -rf "$W"' EXIT
for f in "$APPLY" "$T0_UNIT" "$PKG_FB/fluent-bit.conf" "$PKG_FB/parsers.conf" "$TG_CONF" "$VERSION_YAML"; do
  [ -f "$f" ] || die2 "$f not found"
done
command -v docker >/dev/null || die2 "docker not on PATH"
command -v jq >/dev/null || die2 "jq not on PATH"
[ -n "$TG_VERSION" ] || die2 "cannot read TELEGRAF_VERSION"

JR="${JOURNAL_REMOTE:-}"
if [ -z "$JR" ]; then
  for c in /usr/lib/systemd/systemd-journal-remote /lib/systemd/systemd-journal-remote; do
    [ -x "$c" ] && { JR="$c"; break; }
  done
fi
[ -n "$JR" ] || die2 "systemd-journal-remote not found (apt: systemd-journal-remote; or set JOURNAL_REMOTE)"

rc=0; pass=0
ok()  { pass=$((pass + 1)); echo "  ok    $1"; }
bad() { rc=1; echo "  FAIL  $1"; }

# --- the live configs, as on the device ---------------------------------------
ETC="$W/etc"; mkdir -p "$ETC"
ENTRY="$(grep -E '^ExecStart=' "$T0_UNIT" | grep -oE -- '-c[[:space:]]+/etc/fluent-bit/[A-Za-z0-9._-]+' | awk '{print $2}')"
[ "$(printf '%s\n' "$ENTRY" | grep -c .)" = 1 ] || die2 "expected one -c in $T0_UNIT"
ENTRY="${ENTRY##*/}"
cp "$OVERLAY_ETC/$ENTRY" "$ETC/" || die2 "$ENTRY not in $OVERLAY_ETC"
TC_VER="$(sed -n 's/^[[:space:]]*ga-telemetry-config:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_YAML")"
if [ -n "${TIER0_OVERLAY_CONF:-}" ]; then
  cp "$TIER0_OVERLAY_CONF" "$ETC/fluent-bit-tier0.conf" || die2 "cannot read $TIER0_OVERLAY_CONF"
else
  curl -fsS --retry 3 --max-time 30 -o "$ETC/fluent-bit-tier0.conf" \
    "https://raw.githubusercontent.com/greenautarky/ga-telemetry-config/v${TC_VER}/src/ga-telemetry-config/etc/fluent-bit/fluent-bit-tier0.conf" \
    || die2 "cannot fetch ga-telemetry-config v$TC_VER"
fi
cp "$PKG_FB/fluent-bit.conf" "$PKG_FB/parsers.conf" "$ETC/"

# --- render lte_saver with the LIVE script ------------------------------------
REN="$W/rendered"
GA_FB_T0_ENTRY="$ETC/$ENTRY" GA_FB_T1="$ETC/fluent-bit.conf" GA_TG_CONF="$TG_CONF" \
  sh "$APPLY" render lte_saver "$REN" || die2 "render lte_saver failed"
for f in tier0.conf tier1.conf telegraf.conf; do [ -s "$REN/$f" ] || die2 "render produced no $f"; done
GA_FB_T0_ENTRY="$ETC/$ENTRY" GA_FB_T1="$ETC/fluent-bit.conf" GA_TG_CONF="$TG_CONF" \
  sh "$APPLY" render minimal "$W/rendered-minimal" || die2 "render minimal failed"
[ ! -e "$W/rendered-minimal/tier0.conf" ] && ok "minimal renders nothing (base units, as normal)" || bad "minimal rendered configs"

echo "static (rendered lte_saver):"
svc_flush() { awk '/^[[:space:]]*\[/{s=toupper($1)} s=="[SERVICE]" && tolower($1)=="flush"{print $2}' "$1"; }
[ "$(svc_flush "$REN/tier0.conf")" = 900 ] && ok "tier0 Flush 900" || bad "tier0 Flush is '$(svc_flush "$REN/tier0.conf")'"
[ "$(svc_flush "$REN/tier1.conf")" = 900 ] && ok "tier1 Flush 900" || bad "tier1 Flush is '$(svc_flush "$REN/tier1.conf")'"
gz="$(awk '/^[[:space:]]*\[/{o=(toupper($1)=="[OUTPUT]"); l=0} o&&tolower($1)=="name"&&$2=="loki"{l=1} o&&l&&tolower($1)=="compress"{print $2}' "$REN/tier0.conf")"
[ "$gz" = gzip ] && ok "tier0 Loki output gzip" || bad "tier0 Loki output compress='$gz'"
grep -q '^@INCLUDE' "$REN/tier0.conf" && bad "tier0 rendering still has an @INCLUDE (it lives in /run)" || ok "tier0 rendering is self-contained"
inputs="$(grep -oE '^\[\[inputs\.[a-z_]+\]\]' "$REN/telegraf.conf" | sed 's/\[\[inputs\.//; s/\]\]//' | sort | tr '\n' ' ')"
[ "$inputs" = "disk mem temp " ] && ok "telegraf inputs: $inputs" || bad "telegraf inputs: '$inputs' (want disk mem temp)"
grep -qE '^[[:space:]]*interval = "1800s"' "$REN/telegraf.conf" && grep -qE '^[[:space:]]*flush_interval = "1800s"' "$REN/telegraf.conf" \
  && ok "telegraf every 30 min" || bad "telegraf interval/flush not 1800s"
grep -q '^\[\[outputs.influxdb\]\]' "$REN/telegraf.conf" && grep -q '^\[global_tags\]' "$REN/telegraf.conf" \
  && ok "telegraf keeps outputs and global tags" || bad "telegraf lost its output or tags"

# --- PART A: fixture journal --------------------------------------------------
BOOT=0f4c2a1e9b7d4c3a8e6f5d4c3b2a1908; T0=1791446400000000; n=0
: > "$W/fixture.export"
rec() {  # rec ID "MESSAGE suffix" FIELD=VALUE...
  local id="$1" msg="$2"; shift 2; n=$((n + 1))
  { echo "__REALTIME_TIMESTAMP=$((T0 + n * 1000000))"; echo "__MONOTONIC_TIMESTAMP=$((n * 1000000))"
    echo "_BOOT_ID=$BOOT"; echo "_HOSTNAME=fixture"; printf '%s\n' "$@"
    echo "MESSAGE=FIXTURE-$id $msg"; echo; } >> "$W/fixture.export"
}
GM=addon_99f1cad4_ga_manager
# tier-0 sources
rec E1 "kernel: Out of memory" _TRANSPORT=kernel PRIORITY=3 SYSLOG_IDENTIFIER=kernel
rec E2 "ERROR (MainThread) [supervisor.addons] start failed" CONTAINER_NAME=hassio_supervisor _SYSTEMD_UNIT=docker.service PRIORITY=3
rec E3 '{"logger": "ga_manager.jobs", "level": "ERROR", "msg": "[job x/converge] step failed"}' CONTAINER_NAME=$GM _SYSTEMD_UNIT=docker.service PRIORITY=3
rec E4 "rauc: installation failed" _SYSTEMD_UNIT=rauc.service PRIORITY=3 SYSLOG_IDENTIFIER=rauc
rec E5 "OTA download failed" _SYSTEMD_UNIT=ga-rauc-install.service PRIORITY=3 SYSLOG_IDENTIFIER=ga-rauc-install
rec L1 "rauc: installation started" _SYSTEMD_UNIT=rauc.service PRIORITY=6 SYSLOG_IDENTIFIER=rauc
rec L2 "Bad password attempt for root" _SYSTEMD_UNIT=dropbear.service PRIORITY=4 SYSLOG_IDENTIFIER=dropbear
rec N1 '{"logger": "ga_manager.workers.converge", "level": "INFO", "msg": "step 3/9 ok"}' CONTAINER_NAME=$GM _SYSTEMD_UNIT=docker.service PRIORITY=3
# tier-1 sources
rec E6 "netbird: management connection lost" _SYSTEMD_UNIT=netbird.service PRIORITY=3 SYSLOG_IDENTIFIER=netbird
rec E7 '{"logger": "ga_manager.health", "level": "ERROR", "msg": "check crashed"}' CONTAINER_NAME=$GM _SYSTEMD_UNIT=docker.service PRIORITY=3
rec N2 "network: carrier flapped" _SYSTEMD_UNIT=network.service PRIORITY=4 SYSLOG_IDENTIFIER=network
rec N3 '{"logger": "ga_manager.health", "level": "WARNING", "msg": "slow tick"}' CONTAINER_NAME=$GM _SYSTEMD_UNIT=docker.service PRIORITY=3
mkdir -p "$W/journal"
"$JR" --output="$W/journal/fixture.journal" "$W/fixture.export" >"$W/jr.log" 2>&1 \
  || { cat "$W/jr.log" >&2; die2 "systemd-journal-remote failed"; }
[ -s "$W/journal/fixture.journal" ] || die2 "no journal written"

# offline SRC DST MATCH — device-only bits rewritten, stdout output for MATCH.
offline() {
  awk -v jdir=/w/journal '
    function flush_block() {
      if (blk == "") return
      if (!(isout && isloki)) printf "%s", blk
      if (insys) { print "    Path                " jdir; nsys++ }
      blk = ""; isout = 0; isloki = 0; insys = 0
    }
    /^[[:space:]]*\[/ || /^@INCLUDE/ {
      flush_block()
      if ($0 ~ /^@INCLUDE/) { print; next }
      inp = ($0 ~ /\[INPUT\]/); isout = ($0 ~ /\[OUTPUT\]/)
      blk = $0 "\n"; next
    }
    blk != "" {
      if (tolower($1) == "name" && $2 == "loki") isloki = 1
      if (inp && tolower($1) == "name" && $2 == "systemd") insys = 1
      if ($1 == "DB")                    { sub(/\/mnt\/data\/fluent-bit\/db/, "/w/db") }
      if (tolower($1) == "storage.path") { $0 = "    storage.path /w/storage" }
      if (tolower($1) == "flush")        { $0 = "    Flush 1" }
      if (tolower($1) == "parsers_file") { $0 = "    Parsers_File /w/etc/parsers.conf" }
      if (tolower($1) == "path" && inp && !insys) { $0 = "    Path /w/none.log" }
      if ($1 == "Read_From_Tail") next
      blk = blk $0 "\n"; next
    }
    { print }
    END { flush_block(); print nsys + 0 > "/dev/stderr" }
  ' "$1" > "$2" 2> "$2.nsys"
  printf '\n[OUTPUT]\n    Name    stdout\n    Match   %s\n    Format  json_lines\n' "$3" >> "$2"
}

# run NAME CONF MATCH [EXTRA_CONF...] — output in $W/out.NAME
run() {
  local name="$1" conf="$2" match="$3"; shift 3
  local d="$W/run.$name"; mkdir -p "$d/etc" "$d/db" "$d/storage"
  cp "$ETC/parsers.conf" "$d/etc/"
  local f; for f in "$@"; do offline "$f" "$d/etc/$(basename "$f")" "__none__"; sed -i '/^\[OUTPUT\]$/,$d' "$d/etc/$(basename "$f")"; done
  offline "$conf" "$d/etc/main.conf" "$match"
  local declared rewritten
  declared="$(cat "$conf" "$@" | awk '/^\[INPUT\]/{i=1;next} /^\[/{i=0} i&&tolower($1)=="name"&&$2=="systemd"{c++} END{print c+0}')"
  rewritten="$(cat "$d"/etc/*.nsys | awk '{s+=$1} END{print s+0}')"
  [ "$rewritten" -ge 1 ] && [ "$rewritten" = "$declared" ] || die2 "$name: rewrote $rewritten of $declared systemd inputs"
  cp -r "$W/journal" "$d/journal"; chmod -R a+rwX "$d"
  local cid
  cid="$(docker run -d --user "$(id -u):$(id -g)" -v "$d:/w" \
          -e GA_ENV=ci -e DEVICE_LABEL=FIXTURE -e DEVICE_UUID=00000000-0000-0000-0000-000000000000 \
          -e LOKI_HOST=x -e LOKI_PORT=1 -e LOKI_USER=x -e LOKI_PASSWORD=x -e LOKI_TENANT=x \
          "$FB_IMAGE" /fluent-bit/bin/fluent-bit -c /w/etc/main.conf)" || die2 "$name: docker run failed"
  sleep 6; docker stop -t 10 "$cid" >/dev/null 2>&1
  docker logs "$cid" > "$W/out.$name" 2> "$W/err.$name"; docker rm "$cid" >/dev/null 2>&1
  grep -q '"MESSAGE":"FIXTURE-' "$W/out.$name" || { tail -5 "$W/err.$name" >&2; die2 "$name: shipped nothing (did fluent-bit start?)"; }
}

# verdict NAME "SHIP ids" "DROP ids" — prints, sets FAILED
verdict() {
  local name="$1" id c; FAILED=""
  for id in $2; do
    c="$(grep -c "\"MESSAGE\":\"FIXTURE-$id " "$W/out.$name")"
    if [ "$c" = 1 ]; then echo "    ok    $id shipped"; else echo "    FAIL  $id shipped $c times (want 1)"; FAILED="$FAILED $id"; fi
  done
  for id in $3; do
    c="$(grep -c "\"MESSAGE\":\"FIXTURE-$id " "$W/out.$name")"
    if [ "$c" = 0 ]; then echo "    ok    $id dropped"; else echo "    FAIL  $id shipped $c times (want 0)"; FAILED="$FAILED $id"; fi
  done
  FAILED="${FAILED# }"
}
case_() {  # case_ NAME SHIP DROP CONF MATCH [EXTRA]
  local name="$1" ship="$2" drop="$3"; shift 3
  run "$name" "$@"
  echo "  $name:"; verdict "$name" "$ship" "$drop"
  [ -z "$FAILED" ] && pass=$((pass + 1)) || { rc=1; echo "  FAIL  $name: [$FAILED]"; }
}

T0_ERR="E1 E2 E3 E4 E5 L1 L2"
echo "part A — real fluent-bit over the fixture journal:"
case_ tier0-normal "$T0_ERR N1" "E6 N2"      "$ETC/$ENTRY" "tier0.*" "$ETC/fluent-bit-tier0.conf"
case_ tier0-lte    "$T0_ERR"    "N1 E6 N2"   "$REN/tier0.conf" "tier0.*"
case_ tier1-normal "E6 E7 N2 N3" ""          "$ETC/fluent-bit.conf" "ihost.*"
case_ tier1-lte    "E6 E7"      "N2 N3"      "$REN/tier1.conf" "ihost.*"

mutant() {  # mutant NAME WANT_FAILED CONF SHIP DROP
  local name="$1" want="$2" conf="$3"
  run "$name" "$conf" "tier0.*"
  echo "  mutant $name:"; verdict "$name" "$4" "$5" > "$W/verdict.$name"; sed 's/^/  /' "$W/verdict.$name"
  if [ "$FAILED" = "$want" ]; then echo "    -> red on exactly [$want], as required"; pass=$((pass + 1))
  else echo "    -> WRONG: must fail on exactly [$want], failed on [${FAILED:-nothing}]"; rc=1; fi
}
sed 's/"(ERROR|CRITICAL)"/"(CRITICAL)"/' "$REN/tier0.conf" > "$W/mut-strict.conf"
grep -q '"(CRITICAL)"' "$W/mut-strict.conf" || die2 "strict mutant: the converge filter was not found to mutate"
mutant strict "E3" "$W/mut-strict.conf" "$T0_ERR" "N1"
awk '/^# --- lte_saver/{exit} {print}' "$REN/tier0.conf" > "$W/mut-nofilter.conf"
mutant nofilter "N1" "$W/mut-nofilter.conf" "$T0_ERR" "N1"

# --- PART B: apply logic --------------------------------------------------------
echo "part B — apply logic (live script, systemctl stubbed):"
B="$W/b"; mkdir -p "$B/gm" "$B/run" "$B/dropins" "$B/stage" "$B/bin"
cat > "$B/bin/systemctl" <<'EOF'
#!/bin/sh
# Stub with a fake /proc: a restart starts a NEW main process that runs what the
# unit's drop-in names (the base config without one) — unless FROZEN=1, which
# models a restart that does not take. --no-block only queues (no effect here).
echo "$*" >> "$SYSTEMCTL_LOG"
nb=0; [ "$1" = --no-block ] && { nb=1; shift; }
pidf() { echo "$GA_PROFILE_PROC/units/$1"; }
spawn() {  # $1 unit -> new pid running the drop-in's config
  d="$GA_PROFILE_DROPIN_ROOT/$1.d/50-ga-profile.conf"
  if [ -f "$d" ]; then cfg="$(grep -oE "[^ ']*/lte-saver/[a-z0-9]+[.]conf" "$d" | tail -1)"; else cfg="/etc/base/$1.conf"; fi
  n=$(( $(cat "$GA_PROFILE_PROC/next" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$GA_PROFILE_PROC/next"
  mkdir -p "$GA_PROFILE_PROC/$n" "$GA_PROFILE_PROC/units"
  printf '/usr/bin/x\000-c\000%s\000' "$cfg" > "$GA_PROFILE_PROC/$n/cmdline"; echo "$n" > "$(pidf "$1")"
}
case "$1" in
  is-active)   case " $ACTIVE " in *" $3 "*) exit 0 ;; *) exit 3 ;; esac ;;
  show)        if [ -f "$(pidf "$5")" ]; then cat "$(pidf "$5")"; else echo 0; fi ;;
  try-restart) case " $ACTIVE " in *" $2 "*) [ "$nb" = 0 ] && [ "${FROZEN:-0}" != 1 ] && spawn "$2" ;; esac ;;
  _spawn)      spawn "$2" ;;
esac
exit 0
EOF
cat > "$B/bin/publish" <<'EOF'
#!/bin/sh
cat > "$1.tmp" && mv -f "$1.tmp" "$1"
EOF
chmod +x "$B/bin/systemctl" "$B/bin/publish"
export GA_PROFILE_PROC="$B/proc" GA_PROFILE_DROPIN_ROOT="$B/dropins" GA_PROFILE_VERIFY_S=1
mkdir -p "$B/proc"
apply() {  # apply ACTIVE_UNITS [script args] — runs the live script once; output in $B/out
  : > "$B/sysctl"; _a="$1"; shift
  for _u in fluent-bit-tier0.service fluent-bit.service telegraf.service; do  # systemd's view: stopped = no process,
    case " $_a " in                                                          # started = runs what its drop-in names
      *" $_u "*) [ -f "$B/proc/units/$_u" ] || SYSTEMCTL_LOG=/dev/null "$B/bin/systemctl" _spawn "$_u" ;;
      *) rm -f "$B/proc/units/$_u" ;;
    esac
  done
  ACTIVE="$_a" SYSTEMCTL_LOG="$B/sysctl" SYSTEMCTL="$B/bin/systemctl" GA_SHARE_PUBLISH="$B/bin/publish" \
  GA_GM_DATA_DIR="$B/gm" GA_PROFILE_RUN_DIR="$B/run" \
  GA_FB_T0_ENTRY="$ETC/$ENTRY" GA_FB_T1="$ETC/fluent-bit.conf" GA_TG_CONF="$TG_CONF" GA_FLUENT_BIT=/nonexistent \
    sh "$APPLY" "$@" > "$B/out" 2>&1
}
boot_units() {  # the shippers come up as systemd starts them: each runs what its drop-in names
  for _u in "$@"; do SYSTEMCTL_LOG=/dev/null "$B/bin/systemctl" _spawn "$_u"; done
}
runs() { tr '\000' ' ' < "$B/proc/$(cat "$B/proc/units/$1")/cmdline"; }
req() { printf '{"schema":1,"profile":"%s","source":"auto","active_path":"%s","consent_tier1":true,"reason":"t","since":"2026-10-10T00:00:00Z"}\n' "$1" "$2" > "$B/gm/ga-telemetry-profile.json"; }
dropins() { find "$B/dropins" -name 50-ga-profile.conf | sed "s|$B/dropins/||; s|.d/50-ga-profile.conf||" | LC_ALL=C sort | tr '\n' ' '; }
rb() { jq -r "$1" "$B/gm/ga-telemetry-profile.applied.json" 2>/dev/null; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 — $(tr '\n' ' ' < "$B/out" | cut -c1-200)"; fi; }
ALL="fluent-bit-tier0.service fluent-bit.service telegraf.service"
boot_units fluent-bit-tier0.service fluent-bit.service telegraf.service

apply "$ALL"
chk "no request: no drop-in, read-back normal/valid" '[ -z "$(dropins)" ] && [ "$(rb .applied)" = normal ] && [ "$(rb .valid)" = true ] && grep -q "^<5>.*no request" "$B/out"'
req lte_saver lte; apply "fluent-bit-tier0.service fluent-bit.service"
chk "lan->lte: three drop-ins, one daemon-reload" '[ "$(dropins)" = "fluent-bit-tier0.service fluent-bit.service telegraf.service " ] && [ "$(grep -c daemon-reload "$B/sysctl")" = 1 ]'
chk "lte: running shippers restarted, telegraf (no consent) NOT started" '[ "$(rb ".units[\"fluent-bit-tier0.service\"]")" = restarted ] && [ "$(rb ".units[\"telegraf.service\"]")" = not-running ] && ! grep -q "start telegraf" "$B/sysctl"'
chk "lte: read-back applied=lte_saver" '[ "$(rb .applied)" = lte_saver ] && [ "$(rb .requested)" = lte_saver ]'
chk "lte: tier-0 drop-in points at the rendered config" 'grep -q "^ExecStart=$" "$B/dropins/fluent-bit-tier0.service.d/50-ga-profile.conf" && grep -q "/lte-saver/tier0.conf" "$B/dropins/fluent-bit-tier0.service.d/50-ga-profile.conf"'
chk "lte: debug overrides keep precedence over the profile" 'grep -q "/mnt/data/fluent-bit/override.conf" "$B/dropins/fluent-bit.service.d/50-ga-profile.conf" && grep -q "/mnt/data/telegraf/override.conf" "$B/dropins/telegraf.service.d/50-ga-profile.conf"'
apply "$ALL"
chk "lte again: idempotent, no reload, no restart" '! grep -q "daemon-reload\|try-restart" "$B/sysctl" && [ "$(rb ".units[\"fluent-bit-tier0.service\"]")" = unchanged ]'
req normal lan; apply "$ALL"
chk "lte->lan: drop-ins removed, shippers restarted" '[ -z "$(dropins)" ] && [ "$(grep -c try-restart "$B/sysctl")" = 3 ] && [ "$(rb .applied)" = normal ]'
req minimal lan; apply "$ALL"
chk "minimal: base units (nothing to change from normal)" '[ -z "$(dropins)" ] && ! grep -q daemon-reload "$B/sysctl" && [ "$(rb .applied)" = minimal ]'
echo '{"schema":1,"profile":"turbo"}' > "$B/gm/ga-telemetry-profile.json"; apply "$ALL"
chk "unknown profile: normal, valid=false, logged at err" '[ "$(rb .applied)" = normal ] && [ "$(rb .valid)" = false ] && grep -q "^<3>" "$B/out"'
echo 'not json' > "$B/gm/ga-telemetry-profile.json"; apply "$ALL"
chk "unparseable: normal, valid=false" '[ "$(rb .valid)" = false ] && [ -z "$(dropins)" ]'
echo '{"schema":2,"profile":"lte_saver"}' > "$B/gm/ga-telemetry-profile.json"; apply "$ALL"
chk "schema 2: refused" '[ "$(rb .valid)" = false ] && [ -z "$(dropins)" ]'
rm -f "$B/gm/ga-telemetry-profile.json"; req lte_saver lte; mv "$B/gm/ga-telemetry-profile.json" "$B/real.json"; ln -s "$B/real.json" "$B/gm/ga-telemetry-profile.json"; apply "$ALL"
chk "symlinked request: refused, base units" '[ "$(rb .valid)" = false ] && [ -z "$(dropins)" ]'
rm -f "$B/gm/ga-telemetry-profile.json"

# 2026-10-12, canary: the runtime switch deadlocked; a re-run then found the drop-ins
# on disk and read back lte_saver while the old processes ran on.
req normal lan; apply "$ALL"
req lte_saver lte; apply "$ALL" --boot
chk "--boot: restarts only ever --no-block (ordered Before= the shippers)" '[ "$(grep -c try-restart "$B/sysctl")" = 3 ] && [ "$(grep -c -- "--no-block try-restart" "$B/sysctl")" = 3 ]'
chk "--boot: the processes still run the base config (restart only queued)" 'runs fluent-bit-tier0.service | grep -q /etc/base/'
FROZEN=1 apply "$ALL"   # the interrupted run: drop-ins on disk, the restarts did not take
chk "a restart that did not take is reported stale, never restarted" '[ "$(rb ".units[\"fluent-bit-tier0.service\"]")" = stale ] && [ "$(rb .applied)" = normal ]'
apply "$ALL"
chk "drop-ins already on disk, process stale -> restarted, not unchanged" '[ "$(rb ".units[\"fluent-bit-tier0.service\"]")" = restarted ] && [ "$(rb ".units[\"telegraf.service\"]")" = restarted ]'
chk "...and every shipper now RUNS the lte-saver config" 'runs fluent-bit-tier0.service | grep -q /lte-saver/tier0.conf && runs fluent-bit.service | grep -q /lte-saver/tier1.conf && runs telegraf.service | grep -q /lte-saver/telegraf.conf'
chk "...read-back applied=lte_saver" '[ "$(rb .applied)" = lte_saver ]'
req normal lan; FROZEN=1 apply "$ALL"
chk "a restart that does not take: stale + err, applied names what RUNS" '[ "$(rb ".units[\"fluent-bit-tier0.service\"]")" = stale ] && grep -q "^<3>.*does not run" "$B/out" && [ "$(rb .applied)" = lte_saver ]'
apply "$ALL"
chk "the next run heals it: restarted, applied=normal" '[ "$(rb .applied)" = normal ] && runs fluent-bit-tier0.service | grep -q /etc/base/'

# --- units: the .path must start a unit NOT ordered before a shipper, and a unit
# that IS ordered before one must run the script with --boot.
U="$ROOT/buildroot-external/rootfs-overlay/etc/systemd/system"
PU="$(sed -n 's/^Unit=//p' "$U/ga-telemetry-profile.path")"
[ -f "$U/$PU" ] || die2 "the .path names $PU, which does not exist"
if grep -qE '^Before=.*(fluent-bit|telegraf)' "$U/$PU"; then
  bad "the .path starts $PU, which is ordered Before= a shipper (deadlock on a runtime switch)"
else ok "the .path starts $PU, not ordered before the shippers"; fi
n=0
for f in "$U"/*.service; do
  grep -q 'ga-telemetry-profile-apply' "$f" || continue; n=$((n + 1))
  if grep -qE '^Before=.*(fluent-bit|telegraf)' "$f" && ! grep -qE '^ExecStart=.*ga-telemetry-profile-apply --boot$' "$f"; then
    bad "$(basename "$f") is ordered Before= a shipper but does not run --boot"
  fi
done
if [ "$n" -ge 2 ]; then ok "units ordered before a shipper run --boot ($n units run the script)"; else bad "expected >= 2 units running the script, found $n"; fi

# --- PART C: telegraf -------------------------------------------------------------
echo "part C — the rendered telegraf config in telegraf $TG_VERSION:"
# Only the buffer directory moves (/mnt/data does not exist in the container),
# exactly as scripts/telegraf-plugin-guard.sh does for the shipped configs.
mkdir -p "$W/tg"; chmod 777 "$W/tg"
sed -E 's|^([[:space:]]*buffer_directory[[:space:]]*=).*|\1 "/tg/buffer"|' "$REN/telegraf.conf" > "$W/tg/telegraf.conf"
grep -q '"/tg/buffer"' "$W/tg/telegraf.conf" || die2 "telegraf: buffer_directory not found to relocate"
if docker run --rm -v "$W/tg:/tg" -e GA_ENV=ci -e DEVICE_UUID=x -e DEVICE_LABEL=x -e GA_BUILD_TIMESTAMP=x \
     -e INFLUX_USER=x -e INFLUX_PASSWORD=x "$TG_IMAGE" telegraf --config /tg/telegraf.conf --test > "$W/tg.out" 2> "$W/tg.err"; then
  # --test prints "> <measurement>,<tags> <fields> <ts>"; disk on /mnt/data has
  # no such mount in the container, so mem and temp are what can appear.
  got="$(sed -n 's/^> //p' "$W/tg.out" | awk '{split($1,a,","); print a[1]}' | LC_ALL=C sort -u | tr '\n' ' ')"
  case "$got" in
    *cpu*|*net*|*docker*|*system*) bad "telegraf gathered more than the essentials: $got" ;;
    *mem*) ok "telegraf loads it and gathers only: $got" ;;
    *) bad "telegraf gathered no mem metrics: '$got'" ;;
  esac
else
  tail -5 "$W/tg.err"; bad "telegraf $TG_VERSION refuses the rendered config"
fi

echo
[ "$rc" = 0 ] && echo "PASS: $pass checks — errors flow in every profile, lte_saver drops only the routine, the apply logic follows the contract"
exit "$rc"
