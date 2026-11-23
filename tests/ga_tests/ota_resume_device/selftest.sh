#!/bin/sh
# Host-side selftest of ota_resume_device/test.sh: the LIVE device suite drives
# the LIVE ga-rauc-install against the ota_resume fixture store (range_server.py,
# a 40 MB bundle, cut after 5 MB) in a network+PID namespace. Known-good must
# PASS every check (the suite CAN go green); the installer from before the
# resumable fetch must be RED on the resume checks (it CAN go red).
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SUITE="$ROOT/tests/ga_tests/ota_resume_device/test.sh"
SRV="$ROOT/tests/ga_tests/ota_resume/range_server.py"
LIVE="$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install"
OLD="${GA_ORD_OLD_INSTALLER:-}"
V=18.4.1.6; RC=BOSv1.6.2-rc1; IP=$(printf '100.%d.0.21' 100)
NS=""
if unshare -rn --pid --fork --kill-child --mount-proc true 2>/dev/null; then NS="unshare -rn --pid --fork --kill-child --mount-proc"
elif sudo -n unshare -n --pid --fork --kill-child --mount-proc true 2>/dev/null; then NS="sudo -n unshare -n --pid --fork --kill-child --mount-proc"; fi
[ -n "$NS" ] || { echo "FATAL: no namespace - this selftest must not pass without running" >&2; exit 1; }
W="$(mktemp -d -t ord-self-XXXXXX)"; [ -n "${ORDS_KEEP:-}" ] && echo "kept: $W" && trap "" EXIT || trap 'rm -rf "$W" 2>/dev/null || sudo -n rm -rf "$W"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=ord-ca -keyout "$W/ca.key" -out "$W/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=ota.greenautarky.com -keyout "$W/k" -out "$W/csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:ota.greenautarky.com\n' > "$W/ext"
openssl x509 -req -in "$W/csr" -CA "$W/ca.pem" -CAkey "$W/ca.key" -CAcreateserial -days 2 -extfile "$W/ext" -out "$W/c" >/dev/null 2>&1
B="$W/store/releases/$V/$RC/haos_ihost-$V.raucb"; mkdir -p "$(dirname "$B")"
head -c $((40 * 1024 * 1024)) /dev/urandom > "$B"
printf '%s  %s\n' "$(sha256sum "$B" | cut -d' ' -f1)" "haos_ihost-$V.raucb" > "$B.sha256"
printf '%s\n' "$RC" > "$W/ga-release"; printf 'VERSION_ID=%s\nVARIANT_ID=ihost\n' "$V" > "$W/os-release"
printf '%s\n' "$IP" > "$W/pin"; echo '{}' > "$W/ctl"

run_suite() {  # <installer> <log>
  rm -rf "$W/tmp"; mkdir -p "$W/tmp"
  $NS env W="$W" SRV="$SRV" IP="$IP" SUITE="$SUITE" INST="$1" TSH="${GA_T_SHELL:-sh}" sh -c '
    ip link set lo up && ip addr add "$IP/32" dev lo || exit 90
    python3 -I "$SRV" --addr "$IP" --root "$W/store" --cert "$W/c" --key "$W/k" --control "$W/ctl" --log "$W/srv.log" --ready "$W/ready" &
    i=0; while [ ! -e "$W/ready" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; rm -f "$W/ready"
    GA_TEST_DESTRUCTIVE=1 GA_ORD_INSTALLER="$INST" GA_ORD_RELEASE_FILE="$W/ga-release" GA_ORD_OS_RELEASE="$W/os-release" \
    GA_ORD_TMP="$W/tmp" GA_ORD_CUT_MB=5 GA_OS_RELEASE="$W/os-release" GA_OTA_ACTIVE_FILE="$W/pin" \
    GA_RESOLVE_OTA_BIN=/bin/true CURL_CA_BUNDLE="$W/ca.pem" NO_COLOR=1 timeout -s KILL 300 $TSH "$SUITE"' > "$2" 2>&1
}
pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
run_suite "$LIVE" "$W/live.log"
n=$(grep -cE 'PASS.*ORD-0[0-7]' "$W/live.log")
if [ "$n" = 8 ] && ! grep -qE 'FAIL|SKIP' "$W/live.log"; then PASS "ORDS-01 live installer: all 8 checks PASS (the suite can go green)"
else FAIL "ORDS-01 live installer: all 8 checks PASS" "$(grep -E 'FAIL|SKIP|->' "$W/live.log" | head -6 | tr '\n' ';')"; fi
# red side: the pre-#2136 installer when given, else a mutant of the LIVE one
# without Range resume (a missing mutation target is a FAILURE, never a skip)
if [ -n "$OLD" ]; then RED="$OLD"; WANT="ORD-02 ORD-03"
else
  RED="$W/no-resume"; WANT="ORD-02 ORD-04"
  python3 -I - "$LIVE" "$RED" <<'PYEOF2' || FAIL "ORDS-02 mutant" "target 'set -- \"\$@\" --continue-at -' not found once"
import sys
s = open(sys.argv[1]).read(); old = '        set -- "$@" --continue-at -'
if s.count(old) != 1: sys.exit(1)
open(sys.argv[2], "w").write(s.replace(old, "        :", 1))
PYEOF2
fi
if [ -s "$RED" ]; then
  run_suite "$RED" "$W/red.log"
  miss=""; for c in $WANT; do grep -qE "FAIL.*$c:" "$W/red.log" || miss="$miss $c"; done
  if [ -z "$miss" ]; then PASS "ORDS-02 an installer without resume is RED on $WANT"
  else FAIL "ORDS-02 an installer without resume is RED on $WANT" "not red:$miss"; fi
fi
echo "--- ota_resume_device selftest: $pass passed, $fail failed ---"
[ "$fail" = 0 ]
