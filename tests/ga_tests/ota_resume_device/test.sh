#!/bin/sh
# ota_resume_device — ga-rauc-install resumes a cut bundle download on the REAL
# device, against the REAL OTA store, with the device's own curl (Odoo #2136).
#
# DRY RUN: the installed /usr/sbin/ga-rauc-install fetches the bundle of the
# release the device already runs (its slot has a .sha256 sidecar), with these
# seams replaced:
#   rauc  -> a stub that refuses `info` and records any `install`: nothing can be
#            installed, the run ends at "rauc info refuses the bundle" (exit 4)
#   curl  -> a shim around the REAL curl that records its arguments and, on the
#            FIRST bundle transfer only, kills it after GA_ORD_CUT_MB MB - the
#            stand-in for a dropped uplink
# Everything the installer writes goes to a temp dir (staging, state, status,
# phase, identity); no device credential is read (anonymous, stage 1).
#
#   ORD-00  prerequisites: installer, release marker, OTA pin, space for a bundle
#   ORD-01  the cut happened (the shim killed the first bundle transfer)
#   ORD-02  the next attempt resumed: --continue-at + If-Range from the store's ETag
#   ORD-03  the bundle was completed and sha256-verified against the sidecar
#   ORD-04  bytes fetched for the bundle ~1.0x its size (resume, not restart)
#   ORD-05  rauc install was never called; the run ended at the rauc stub (rc 4)
#   ORD-06  the status file is schema-1 JSON that ended in phase "failed"
#   ORD-07  nothing left behind: no accepted request, no identity file
#
# Downloads one full bundle (~210-230 MB): runs only with GA_TEST_DESTRUCTIVE=1,
# on a canary with a wired uplink, never inside a soak.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OTA resumable fetch (Odoo #2136) - dry run on the device"

INSTALLER="${GA_ORD_INSTALLER:-/usr/sbin/ga-rauc-install}"
PIN_FILE="${GA_OTA_ACTIVE_FILE:-/run/ga-resolve-ota.active}"
RESOLVER="${GA_RESOLVE_OTA_BIN:-/usr/sbin/ga-resolve-ota}"
CUT_MB="${GA_ORD_CUT_MB:-20}"
# Relocations for the host-side selftest only (nothing on a device sets them).
REL_FILE="${GA_ORD_RELEASE_FILE:-/etc/ga-release}"
OSR_FILE="${GA_ORD_OS_RELEASE:-/etc/os-release}"
TMP_BASE="${GA_ORD_TMP:-/mnt/data/tmp}"
FREE_DIR="${GA_ORD_TMP:-/mnt/data}"

if ! ga_destructive "ORD-ALL" "downloads one full OS bundle and cuts it once"; then
  suite_end; exit 0
fi

REALCURL="$(command -v curl 2>/dev/null)"
REL="$(head -c 64 "$REL_FILE" 2>/dev/null | tr -d '[:space:]')"
VER="$(sed -n 's/^VERSION_ID=//p' "$OSR_FILE" 2>/dev/null | tr -d '"[:space:]')"
T=$(mktemp -d "$TMP_BASE/ga-ord.XXXXXX" 2>/dev/null)
FREE_KB=$(df -Pk "$FREE_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
run_test "ORD-00" "installer, curl, release marker ($REL), version ($VER), OTA pin, >= 600 MB free on /mnt/data" \
  "test -x '$INSTALLER' && test -n '$REALCURL' && test -n '$T' && echo '$REL' | grep -qE '^BOSv[0-9]+[.][0-9]+[.][0-9]+(-(rc|dev)[0-9]+)?\$' && test -n '$VER' && { test -s '$PIN_FILE' || '$RESOLVER' >/dev/null 2>&1; test -s '$PIN_FILE'; } && [ '${FREE_KB:-0}' -ge 614400 ]"
[ -n "$T" ] || { suite_end; exit 1; }
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/gm" "$T/stage" "$T/state" "$T/run"

cat > "$T/bin/rauc" <<STUB
#!/bin/sh
echo "rauc \$*" >> "$T/rauc.log"
exit 1
STUB
# The shim: one line per call in calls.log ("<n> <bytes before> <bytes after> <rc> <args>").
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
out=""; prev=""; bundle=0
for a in "$@"; do
  [ "$prev" = "--output" ] && out="$a"
  case "$a" in https://*.raucb) bundle=1 ;; esac
  prev="$a"
done
before=0; [ -n "$out" ] && [ -f "$out" ] && before=$(stat -c %s "$out")
cut=0; [ "$bundle" = 1 ] && [ ! -e "$ORD_T/cut.done" ] && cut=1
if [ "$cut" = 1 ]; then
  # throttled so the 1 s poll below catches the cut point (~5 s to reach it) on any link
  "$ORD_REALCURL" --limit-rate "$((ORD_CUT_MB * 1024 / 5))K" "$@" &
else
  "$ORD_REALCURL" "$@" &
fi
pid=$!
if [ "$cut" = 1 ]; then
  lim=$((ORD_CUT_MB * 1024 * 1024))
  while kill -0 "$pid" 2>/dev/null; do
    s=0; [ -f "$out" ] && s=$(stat -c %s "$out")
    if [ "$s" -ge "$lim" ]; then kill "$pid" 2>/dev/null; echo "$s" > "$ORD_T/cut.done"; break; fi
    sleep 1
  done
fi
wait "$pid"; rc=$?
after=0; [ -n "$out" ] && [ -f "$out" ] && after=$(stat -c %s "$out")
echo "$bundle $before $after $rc $*" >> "$ORD_T/calls.log"
exit "$rc"
STUB
chmod +x "$T/bin/rauc" "$T/bin/curl"

ORD_T="$T" ORD_REALCURL="$REALCURL" ORD_CUT_MB="$CUT_MB" PATH="$T/bin:$PATH" \
  GA_GM_DATA_DIR="$T/gm" GA_STAGING_DIR="$T/stage" GA_OTA_STATE_DIR="$T/state" \
  GA_OTA_PHASE_FILE="$T/phase" GA_OTA_IDENT_DIR="$T/run" GA_JOURNAL_DUMP_BIN=/nonexistent \
  GA_OTA_BACKOFF_S=2 GA_OTA_MAX_ATTEMPTS=4 \
  "$INSTALLER" "$VER" "$REL" > "$T/out" 2>&1
RC=$?

CUT=$(cat "$T/cut.done" 2>/dev/null)
show_verdict "ORD-01" "the first bundle transfer was cut after ${CUT_MB} MB" \
  "$([ -n "$CUT" ] && echo 0 || echo 1)" "cut at ${CUT:-never} bytes"

RESUMED=$(awk '$1 == 1 && $2 > 0' "$T/calls.log" | grep -c -e '--continue-at' )
IFR=$(awk '$1 == 1 && $2 > 0' "$T/calls.log" | grep -c 'If-Range: "')
show_verdict "ORD-02" "the next attempt resumed with --continue-at and If-Range" \
  "$([ "$RESUMED" -ge 1 ] && [ "$IFR" -ge 1 ] && echo 0 || echo 1)" "resumed calls: $RESUMED, with If-Range: $IFR"

SIZE=$(sed -n 's/^\[ga-rauc-install\] downloaded \([0-9]*\) bytes, sha256 verified.*/\1/p' "$T/out" | head -1)
show_verdict "ORD-03" "the bundle was completed and sha256-verified" \
  "$([ -n "$SIZE" ] && echo 0 || echo 1)" "size ${SIZE:-none}; $(grep -m1 -E 'sha256|FATAL' "$T/out")"

FETCHED=$(awk '$1 == 1 { d = $3 - $2; if (d > 0) t += d } END { print t + 0 }' "$T/calls.log")
show_verdict "ORD-04" "bytes fetched for the bundle ~1.0x its size (<= size + 1 MB)" \
  "$([ -n "$SIZE" ] && [ "$FETCHED" -le $((SIZE + 1048576)) ] && echo 0 || echo 1)" "fetched $FETCHED of ${SIZE:-?}"

RI=$(grep -c '^rauc install' "$T/rauc.log" 2>/dev/null)
show_verdict "ORD-05" "rauc install never called; the run ended at the rauc stub (rc 4)" \
  "$([ "${RI:-0}" = 0 ] && [ "$RC" = 4 ] && echo 0 || echo 1)" "rc=$RC installs=${RI:-0}"

ST=$(cat "$T/gm/ga-rauc-install.status" 2>/dev/null)
show_verdict "ORD-06" "the status file is schema 1 and ended in phase failed" \
  "$(printf '%s' "$ST" | grep -q '^{"schema":1,.*"phase":"failed".*"updated":[0-9]*}$' && echo 0 || echo 1)" "status: ${ST:-none}"

LEFT=$(find "$T/state" "$T/run" -type f 2>/dev/null | wc -l | tr -d ' ')
show_verdict "ORD-07" "no accepted request and no identity file left behind" \
  "$([ "$LEFT" = 0 ] && echo 0 || echo 1)" "$LEFT file(s)"

suite_end
