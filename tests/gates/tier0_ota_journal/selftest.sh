#!/usr/bin/env bash
# tier0_ota_journal/selftest.sh — tier-0 ships the OS update host path, and
# nothing else new.
#
# WHY
#   2026-10-08: an OTA to a canary was accepted by ga_manager, which wrote the
#   host request file and reported success; RAUC never installed anything. The
#   tier-0 stream (the only one on a device without telemetry consent) carried
#   ga_manager's lines and nothing from ga-rauc-install.path/.service, so "the
#   host did nothing" and "the host logged nothing" looked the same.
#
# WHAT RUNS — the subject, not a model of it
#   The REAL fluent-bit (the version buildroot builds) over a REAL journal file,
#   with the LIVE configs:
#     - the config fluent-bit-tier0.service loads, read from its ExecStart -c
#     - everything that config @INCLUDEs: fluent-bit-tier0.conf from the
#       ga-telemetry-config component at the version.yaml pin (fetched from the
#       public repo at that tag; TIER0_OVERLAY_CONF=<file> overrides offline)
#   Only what cannot run off-device is rewritten: each systemd INPUT gets
#   `Path <fixture journal>`, DB/storage paths move to a scratch dir, and the
#   Loki OUTPUT becomes stdout. The rewrite is counted and fails closed if it
#   touched fewer inputs than exist.
#
#   The fixture journal (systemd export format -> systemd-journal-remote):
#     must-ship, each EXACTLY once (once: a second match would double-ship):
#       S1-S3,S6  _SYSTEMD_UNIT=ga-rauc-install.service at PRIORITY 6/3/7
#       S4        PID 1 lifecycle line UNIT=ga-rauc-install.service (INFO)
#       S5        PID 1 line UNIT=ga-rauc-install.path (INFO)
#       S7        PID 1 lifecycle line UNIT=rauc.service (INFO)
#       S8        rauc.service's own output incl. ga-release-floor (INFO)
#     must-drop:
#       D1 an unrelated unit at INFO, D2/D3 ga-resolve-ota (excluded on purpose),
#       D4 a near-name OTA unit (ga-rauc-slots) at INFO,
#       D5 a tier-1-only unit (network.service) at WARNING.
#
# RED PROOF (part of this test)
#   Two mutants run over the same journal and MUST fail on the named cases:
#     master    the pre-change shape: the unit loads fluent-bit-tier0.conf alone
#               -> S1-S7 missing (S8 still ships; D* still dropped)
#     no-UNIT   the OS input without its UNIT= matches
#               -> exactly S4, S5, S7 missing (the PID 1 lines)
#
# Exit 0 = live config green AND both mutants red on exactly their cases.
# Exit 1 = a verdict failed. Exit 2 = could not check (never green).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UNIT="$ROOT/buildroot-ihost/rootfs-overlay/etc/systemd/system/fluent-bit-tier0.service"
OVERLAY_ETC="$ROOT/buildroot-ihost/rootfs-overlay/etc/fluent-bit"
PARSERS="$ROOT/buildroot-external/package/fluent-bit-config/parsers.conf"
VERSION_YAML="$ROOT/version.yaml"
FB_MK="$ROOT/buildroot/package/fluent-bit/fluent-bit.mk"

# The fluent-bit the image builds (buildroot FLUENT_BIT_VERSION). Compared below
# against buildroot's .mk whenever the submodule is checked out.
FB_VERSION="3.2.10"
FB_IMAGE="${FLUENT_BIT_IMAGE:-fluent/fluent-bit@sha256:d6dec000c4929a439562525728c708f6e99800d7ddc82efd6aa4f45f3a20b562}"

die2() { echo "ERROR (could not check): $*" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/tier0-ota.XXXXXX")"
trap 'rm -rf "$W"' EXIT

for f in "$UNIT" "$PARSERS" "$VERSION_YAML"; do
  [ -f "$f" ] || die2 "$f not found"
done
command -v docker >/dev/null || die2 "docker not on PATH"

if [ -f "$FB_MK" ]; then
  mk_ver="$(sed -n 's/^FLUENT_BIT_VERSION = //p' "$FB_MK")"
  [ "$mk_ver" = "$FB_VERSION" ] \
    || die2 "buildroot builds fluent-bit $mk_ver, this gate runs $FB_VERSION — update FB_VERSION/FB_IMAGE"
fi

JR="${JOURNAL_REMOTE:-}"
if [ -z "$JR" ]; then
  for c in /usr/lib/systemd/systemd-journal-remote /lib/systemd/systemd-journal-remote; do
    [ -x "$c" ] && { JR="$c"; break; }
  done
fi
[ -n "$JR" ] || die2 "systemd-journal-remote not found (apt: systemd-journal-remote; or set JOURNAL_REMOTE)"

# --- the config the unit loads ---------------------------------------------
ENTRY="$(grep -E '^ExecStart=' "$UNIT" | grep -oE -- '-c[[:space:]]+/etc/fluent-bit/[A-Za-z0-9._-]+' | awk '{print $2}')"
[ "$(printf '%s\n' "$ENTRY" | grep -c .)" = 1 ] || die2 "expected exactly one -c in $UNIT ExecStart, got: '${ENTRY}'"
ENTRY_NAME="${ENTRY##*/}"
echo "unit loads: $ENTRY_NAME"

# --- the component config, at the pin --------------------------------------
TC_VER="$(sed -n 's/^[[:space:]]*ga-telemetry-config:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_YAML")"
[ -n "$TC_VER" ] || die2 "no ga-telemetry-config pin in version.yaml"
mkdir -p "$W/etc"
if [ -n "${TIER0_OVERLAY_CONF:-}" ]; then
  cp "$TIER0_OVERLAY_CONF" "$W/etc/fluent-bit-tier0.conf" || die2 "cannot read $TIER0_OVERLAY_CONF"
  echo "component config: $TIER0_OVERLAY_CONF (override; pin is $TC_VER)"
else
  url="https://raw.githubusercontent.com/greenautarky/ga-telemetry-config/v${TC_VER}/src/ga-telemetry-config/etc/fluent-bit/fluent-bit-tier0.conf"
  curl -fsS --retry 3 --max-time 30 -o "$W/etc/fluent-bit-tier0.conf" "$url" || die2 "cannot fetch $url"
  echo "component config: ga-telemetry-config v$TC_VER"
fi
grep -q '^\[OUTPUT\]' "$W/etc/fluent-bit-tier0.conf" || die2 "component config has no [OUTPUT] — not the tier-0 config?"
cp "$PARSERS" "$W/etc/parsers.conf"
# The stdout OUTPUT that replaces Loki off-device takes the Loki OUTPUT's own
# Match, so "reaches the output" here means "reaches Loki" on the device.
LOKI_MATCH="$(awk '/^\[/{o=($0 ~ /\[OUTPUT\]/); l=0; m=""} o&&$1=="Name"&&$2=="loki"{l=1} o&&$1=="Match"{m=$2} l&&m!=""{print m; exit}' "$W/etc/fluent-bit-tier0.conf")"
[ -n "$LOKI_MATCH" ] || die2 "no Match on the loki OUTPUT of the component config"
echo "loki OUTPUT matches: $LOKI_MATCH"

# --- fixture journal --------------------------------------------------------
# rec ID FIELD=VALUE... — one export-format entry; MESSAGE carries the id.
BOOT=0f4c2a1e9b7d4c3a8e6f5d4c3b2a1908
T0=1791446400000000
n=0
rec() {
  local id="$1"; shift
  n=$((n + 1))
  {
    echo "__REALTIME_TIMESTAMP=$((T0 + n * 1000000))"
    echo "__MONOTONIC_TIMESTAMP=$((n * 1000000))"
    echo "_BOOT_ID=$BOOT"
    echo "_HOSTNAME=fixture"
    printf '%s\n' "$@"
    echo "MESSAGE=FIXTURE-$id"
    echo
  } >> "$W/fixture.export"
}
: > "$W/fixture.export"
rec S1 _SYSTEMD_UNIT=ga-rauc-install.service PRIORITY=6 SYSLOG_IDENTIFIER=ga-rauc-install _PID=4100
rec S2 _SYSTEMD_UNIT=ga-rauc-install.service PRIORITY=3 SYSLOG_IDENTIFIER=ga-rauc-install _PID=4100
rec S3 _SYSTEMD_UNIT=ga-rauc-install.service PRIORITY=6 SYSLOG_IDENTIFIER=rauc _PID=4180
rec S4 _SYSTEMD_UNIT=init.scope UNIT=ga-rauc-install.service PRIORITY=6 SYSLOG_IDENTIFIER=systemd _PID=1
rec S5 _SYSTEMD_UNIT=init.scope UNIT=ga-rauc-install.path PRIORITY=6 SYSLOG_IDENTIFIER=systemd _PID=1
rec S6 _SYSTEMD_UNIT=ga-rauc-install.service PRIORITY=7 SYSLOG_IDENTIFIER=ga-rauc-install _PID=4100
rec S7 _SYSTEMD_UNIT=init.scope UNIT=rauc.service PRIORITY=6 SYSLOG_IDENTIFIER=systemd _PID=1
rec S8 _SYSTEMD_UNIT=rauc.service PRIORITY=6 SYSLOG_IDENTIFIER=rauc _PID=700
rec D1 _SYSTEMD_UNIT=systemd-timesyncd.service PRIORITY=6 SYSLOG_IDENTIFIER=systemd-timesyncd _PID=300
rec D2 _SYSTEMD_UNIT=ga-resolve-ota.service PRIORITY=6 SYSLOG_IDENTIFIER=ga-resolve-ota _PID=5000
rec D3 _SYSTEMD_UNIT=init.scope UNIT=ga-resolve-ota.service PRIORITY=6 SYSLOG_IDENTIFIER=systemd _PID=1
rec D4 _SYSTEMD_UNIT=ga-rauc-slots.service PRIORITY=6 SYSLOG_IDENTIFIER=ga-rauc-slots _PID=5100
rec D5 _SYSTEMD_UNIT=network.service PRIORITY=4 SYSLOG_IDENTIFIER=network _PID=200
SHIP="S1 S2 S3 S4 S5 S6 S7 S8"
DROP="D1 D2 D3 D4 D5"

mkdir -p "$W/journal"
"$JR" --output="$W/journal/fixture.journal" "$W/fixture.export" >"$W/jr.log" 2>&1 \
  || { cat "$W/jr.log" >&2; die2 "systemd-journal-remote failed"; }
[ -s "$W/journal/fixture.journal" ] || die2 "no journal file written"

# --- rewrite a config set for an off-device run -----------------------------
# offline_conf SRC DST — Path on every systemd INPUT, scratch DB/storage, Loki
# OUTPUT dropped, Flush 1. Prints the number of systemd INPUTs rewritten.
offline_conf() {
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
      if ($1 == "Name" && $2 == "loki") isloki = 1
      if (inp && $1 == "Name" && $2 == "systemd") insys = 1
      if ($1 == "DB")           { sub(/\/mnt\/data\/fluent-bit\/db/, "/w/db") }
      if (tolower($1) == "storage.path") { $0 = "    storage.path /w/storage" }
      if ($1 == "Flush")        { $0 = "    Flush 1" }
      if ($1 == "Read_From_Tail") next
      blk = blk $0 "\n"; next
    }
    { print }
    END { flush_block(); print nsys + 0 > "/dev/stderr" }
  ' "$1" > "$2" 2> "$2.nsys"
}

# run_case NAME ENTRY_FILE_IN_W_ETC — runs fluent-bit, writes $W/out.NAME
run_case() {
  local name="$1" entry="$2"
  local d="$W/run.$name"
  mkdir -p "$d/etc" "$d/db" "$d/storage"
  local total=0 f
  for f in "$W"/etc/*.conf; do
    offline_conf "$f" "$d/etc/${f##*/}"
    total=$((total + $(cat "$d/etc/${f##*/}.nsys")))
  done
  # the systemd INPUTs the live files declare must ALL have been rewritten
  local declared
  declared="$(cat "$W"/etc/*.conf | awk '/^\[INPUT\]/{i=1;next} /^\[/{i=0} i&&$1=="Name"&&$2=="systemd"{c++} END{print c+0}')"
  [ "$total" -ge 1 ] && [ "$total" = "$declared" ] \
    || die2 "$name: rewrote $total of $declared systemd inputs"
  printf '\n[OUTPUT]\n    Name    stdout\n    Match   %s\n    Format  json_lines\n' \
    "$LOKI_MATCH" >> "$d/etc/$entry"
  cp -r "$W/journal" "$d/journal"
  local cid
  cid="$(docker run -d --user "$(id -u):$(id -g)" -v "$d:/w" \
           -e GA_ENV=ci -e DEVICE_LABEL=FIXTURE -e DEVICE_UUID=00000000-0000-0000-0000-000000000000 \
           -e LOKI_HOST=x -e LOKI_PORT=1 -e LOKI_USER=x -e LOKI_PASSWORD=x -e LOKI_TENANT=x \
           "$FB_IMAGE" /fluent-bit/bin/fluent-bit -c "/w/etc/$entry")" \
    || die2 "$name: docker run failed"
  # a few flush cycles, then a graceful stop (SIGTERM flushes what is buffered)
  sleep 6
  docker stop -t 10 "$cid" >/dev/null 2>&1
  docker logs "$cid" > "$W/out.$name" 2> "$W/err.$name"
  docker rm "$cid" >/dev/null 2>&1
  grep -q '"MESSAGE":"FIXTURE-' "$W/out.$name" \
    || { cat "$W/err.$name" >&2; die2 "$name: fluent-bit shipped no fixture line at all (did it start?)"; }
}

# verdict NAME — prints per-case lines; sets FAILED to the failing case ids
verdict() {
  local name="$1" id c
  FAILED=""
  for id in $SHIP; do
    c="$(grep -c "\"MESSAGE\":\"FIXTURE-$id\"" "$W/out.$name")"
    if [ "$c" != 1 ]; then
      echo "  FAIL  $id shipped $c times (want 1)"; FAILED="$FAILED $id"
    elif ! grep "\"MESSAGE\":\"FIXTURE-$id\"" "$W/out.$name" | grep -q '"tier":"0"'; then
      # the included stamp FILTER must reach it: same tier/identity as tier-0
      echo "  FAIL  $id shipped without the tier-0 stamp"; FAILED="$FAILED $id"
    else
      echo "  ok    $id shipped once, tier-0 stamped"
    fi
  done
  for id in $DROP; do
    c="$(grep -c "\"MESSAGE\":\"FIXTURE-$id\"" "$W/out.$name")"
    if [ "$c" = 0 ]; then echo "  ok    $id dropped"
    else echo "  FAIL  $id shipped $c times (want 0)"; FAILED="$FAILED $id"; fi
  done
  FAILED="${FAILED# }"
}

rc=0

# --- live -------------------------------------------------------------------
cp "$OVERLAY_ETC/$ENTRY_NAME" "$W/etc/$ENTRY_NAME" 2>/dev/null \
  || [ -f "$W/etc/$ENTRY_NAME" ] || die2 "$ENTRY_NAME not found in $OVERLAY_ETC"
for inc in $(sed -n 's/^@INCLUDE[[:space:]]\{1,\}//p' "$W/etc/$ENTRY_NAME"); do
  [ -f "$W/etc/$inc" ] || die2 "$ENTRY_NAME includes $inc, which is not available here"
done
run_case live "$ENTRY_NAME"
echo "live ($ENTRY_NAME):"
verdict live
[ -z "$FAILED" ] || { echo "RED: live config fails:$FAILED"; rc=1; }

# --- mutants ----------------------------------------------------------------
# mutant WANT NAME ENTRY — must fail on exactly WANT
mutant() {
  local want="$1" name="$2" entry="$3"
  run_case "$name" "$entry"
  echo "mutant $name:"
  verdict "$name" > "$W/verdict.$name"
  sed 's/^/  /' "$W/verdict.$name"
  if [ "$FAILED" = "$want" ]; then
    echo "  -> red on exactly [$want], as required"
  else
    echo "  -> WRONG: mutant $name must fail on exactly [$want], failed on [${FAILED:-nothing}]"
    rc=1
  fi
}

if [ "$ENTRY_NAME" != "fluent-bit-tier0.conf" ]; then
  mutant "S1 S2 S3 S4 S5 S6 S7" master fluent-bit-tier0.conf
  grep -v '^[[:space:]]*Systemd_Filter[[:space:]]\{1,\}UNIT=' "$W/etc/$ENTRY_NAME" > "$W/etc/no-unit.conf"
  mutant "S4 S5 S7" no-unit no-unit.conf
  rm -f "$W/etc/no-unit.conf"
else
  echo "RED: the unit still loads fluent-bit-tier0.conf alone — the OS update units are not shipped"
  rc=1
fi

[ "$rc" = 0 ] && echo "PASS: tier-0 ships the OS update host path, nothing else new; both mutants red"
exit "$rc"
