#!/bin/sh
# ga-rauc-install — does the chosen OTA path actually reach the download?
#
# WHY THIS EXISTS. `ga-resolve-ota` probes every address in GA_OTA_IPS every five
# minutes, writes the winner to /run/ga-resolve-ota.active, and ga-update-hosts
# copies it into /etc/hosts. All of that ran, logged success, and changed nothing
# about where the bundle came from.
#
# Measured on K31 2026-08-28, across the five GA names in /etc/hosts:
#
#     fleet / influx / loki   no public A record   -> took the pinned address
#     ota / mqtt              public A record      -> took the PUBLIC endpoint
#
# A name is resolved by DNS first; /etc/hosts only answers when DNS does not.
# Three of five names looked correct — they agreed with the pin by accident, not
# because the pin worked — and the two that did not are the two that matter.
# Every OTA bundle therefore travelled the public internet while a selected,
# reachable mesh path sat unused. Forcing the address with --resolve makes the
# selection load-bearing without touching DNS.
#
# WHAT THIS SUITE RUNS. The LIVE script, with curl/rauc/systemctl replaced by
# stubs on PATH that record their arguments. The stubs are collaborators, not the
# subject: the subject is which address this script tells curl to use, and that
# code is the real one. Nothing here reboots anything — `systemctl` is a stub, and
# a test that could reboot the machine it runs on is not a test.
#
# Pure host-side: sh + awk. No device required. Runs in lint.yml host-suites.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-rauc-install (the chosen OTA path reaches the download)"

OVERLAY="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay"
INSTALL="$OVERLAY/usr/sbin/ga-rauc-install"

run_test "OTAP-01" "ga-rauc-install present + executable" "test -x '$INSTALL'"
if [ ! -x "$INSTALL" ]; then
  # Fail closed. "Could not find the subject" must never read as "the subject is
  # fine" — that is the same confusion this whole suite is about.
  suite_end
  exit 1
fi

WORK="$(mktemp -d)"
BIN="$WORK/bin"; mkdir -p "$BIN"
ARGS="$WORK/curl-args"
CALLS="$WORK/stub-calls"
OUT="$WORK/stdout"; ERR="$WORK/stderr"

# ---- stubs -----------------------------------------------------------------
# curl: record argv, create the output file, and optionally fail the FIRST call
# so the fallback URL is exercised too.
cat > "$BIN/curl" <<'STUB'
#!/bin/sh
echo "$@" >> "$CURL_ARGS_FILE"
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && : > "$out"
if [ -n "$STUB_CURL_FAIL_FIRST" ] && [ ! -f "$CURL_ARGS_FILE.firstdone" ]; then
  : > "$CURL_ARGS_FILE.firstdone"
  exit 22
fi
exit 0
STUB
for c in rauc sync; do
  printf '#!/bin/sh\nexit 0\n' > "$BIN/$c"
done

# systemctl + reboot RECORD the call instead of silently succeeding, so the suite
# can assert the reboot was caught HERE rather than assuming it.
for c in systemctl reboot; do
  printf '#!/bin/sh\necho "%s $*" >> "$STUB_CALLS_FILE"\nexit 0\n' "$c" > "$BIN/$c"
done

# sleep is stubbed to return AT ONCE, and that is a safety control, not a speed-up.
#
# ga-rauc-install ends with `( sleep 5 && systemctl reboot ) &` — a DETACHED
# subshell that outlives the script. On 2026-08-28 this suite let those subshells
# escape: the suite finished in under a second, `rm -rf "$WORK"` deleted the stub
# directory, and five seconds later a dozen orphans resolved `systemctl` through
# the real PATH and rebooted the developer's laptop. Twice.
#
# Collapsing the timer means the reboot attempt lands on the stub WHILE it still
# exists, and `wait` below makes sure nothing is still pending at cleanup.
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
chmod +x "$BIN"/*

# ---- harness ---------------------------------------------------------------
# run <active-file-contents-or-ABSENT> [rc-label] [fail-first]
run() {
  rm -f "$ARGS" "$ARGS.firstdone" "$OUT" "$ERR"
  : > "$ARGS"
  af="$WORK/active"
  rm -f "$af"
  [ "$1" != "ABSENT" ] && printf '%s' "$1" > "$af"
  : > "$CALLS"
  PATH="$BIN:$PATH" \
  CURL_ARGS_FILE="$ARGS" \
  STUB_CALLS_FILE="$CALLS" \
  STUB_CURL_FAIL_FIRST="$3" \
  GA_OTA_ACTIVE_FILE="$af" \
  GA_OTA_STAGING_DIR="$WORK/staging" \
    sh "$INSTALL" 16.3.1.9 "$2" >"$OUT" 2>"$ERR"
  # Nothing may outlive the run. `wait` is the whole reason this is not a
  # one-liner: the script detaches its reboot timer, and an orphan that wakes up
  # after cleanup finds the real systemctl.
  wait 2>/dev/null || true
  return 0
}

PIN_443="--resolve ota.greenautarky.com:443:192.0.2.10"
PIN_80="--resolve ota.greenautarky.com:80:192.0.2.10"

# ---------------------------------------------------------------------------
# MUST PIN — the repair itself
# ---------------------------------------------------------------------------
# Fixture addresses are RFC 5737 documentation space (192.0.2.0/24), which exists
# for exactly this and sits outside every range the disclosure gate guards.
run "192.0.2.10
" "BOSv1.3.0-rc11"
run_test "OTAP-10" "the chosen address is forced on the download (:443)" \
  "grep -qF -- '$PIN_443' '$ARGS'"
run_test "OTAP-11" "and on :80, so a redirect cannot fall back to DNS" \
  "grep -qF -- '$PIN_80' '$ARGS'"
run_test "OTAP-12" "the chosen path is announced, not silent" \
  "grep -q 'using OTA path 192.0.2.10' '$OUT'"
run_test "OTAP-13" "the URL still names the host — the pin replaces resolution, not the request" \
  "grep -q 'https://ota.greenautarky.com/releases/16.3.1.9/BOSv1.3.0-rc11/' '$ARGS'"

# The fallback URL is a SECOND curl call. A pin applied to the first request only
# would send the retry — the one that runs when things are already going wrong —
# out over the unselected path.
run "192.0.2.10" "BOSv1.3.0-rc11" 1
run_test "OTAP-14" "the per-rc miss falls back to the prod slot" \
  "grep -q 'releases/16.3.1.9/haos_ihost' '$ARGS'"
run_test "OTAP-15" "the FALLBACK download is pinned too" \
  "test \"\$(grep -cF -- '$PIN_443' '$ARGS')\" -eq 2"

# No rc label: version-only slot, still pinned.
run "192.0.2.10" ""
run_test "OTAP-16" "version-only slot is pinned as well" \
  "grep -qF -- '$PIN_443' '$ARGS' && grep -q 'releases/16.3.1.9/haos_ihost' '$ARGS'"

# ---------------------------------------------------------------------------
# MUST NOT PIN — and must SAY SO. A silent fallback to DNS is the original defect.
# ---------------------------------------------------------------------------
check_unpinned() {   # check_unpinned <id> <description>
  run_test "$1" "$2 — no --resolve" "! grep -q -- '--resolve' '$ARGS'"
  run_test "${1}b" "$2 — warns LOUDLY on stderr, naming the file" \
    "grep -q 'WARN' '$ERR' && grep -q 'ga-resolve-ota' '$ERR'"
  run_test "${1}c" "$2 — the download still happens (never strand a device)" \
    "grep -q 'releases/16.3.1.9' '$ARGS'"
}

run "ABSENT" "BOSv1.3.0-rc11"
check_unpinned "OTAP-20" "active file absent"

run "" "BOSv1.3.0-rc11"
check_unpinned "OTAP-21" "active file empty"

run "not-an-ip" "BOSv1.3.0-rc11"
check_unpinned "OTAP-22" "active file holds a hostname"

# A malformed address would send the bundle somewhere nobody chose — worse than
# not pinning, because it looks deliberate.
run "999.1.1.1" "BOSv1.3.0-rc11"
check_unpinned "OTAP-23" "octet out of range"

run "192.0.2" "BOSv1.3.0-rc11"
check_unpinned "OTAP-24" "three octets"

run "2001:db8::1" "BOSv1.3.0-rc11"
check_unpinned "OTAP-25" "IPv6 literal (curl --resolve needs brackets we do not build)"

# ---------------------------------------------------------------------------
# MUST PASS — no false positives. A check that flags everything gets ignored.
# ---------------------------------------------------------------------------
run "192.0.2.10 # picked 12:44
" "BOSv1.3.0-rc11"
run_test "OTAP-30" "a trailing comment does not defeat the pin" \
  "grep -qF -- '$PIN_443' '$ARGS'"

run "192.0.2.10
203.0.113.9" "BOSv1.3.0-rc11"
run_test "OTAP-31" "only the FIRST line is used — one winner, not two" \
  "grep -qF -- '$PIN_443' '$ARGS' && ! grep -q '203.0.113.9' '$ARGS'"

run "255.255.255.255" "BOSv1.3.0-rc11"
run_test "OTAP-32" "255 is a legal octet — the validator must not be too strict" \
  "grep -qF -- '--resolve ota.greenautarky.com:443:255.255.255.255' '$ARGS'"

run "192.0.2.10" "BOSv1.3.0-rc11"
run_test "OTAP-33" "a pinned run says nothing alarming on stderr" \
  "! grep -q 'WARN' '$ERR'"
# THE GUARD THAT MATTERS, and the one this suite got wrong first.
#
# It used to assert `test -x "$BIN/systemctl"` — that the stub FILE exists. That
# cannot fail, proves nothing about what ran, and gave false confidence about the
# exact command that rebooted a laptop twice on 2026-08-28. Assert the call was
# CAUGHT instead: the script did try to reboot, and the attempt landed here.
run_test "OTAP-34" "the script's reboot attempt was intercepted by the stub" \
  "grep -q 'systemctl reboot' '$CALLS'"
run_test "OTAP-35" "and nothing is still pending after the run" \
  "test -z \"\$(jobs -p 2>/dev/null)\""

rm -rf "$WORK"
suite_end
