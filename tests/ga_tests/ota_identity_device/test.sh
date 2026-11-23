#!/bin/sh
# ota_identity_device - ga-rauc-install sends the device identity (OTA hardening,
# stage 1, Odoo #2160, OS #1094) - DRY RUN of the identity part on the device.
#
# The REAL /usr/sbin/ga-rauc-install runs on the device with a version nobody
# published, against the REAL pinned OTA endpoint, with these seams replaced:
#   rauc   -> a stub that refuses `info` and records any `install` (so NO install can
#             happen: the script dies at "rauc info refuses the bundle", exit 4)
#   curl   -> a shim that RECORDS its arguments and the identity config file (mode,
#             headers), starts the REAL curl, and while that curl is alive scans EVERY
#             /proc/<pid>/cmdline for the token, then waits for it
# The identity is a SYNTHETIC fixture (GA_GM_DATA_DIR = a temp dir holding a made-up
# ga-fleet-credentials.yaml): no real device secret is read, printed or sent. The
# download URL is pointed at the store's probe object, so the HTTP leg is real and tiny.
#
#   OTAID-00  prerequisites: installed script, pinned OTA endpoint, tools
#   OTAID-01  with an identity: curl is called with --config <file> (not -H on the line)
#   OTAID-02  ...the config is mode 0600 and carries the Bearer + X-GA-Device-Id headers
#   OTAID-03  ...the token is on NO process command line while the download runs
#   OTAID-03c control: the same scan DOES find a token placed on a command line (the
#             detector can go red)
#   OTAID-04  ...the token is not in the script's output
#   OTAID-05  ...the config is removed after the run
#   OTAID-06  no credentials: WARNING says anonymous, curl has no --config, the download
#             still completes (the store is open in stage 1)
#   OTAID-07  in both runs `rauc install` was never called
# Both boards (the script is shared). The real endpoint sees one tiny GET of its probe
# object per run, with a made-up device id.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OTA device identity, stage 1 (Odoo #2160) - dry run"

INSTALLER="${GA_OTAID_INSTALLER:-/usr/sbin/ga-rauc-install}"
# pinned here (ota_fetch OTAF-02 pins the same value): the store's probe object
PROBE_PATH="/ga-ota-health"
PIN_FILE="${GA_OTA_ACTIVE_FILE:-/run/ga-resolve-ota.active}"
RESOLVER="${GA_RESOLVE_OTA_BIN:-/usr/sbin/ga-resolve-ota}"
IDENT_GLOB="${GA_OTA_IDENT_DIR:-/run}/ga-rauc-install-ident.*"
FAKE_ID="ga-otaid-dryrun"

REALCURL="$(command -v curl 2>/dev/null)"
run_test "OTAID-00" "installer, curl, stat and the OTA pin are present" \
  "test -x '$INSTALLER' && test -n '$REALCURL' && command -v stat >/dev/null && { test -s '$PIN_FILE' || '$RESOLVER' >/dev/null 2>&1; test -s '$PIN_FILE'; }"

T=$(mktemp -d /mnt/data/tmp/ga-otaid.XXXXXX 2>/dev/null || mktemp -d /tmp/ga-otaid.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin" "$T/gm" "$T/gm-empty" "$T/stage"

# synthetic token: random, 32 hex chars, matches the script's [A-Za-z0-9_-]{16,128}
TOK="otaid$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s\n' "$TOK" > "$T/pat"          # grep -f pattern file: the token never sits on a grep command line
printf 'device_id: %s\nfleet:\n  token: %s\n' "$FAKE_ID" "$TOK" > "$T/gm/ga-fleet-credentials.yaml"
chmod 0600 "$T/gm/ga-fleet-credentials.yaml"

cat > "$T/bin/rauc" <<STUB
#!/bin/sh
echo "rauc \$*" >> "$T/rauc.log"
exit 1
STUB

# The curl shim (quoted heredoc: no expansion here, everything comes from the environment).
# Per call: the argument line, the identity file's facts, the /proc scan while the REAL curl
# is alive. OTAID_URL replaces the bundle URL (probe object).
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >> "$OTAID_T/$OTAID_RUN.args"
n=$#; prev=""; out=""; side=""
while [ "$n" -gt 0 ]; do
  a="$1"; shift; n=$((n - 1))
  [ "$prev" = "--output" ] && out="$a"
  # the .sha256 sidecar (Odoo #2136): answered below with the hash of the probe object
  # under the bundle's name, so the installer verifies and reaches `rauc info`
  case "$a" in https://ota.*.sha256) side="${a%.sha256}"; side="${side##*/}" ;; esac
  if [ "$prev" = "--config" ]; then
    echo "mode=$(stat -c %a "$a" 2>/dev/null)" >> "$OTAID_T/$OTAID_RUN.conf"
    sed 's/Bearer .*/Bearer <redacted>/' "$a" >> "$OTAID_T/$OTAID_RUN.conf" 2>/dev/null
    echo "token_in_config=$(grep -c -F -f "$OTAID_T/pat" "$a" 2>/dev/null)" >> "$OTAID_T/$OTAID_RUN.conf"
  fi
  prev="$a"
  case "$a" in https://ota.*) a="$OTAID_URL" ;; esac
  set -- "$@" "$a"
done
"$OTAID_REALCURL" "$@" &
pid=$!
polls=0; hits=0
while kill -0 "$pid" 2>/dev/null; do
  polls=$((polls + 1))
  h=$(grep -a -l -f "$OTAID_T/pat" /proc/[0-9]*/cmdline 2>/dev/null | wc -l)
  hits=$((hits + h))
done
echo "polls=$polls hits=$hits" >> "$OTAID_T/$OTAID_RUN.scan"
wait "$pid"; rc=$?
if [ "$rc" = 0 ] && [ -n "$side" ] && [ -n "$out" ]; then
  printf '%s  %s\n' "$(sha256sum "$out" | cut -d' ' -f1)" "$side" > "$out.t" && mv -f "$out.t" "$out"
fi
exit "$rc"
STUB
chmod +x "$T/bin/rauc" "$T/bin/curl"

dry_run() {   # dry_run <name> <gm-data-dir>  -> $T/<name>.out, $T/<name>.rc
  OTAID_T="$T" OTAID_REALCURL="$REALCURL" OTAID_RUN="$1" OTAID_URL="https://ota.greenautarky.com${PROBE_PATH}" \
  PATH="$T/bin:$PATH" GA_GM_DATA_DIR="$2" GA_STAGING_DIR="$T/stage" \
  GA_OTA_STATE_DIR="$T/state-$1" GA_OTA_PHASE_FILE="$T/phase-$1" GA_OTA_MAX_ATTEMPTS=1 \
    "$INSTALLER" 0.0.0.0 > "$T/$1.out" 2>&1
  echo $? > "$T/$1.rc"
}

dry_run ident "$T/gm"
dry_run anon  "$T/gm-empty"

# OTAID-01
if grep -q -e '^curl .*--config ' "$T/ident.args" 2>/dev/null; then _rc=0; else _rc=1; fi
show_verdict "OTAID-01" "with an identity curl is called with --config <file>" "$_rc" "calls: $(wc -l < "$T/ident.args" 2>/dev/null) (rc of the dry run: $(cat "$T/ident.rc"))"
# the Bearer value must not be on the curl line either
if grep -q -F -f "$T/pat" "$T/ident.args" 2>/dev/null; then _rc=1; else _rc=0; fi
show_verdict "OTAID-01b" "...and the token is not among curl's arguments" "$_rc" ""

# OTAID-02
MODE=$(sed -n 's/^mode=//p' "$T/ident.conf" 2>/dev/null | head -1)
if [ "$MODE" = 600 ] && grep -q '^token_in_config=1$' "$T/ident.conf" && grep -q '^header = "Authorization: Bearer ' "$T/ident.conf" && grep -q "^header = \"X-GA-Device-Id: $FAKE_ID\"" "$T/ident.conf"; then _rc=0; else _rc=1; fi
show_verdict "OTAID-02" "the identity config is mode 0600 with the Bearer and X-GA-Device-Id headers" "$_rc" "mode='${MODE:-none}'"

# OTAID-03: coverage first (rule 9) - a scan that never ran proves nothing
POLLS=$(sed -n 's/^polls=\([0-9]*\) hits=.*/\1/p' "$T/ident.scan" 2>/dev/null | head -1)
HITS=$(sed -n 's/^polls=[0-9]* hits=\([0-9]*\)/\1/p' "$T/ident.scan" 2>/dev/null | head -1)
if [ -n "$POLLS" ] && [ "$POLLS" -ge 1 ] && [ "$HITS" = 0 ]; then _rc=0; else _rc=1; fi
show_verdict "OTAID-03" "the token is on no /proc/*/cmdline while the download runs" "$_rc" "scans during the download: ${POLLS:-0}, hits: ${HITS:-n/a}"

# OTAID-03c: control - the same scan finds a token placed on a command line
sh -c 'sleep 5; :' "$TOK" &   # the token is $0 of this sh, i.e. on its command line
CPID=$!
sleep 1
CH=$(grep -a -l -f "$T/pat" /proc/[0-9]*/cmdline 2>/dev/null | wc -l)
kill "$CPID" 2>/dev/null
if [ "$CH" -ge 1 ]; then _rc=0; else _rc=1; fi
show_verdict "OTAID-03c" "control: the scan finds a token on a command line (it can go red)" "$_rc" "hits: $CH"

# OTAID-04
if grep -q -F -f "$T/pat" "$T/ident.out"; then _rc=1; else _rc=0; fi
show_verdict "OTAID-04" "the token is not in the installer's output" "$_rc" "$(grep -c 'sending device identity' "$T/ident.out") 'sending device identity' line(s)"

# OTAID-05
LEFT=$(ls $IDENT_GLOB 2>/dev/null | wc -l)
if [ "$LEFT" = 0 ]; then _rc=0; else _rc=1; fi
show_verdict "OTAID-05" "the identity config is removed after the run" "$_rc" "$LEFT file(s) matching $IDENT_GLOB"

# OTAID-06: anonymous path
ANON_WARN=$(grep -c 'WARNING: no device identity' "$T/anon.out")
ANON_CFG=$(grep -c -e '--config' "$T/anon.args" 2>/dev/null)
ANON_DL=$(grep -c '^\[ga-rauc-install\] downloaded ' "$T/anon.out")
if [ "$ANON_WARN" = 1 ] && [ "${ANON_CFG:-0}" = 0 ] && [ "$ANON_DL" = 1 ] && [ "$(cat "$T/anon.rc")" = 4 ]; then _rc=0; else _rc=1; fi
show_verdict "OTAID-06" "no creds: WARNING (anonymous), no --config, the download still completes" "$_rc" "warn=$ANON_WARN config_args=${ANON_CFG:-0} downloaded=$ANON_DL rc=$(cat "$T/anon.rc") (4 = rauc stub refused the fake bundle)"

# OTAID-07
RI=$(grep -c '^rauc install' "$T/rauc.log" 2>/dev/null)
if [ "${RI:-0}" = 0 ]; then _rc=0; else _rc=1; fi
show_verdict "OTAID-07" "rauc install was never called (dry run)" "$_rc" "rauc calls: $(tr '\n' '|' < "$T/rauc.log" 2>/dev/null)"

suite_end
