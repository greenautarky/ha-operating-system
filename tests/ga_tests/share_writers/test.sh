#!/bin/sh
# share_writers — every host writer of a status file in the shared directory
# publishes it atomically and without following a symlink found at its path.
#
# /mnt/data/supervisor/share is also mounted into add-on containers, so any
# name in it may hold something the host did not put there. The host writers
# must therefore only ever land their bytes at the literal path (staged in a
# host-only directory, renamed into place by ga-share-publish), and the
# ga-wlan0-deauth <-> ga_manager mutual exclusion must use an object that
# cannot be swapped out: the shared directory itself.
#
# How: each REAL script runs inside a bubblewrap sandbox in which a temp dir is
# mounted at /mnt/data (and /mnt/boot, /run, /tmp), and the repository's own
# /usr/libexec overlay is mounted at /usr/libexec. Only the commands that talk
# to hardware or services (nmcli, ip, nft, systemctl, dmesg, journalctl, iw,
# logger) are stubbed. Before each run a symlink is placed at the path the
# writer uses, pointing at an unrelated file under /mnt/data; afterwards that
# file must be byte-identical AND the status file must exist at its literal
# path with the writer's content (so "wrote nothing" cannot pass).
#
# With --unshare-pid the script under test is PID 2, which makes the
# `$$`-suffixed temporary names of the pre-change writers predictable, so the
# suite is deterministic in both directions.
#
# Runs every case twice when BusyBox is available: once with the host's
# coreutils, once with BusyBox applets first on PATH (the device's userland).
# Set GA_REQUIRE_BUSYBOX=1 to make a missing BusyBox a failure (CI does).
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
IHOST="$ROOT/buildroot-ihost/rootfs-overlay"
LIBEXEC="$ROOT/buildroot-external/rootfs-overlay/usr/libexec"

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }

# ── the sandbox runner ──────────────────────────────────────────────────────
BWRAP=""
if command -v bwrap >/dev/null 2>&1; then
  if bwrap --ro-bind / / --unshare-pid --proc /proc --dev /dev true 2>/dev/null; then
    BWRAP="bwrap"
  elif sudo -n bwrap --ro-bind / / --unshare-pid --proc /proc --dev /dev true 2>/dev/null; then
    BWRAP="sudo -n bwrap"
  fi
fi
if [ -z "$BWRAP" ]; then
  echo "FATAL: bubblewrap cannot create a sandbox here — this suite must not pass without running" >&2
  exit 1
fi
command -v flock >/dev/null 2>&1 || { echo "FATAL: flock (util-linux) missing — the device has it" >&2; exit 1; }

WORK="$(mktemp -d -t share-writers-XXXXXX)"
# sudo-run sandboxes may leave root-owned files behind.
trap 'rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK" 2>/dev/null' EXIT

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
for c in nft systemctl dmesg journalctl iw logger; do
  printf '#!/bin/sh\nexit 0\n' > "$STUBS/$c"
done
# nmcli: everything connected and healthy; nothing else to report.
cat > "$STUBS/nmcli" <<'EOF'
#!/bin/sh
case "$*" in
  *"CONNECTIVITY general status"*|"networking connectivity check") echo full ;;
esac
exit 0
EOF
# ip: WiFi is the default route (the watchdog only runs then); link ops no-op.
cat > "$STUBS/ip" <<'EOF'
#!/bin/sh
case "$1" in route) echo "default via gateway dev wlan0 proto dhcp metric 600 " ;; esac
exit 0
EOF
chmod +x "$STUBS"/*

BBDIR=""
if command -v busybox >/dev/null 2>&1; then
  BBDIR="$WORK/busybox"; mkdir -p "$BBDIR"
  for a in sh cat mv rm ln mkdir chmod dirname basename head tr sed awk grep date \
           printf stat ls cut sleep touch mktemp; do
    ln -s "$(command -v busybox)" "$BBDIR/$a"
  done
elif [ "${GA_REQUIRE_BUSYBOX:-0}" = 1 ]; then
  echo "FATAL: GA_REQUIRE_BUSYBOX=1 but busybox is not installed" >&2; exit 1
fi

# fresh <case>: a new /mnt/data with the share dir, an unrelated file, /run, /tmp
fresh() {
  C="$WORK/case/$1"; rm -rf "$C" 2>/dev/null || sudo -n rm -rf "$C"
  mkdir -p "$C/data/supervisor/share" "$C/boot" "$C/run" "$C/tmp" "$C/data/other-dir"
  printf 'UNRELATED-CONTENT-1\n' > "$C/data/other-file"
  SHARE="$C/data/supervisor/share"
}

# sbx <path-prefix> <cmd...>: run inside the sandbox with $C mounted. The stubs
# and the BusyBox links are mounted under /mnt because $WORK itself may live
# under the /tmp the sandbox replaces.
sbx() {
  _pfx="$1"; shift
  # Bounded: a writer that blocks must fail its checks, never wedge the job.
  timeout -k 5 60 $BWRAP --ro-bind / / --unshare-pid --proc /proc --dev /dev \
    --tmpfs /mnt --bind "$C/data" /mnt/data --bind "$C/boot" /mnt/boot \
    --bind "$C/run" /run --bind "$C/tmp" /tmp \
    --ro-bind "$LIBEXEC" /usr/libexec --ro-bind "$STUBS" /mnt/.stubs \
    ${BBDIR:+--ro-bind "$BBDIR" /mnt/.busybox} \
    --tmpfs /sys --dir /sys/bus/sdio/devices/mmc1:0001:1 --dir /sys/class/net/wlan0 \
    --setenv PATH "$_pfx/mnt/.stubs:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

unchanged() { [ "$(cat "$C/data/other-file")" = UNRELATED-CONTENT-1 ]; }
dir_empty() { [ -z "$(ls -A "$C/data/other-dir")" ]; }
published() {  # <name> <needle>: a regular file at the literal path, with content
  [ -f "$SHARE/$1" ] && [ ! -L "$SHARE/$1" ] && grep -q "$2" "$SHARE/$1"
}

check() {  # <id> <what> <name> <needle> [dir]
  _id="$1"; _what="$2"; _name="$3"; _needle="$4"
  if [ "${5:-}" = dir ]; then
    if dir_empty; then PASS "$_id $_what: nothing placed in the linked directory"
    else FAIL "$_id $_what: a file appeared in the linked directory" "$(ls -A "$C/data/other-dir" | tr '\n' ' ')"; fi
  else
    if unchanged; then PASS "$_id $_what: linked file unchanged"
    else FAIL "$_id $_what: linked file was written" "now: $(head -c 80 "$C/data/other-file" | tr '\n' ' ')"; fi
  fi
  if published "$_name" "$_needle"; then PASS "$_id $_what: status published at the literal path"
  else FAIL "$_id $_what: status NOT published at the literal path" "$(ls -l "$SHARE" | tr '\n' ';')"; fi
}

run_cases() {  # <label> <PATH prefix>
  L="$1"; P="$2"

  echo "── [$L] ga-uplink-ladder ──"
  fresh ladder; ln -s /mnt/data/other-file "$SHARE/ga-uplink.json"
  sbx "$P" sh "$IHOST/usr/sbin/ga-uplink-ladder" >/dev/null 2>&1
  check "SW-01[$L]" "ladder status (symlink at the file)" ga-uplink.json '"rung":"none"'

  echo "── [$L] ga-wifi-watchdog ──"
  fresh wd-tmp; ln -s /mnt/data/other-file "$SHARE/ga-wifi-health.json.tmp"
  sbx "$P" sh "$IHOST/usr/sbin/ga-wifi-watchdog" >/dev/null 2>&1
  check "SW-02[$L]" "watchdog health (symlink at the .tmp name)" ga-wifi-health.json '"iface": "wlan0"'
  fresh wd-dir; ln -s /mnt/data/other-dir "$SHARE/ga-wifi-health.json"
  sbx "$P" sh "$IHOST/usr/sbin/ga-wifi-watchdog" >/dev/null 2>&1
  check "SW-03[$L]" "watchdog health (symlink to a directory at the file)" ga-wifi-health.json '"iface": "wlan0"' dir

  echo "── [$L] ga-firewall-gate ──"
  fresh fw-tmp; ln -s /mnt/data/other-file "$SHARE/ga-firewall-status.json.tmp.2"
  sbx "$P" sh "$IHOST/usr/libexec/ga-firewall-gate" >/dev/null 2>&1
  check "SW-04[$L]" "firewall status (symlink at the .tmp.<pid> name)" ga-firewall-status.json '"ruleset_loaded": true'
  fresh fw-dir; ln -s /mnt/data/other-dir "$SHARE/ga-firewall-status.json"
  sbx "$P" sh "$IHOST/usr/libexec/ga-firewall-gate" >/dev/null 2>&1
  check "SW-05[$L]" "firewall status (symlink to a directory at the file)" ga-firewall-status.json '"ruleset_loaded": true' dir

  echo "── [$L] ga-bluetooth-status ──"
  fresh bt-tmp; ln -s /mnt/data/other-file "$SHARE/ga-bluetooth-status.json.tmp.2"
  sbx "$P" sh "$IHOST/usr/libexec/ga-bluetooth-status" >/dev/null 2>&1
  check "SW-06[$L]" "bluetooth status (symlink at the .tmp.<pid> name)" ga-bluetooth-status.json '"schema_version": 2'

  echo "── [$L] ga-manage-ethernet ──"
  fresh eth-tmp; ln -s /mnt/data/other-file "$SHARE/ga-ethernet-status.json.tmp.2"
  sbx "$P" sh "$IHOST/usr/sbin/ga-manage-ethernet" apply >/dev/null 2>&1
  check "SW-07[$L]" "ethernet status (symlink at the .tmp.<pid> name)" ga-ethernet-status.json '"source": "default"'

  echo "── [$L] ga-wlan0-deauth ──"
  DEAUTH="$IHOST/usr/sbin/ga-wlan0-deauth"
  PUBLISH_ONE='GA_DEAUTH_TEST=1 . "$0"; publish_counter 4 bid "" "\"3\":4" 3'
  fresh deauth-lock; ln -s /mnt/data/other-file "$SHARE/ga-wlan0-deauth.json.lock"
  sbx "$P" sh -c "$PUBLISH_ONE" "$DEAUTH" >/dev/null 2>&1
  check "SW-08[$L]" "deauth counter (symlink at the old lock name)" ga-wlan0-deauth.json '"reason3_total":4'
  fresh deauth-nolock
  sbx "$P" sh -c "$PUBLISH_ONE" "$DEAUTH" >/dev/null 2>&1
  if [ -z "$(ls -A "$SHARE" | grep -v '^ga-wlan0-deauth.json$')" ]; then
    PASS "SW-09[$L] deauth leaves nothing but its status file in the shared dir"
  else
    FAIL "SW-09[$L] deauth leaves nothing but its status file in the shared dir" "$(ls -A "$SHARE" | tr '\n' ' ')"
  fi
  # The marks read: the status path itself is a link to a file that happens to
  # contain the marks field. Nothing from that file may reach the output.
  fresh deauth-read
  printf '{"healer_marks":["FROM-OTHER-FILE"]}\n' > "$C/data/other-file"
  ln -s /mnt/data/other-file "$SHARE/ga-wlan0-deauth.json"
  sbx "$P" sh -c "$PUBLISH_ONE" "$DEAUTH" >/dev/null 2>&1
  if published ga-wlan0-deauth.json '"reason3_total":4' && ! grep -q FROM-OTHER-FILE "$SHARE/ga-wlan0-deauth.json"; then
    PASS "SW-10[$L] deauth marks are read only from a regular file at the literal path"
  else
    FAIL "SW-10[$L] deauth marks are read only from a regular file at the literal path" "$(cat "$SHARE/ga-wlan0-deauth.json" 2>/dev/null)"
  fi
  # ...while marks in a genuine status file are preserved (the two-writer seam).
  fresh deauth-keep
  printf '{"reason3_total":1,"healer_marks":["2026-09-29T10:00:00Z"]}\n' > "$SHARE/ga-wlan0-deauth.json"
  sbx "$P" sh -c "$PUBLISH_ONE" "$DEAUTH" >/dev/null 2>&1
  if grep -q '"healer_marks":\["2026-09-29T10:00:00Z"\]' "$SHARE/ga-wlan0-deauth.json" \
     && grep -q '"reason3_total":4' "$SHARE/ga-wlan0-deauth.json"; then
    PASS "SW-11[$L] deauth preserves healer_marks from a regular status file"
  else
    FAIL "SW-11[$L] deauth preserves healer_marks from a regular status file" "$(cat "$SHARE/ga-wlan0-deauth.json" 2>/dev/null)"
  fi
  # Mutual exclusion is on the shared DIRECTORY: while another holder has it,
  # the publish waits; it proceeds once the holder releases.
  fresh deauth-excl
  sbx "$P" sh -c '
    flock -x /mnt/data/supervisor/share -c "sleep 2" &
    sleep 0.5
    s=$(date +%s)
    GA_DEAUTH_TEST=1 . "$0"; publish_counter 4 bid "" "\"3\":4" 3
    echo $(( $(date +%s) - s )) > /tmp/waited' "$DEAUTH" >/dev/null 2>&1
  _w="$(cat "$C/tmp/waited" 2>/dev/null || echo x)"
  if [ "$_w" != x ] && [ "$_w" -ge 1 ] && [ "$_w" -le 4 ] && published ga-wlan0-deauth.json '"reason3_total":4'; then
    PASS "SW-12[$L] deauth waits for a holder of the shared-directory lock (${_w}s), then publishes"
  else
    FAIL "SW-12[$L] deauth waits for a holder of the shared-directory lock" "waited=$_w"
  fi
  # A holder that never releases must not wedge the counter: bounded wait.
  fresh deauth-bound
  sbx "$P" sh -c '
    flock -x /mnt/data/supervisor/share -c "sleep 12" &
    sleep 0.5
    s=$(date +%s)
    GA_DEAUTH_TEST=1 . "$0"; publish_counter 4 bid "" "\"3\":4" 3
    echo $(( $(date +%s) - s )) > /tmp/waited
    kill %1 2>/dev/null' "$DEAUTH" >/dev/null 2>&1
  _w="$(cat "$C/tmp/waited" 2>/dev/null || echo x)"
  if [ "$_w" != x ] && [ "$_w" -ge 4 ] && [ "$_w" -le 8 ] && published ga-wlan0-deauth.json '"reason3_total":4'; then
    PASS "SW-13[$L] a lock that is never released delays the publish by the bounded wait only (${_w}s)"
  else
    FAIL "SW-13[$L] a lock that is never released delays the publish by the bounded wait only" "waited=$_w"
  fi
}

echo "share_writers — status files in the shared directory ($BWRAP)"
run_cases host ""
if [ -n "$BBDIR" ]; then
  run_cases busybox "/mnt/.busybox:"
else
  echo "  NOTE  busybox not installed — BusyBox pass not run (CI sets GA_REQUIRE_BUSYBOX=1)"
fi

echo
echo "share_writers: $pass passed, $fail failed"
[ "$pass" -gt 0 ] || { echo "FATAL: no check ran"; exit 1; }
[ "$fail" -eq 0 ]
