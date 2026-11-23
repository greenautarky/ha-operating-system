#!/bin/sh
# ota_resume — ga-rauc-install fetches resumably and installs only a verified
# bundle (Odoo #2136).
#
# The REAL ga-rauc-install runs with the REAL curl against a REAL HTTPS server
# (range_server.py: Range, ETag/If-Range, fault injection) on a mesh address,
# inside an unprivileged user+network+PID namespace:
#   - the namespace has only `lo`; the mesh address is added there, so the
#     installer's `curl --resolve ota.greenautarky.com:443:<mesh ip>` reaches
#     the fixture and nothing else;
#   - TLS is verified against a throw-away CA (CURL_CA_BUNDLE), never -k;
#   - only rauc, systemctl and sync are stubbed. curl is NOT stubbed: its
#     resume behaviour is the thing under test (rule 8);
#   - --kill-child: when a case ends, every process in its PID namespace dies,
#     including the installer's detached `sleep 5 && systemctl reboot` - it can
#     never outlive the case and reach a real systemctl (the 2026-08-28 reboot
#     incident of the old fixtures).
#
#   OTAR-01  clean fetch: verified, installed, state cleared, wire bytes = size
#   OTAR-02  three cuts mid-download: resumed with Range + If-Range, wire bytes
#            ~1.0x the bundle (not 3x), the installed file is the served one
#   OTAR-03  a stall (server silent): detected by the stall limit, resumed
#   OTAR-04  per-rc slot 404 -> the prod slot (sidecar decides the slot)
#   OTAR-05  per-rc slot NETWORK error -> NO prod fallback, retried, gives up
#   OTAR-05c per-rc slot HTTP 503 / 403 -> NO prod fallback either (404 only)
#   OTAR-06  sha256 mismatch: never installed, partial discarded, status failed
#   OTAR-07  the build changes between attempts: the partial is dropped
#   OTAR-08  a killed run leaves the accepted request; a run without a new
#            request resumes it from the partial (boot re-arm path)
#   OTAR-09  a new request in ga_manager's directory supersedes a retrying run
#   OTAR-10  a complete partial (crash before rename): 416 -> verified, installed
#   OTAR-11  not staged anywhere: permanent, one attempt, status failed
#   OTAR-12  the status file is valid JSON with exactly the fixture's keys and
#            types, and shows a downloading phase with bytes and total
#   OTAR-13  the units: no fixed start timeout, boot re-arm unit enabled
#   OTAR-14  the same bytes re-published (new ETag): If-Range refused -> restart
#   OTAR-15  a store without Range support: the partial is dropped, fetched whole
#   OTAR-16  the per-run deadline counts uptime, ends retries before the limit
#   OTAR-17  the attempt count is persisted: a resumed run continues it
#   OTAR-18  a long backoff pause keeps the status fresh (heartbeat)
#
# GA_OTAR_INSTALLER replaces the installer under test (red proof against an
# older version). GA_T_SHELL runs it with another shell ("busybox sh" = the
# device's shell).
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/ga_tests/ota_resume"
EXT="$ROOT/buildroot-external/rootfs-overlay"
INSTALLER="${GA_OTAR_INSTALLER:-$EXT/usr/sbin/ga-rauc-install}"
UNITS="$EXT/usr/lib/systemd/system"
# Pinned here, not read from the tree under test (rule 7).
OTA_HOST=ota.greenautarky.com
MESH_IP=$(printf '100.%d.0.21' 100)
V1=18.4.1.6
V2=18.4.1.7
RC=BOSv1.6.2-rc1
SIZE=$((4 * 1024 * 1024))
MIB=$((1024 * 1024))

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
ok() { if eval "$2"; then PASS "$1"; else FAIL "$1" "${3:-}"; fi; }

for t in python3 openssl curl sha256sum ip; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: $t missing - this suite must not pass without running" >&2; exit 1; }
done

# ── the namespace runner (fail closed if none can be made) ──────────────────
NS=""
if unshare -rn --pid --fork --kill-child --mount-proc sh -c 'ip link set lo up && ip addr add 192.0.2.99/32 dev lo' 2>/dev/null; then
  NS="unshare -rn --pid --fork --kill-child --mount-proc"
elif sudo -n unshare -n --pid --fork --kill-child --mount-proc sh -c 'ip link set lo up && ip addr add 192.0.2.99/32 dev lo' 2>/dev/null; then
  NS="sudo -n unshare -n --pid --fork --kill-child --mount-proc"
fi
if [ -z "$NS" ]; then
  echo "FATAL: cannot create a network+PID namespace here - this suite must not pass without running" >&2
  exit 1
fi

WORK="$(mktemp -d -t ota-resume-XXXXXX)"
# OTAR_KEEP=1 keeps the work directory for debugging (printed at the end).
if [ -n "${OTAR_KEEP:-}" ]; then trap 'echo "kept: $WORK"' EXIT
else trap 'rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK" 2>/dev/null' EXIT; fi

# ── a throw-away CA and the store's certificate ─────────────────────────────
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=ota-resume-test-ca \
  -keyout "$WORK/ca.key" -out "$WORK/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=$OTA_HOST" \
  -keyout "$WORK/srv.key" -out "$WORK/srv.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\n' "$OTA_HOST" > "$WORK/san.ext"
openssl x509 -req -in "$WORK/srv.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial \
  -days 2 -extfile "$WORK/san.ext" -out "$WORK/srv.pem" >/dev/null 2>&1
[ -s "$WORK/srv.pem" ] || { echo "FATAL: could not make the test certificate" >&2; exit 1; }

# ── stubs: rauc records the sha256 of what it is asked to install ──────────
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/rauc" <<'EOF'
#!/bin/sh
case "$1" in
  info) exit 0 ;;
  install) echo "rauc install $2 $(sha256sum "$2" | cut -d' ' -f1)" >> "$OTAR_CASE/calls"; exit 0 ;;
esac
exit 1
EOF
for c in systemctl sync; do
  printf '#!/bin/sh\necho "%s $*" >> "$OTAR_CASE/calls"\nexit 0\n' "$c" > "$STUBS/$c"
done
printf '#!/bin/sh\nexit 0\n' > "$STUBS/resolver"
chmod +x "$STUBS"/*

# ── the store: bundles + sidecars ───────────────────────────────────────────
mkbundle() {  # <relpath> — random content + a sidecar naming it
  mkdir -p "$(dirname "$WORK/store/$1")"
  head -c "$SIZE" /dev/urandom > "$WORK/store/$1"
  printf '%s  %s\n' "$(sha256sum "$WORK/store/$1" | cut -d' ' -f1)" "$(basename "$1")" > "$WORK/store/$1.sha256"
}
RC_PATH="releases/$V1/$RC/haos_ihost-$V1.raucb"
PROD_PATH="releases/$V1/haos_ihost-$V1.raucb"
V2_PATH="releases/$V2/haos_ihost-$V2.raucb"
STORE0="$WORK/store0"
mkbundle "$RC_PATH"; mkbundle "$PROD_PATH"; mkbundle "$V2_PATH"
cp -a "$WORK/store" "$STORE0"
sha() { sha256sum "$1" | cut -d' ' -f1; }
RC_SHA=$(sha "$WORK/store/$RC_PATH")
PROD_SHA=$(sha "$WORK/store/$PROD_PATH")
V2_SHA=$(sha "$WORK/store/$V2_PATH")

# ── one case = one namespace: server + installer ────────────────────────────
fresh() {  # <case> [control-json]
  C="$WORK/case/$1"; rm -rf "$C"; mkdir -p "$C/gm" "$C/stage" "$C/state" "$C/run"
  : > "$C/calls"; : > "$C/log"; : > "$C/statuslog"
  printf '%s\n' "${2:-{\}}" > "$C/control.json"
  printf '%s\n' "$MESH_IP" > "$C/pin"
  printf 'NAME="GA OS"\nVARIANT_ID=ihost\n' > "$C/os-release"
  rm -rf "$WORK/store"; cp -a "$STORE0" "$WORK/store"
}
INSTENV=""
KILL_AFTER=""
run() {  # [installer args...] — runs in the case's namespace
  # shellcheck disable=SC2086  # $NS and $INSTENV must word-split
  $NS env OTAR_CASE="$C" OTAR_SRV="$HERE/range_server.py" OTAR_WORK="$WORK" \
      OTAR_IP="$MESH_IP" OTAR_KILL="$KILL_AFTER" OTAR_INSTALLER="$INSTALLER" OTAR_SH="${GA_T_SHELL:-sh}" \
      sh -c '
    ip link set lo up && ip addr add "$OTAR_IP/32" dev lo || exit 90
    python3 -I "$OTAR_SRV" --addr "$OTAR_IP" --port 443 --root "$OTAR_WORK/store" \
      --cert "$OTAR_WORK/srv.pem" --key "$OTAR_WORK/srv.key" --control "$OTAR_CASE/control.json" \
      --log "$OTAR_CASE/log" --ready "$OTAR_CASE/ready" 2> "$OTAR_CASE/server.err" &
    i=0; while [ ! -e "$OTAR_CASE/ready" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
    [ -e "$OTAR_CASE/ready" ] || exit 91
    rm -f "$OTAR_CASE/ready"
    # status snapshots for OTAR-12 (every 0.2 s while the installer runs)
    ( while :; do [ -f "$OTAR_CASE/gm/ga-rauc-install.status" ] && cat "$OTAR_CASE/gm/ga-rauc-install.status" >> "$OTAR_CASE/statuslog"; sleep 0.2; done ) &
    if [ -n "$OTAR_KILL" ]; then T="timeout -s KILL $OTAR_KILL"; else T="timeout -s KILL 120"; fi
    $T env PATH="$OTAR_WORK/stubs:$PATH" CURL_CA_BUNDLE="$OTAR_WORK/ca.pem" \
      GA_GM_DATA_DIR="$OTAR_CASE/gm" GA_STAGING_DIR="$OTAR_CASE/stage" \
      GA_OTA_STATE_DIR="$OTAR_CASE/state" GA_OTA_PHASE_FILE="$OTAR_CASE/phase" \
      GA_OTA_ACTIVE_FILE="$OTAR_CASE/pin" GA_RESOLVE_OTA_BIN="$OTAR_WORK/stubs/resolver" \
      GA_OS_RELEASE="$OTAR_CASE/os-release" GA_OTA_IDENT_DIR="$OTAR_CASE/run" \
      GA_JOURNAL_DUMP_BIN=/nonexistent \
      GA_OTA_BACKOFF_S=1 GA_OTA_BACKOFF_MAX_S=1 GA_OTA_STALL_S=2 GA_OTA_LOW_SPEED=1024 \
      GA_OTA_STATUS_EVERY_S=1 GA_OTA_MAX_ATTEMPTS=6 '"$INSTENV"' \
      $OTAR_SH "$OTAR_INSTALLER" "$@" > "$OTAR_CASE/out" 2>&1
    echo $? > "$OTAR_CASE/rc"
  ' sh "$@"
}
rc() { cat "$C/rc" 2>/dev/null; }
out() { tr '\n' ';' < "$C/out" | tail -c 900; }
installed() { awk '$1 == "rauc" && $2 == "install" { print $4 }' "$C/calls"; }
n_installs() { grep -c '^rauc install ' "$C/calls"; }
# body bytes the server wrote for paths containing <substr>
wire() { python3 -I -c 'import json,sys
t=0
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["path"].endswith(sys.argv[2]): t+=r["sent"]
print(t)' "$C/log" "$1"; }
reqs() { python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["path"].endswith(sys.argv[2]): print(r["status"], r.get("range") or "-", r.get("if_range") or "-", r["sent"], r["cut"])' "$C/log" "$1"; }
state_present() { [ -f "$C/state/request" ]; }

echo "--- clean fetch ---"
fresh r01
run "$V1" "$RC"
ok "OTAR-01 clean fetch: rc 0, the served per-rc bundle is installed once" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$RC_SHA' ] && [ \"\$(n_installs)\" = 1 ]" "rc=$(rc) installed=$(installed) out: $(out)"
ok "OTAR-01b ... the accepted request is cleared, the reboot is scheduled" \
   "! state_present && grep -q 'scheduling reboot' '$C/out'"
ok "OTAR-01c ... wire bytes for the bundle = its size ($SIZE)" "[ \"\$(wire $RC_PATH)\" = $SIZE ]" "wire=$(wire $RC_PATH)"

echo "--- resume ---"
fresh r02 "{\"cut_after\": $MIB, \"cut_count\": 3}"
run "$V1" "$RC"
ok "OTAR-02 three cuts: rc 0 and the served bundle is installed" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$RC_SHA' ]" "rc=$(rc) out: $(out)"
ok "OTAR-02b ... attempts 2-4 asked for the rest with Range + If-Range and got 206" \
   "[ \"\$(reqs $RC_PATH | grep -c '^206 bytes=[0-9]*- \"')\" = 3 ]" "reqs: $(reqs $RC_PATH | tr '\n' ';')"
ok "OTAR-02c ... wire bytes ~1.0x the bundle, not 3x (<= size + 64 KiB)" \
   "[ \"\$(wire $RC_PATH)\" -le $((SIZE + 65536)) ]" "wire=$(wire $RC_PATH) size=$SIZE"

# stall_s 20: curl judges speed over a ~5 s sliding window, so the 1 MiB burst
# before the silence keeps it "fast" for ~5 s; 2 s below 1 KiB/s comes after that.
fresh r03 "{\"stall_after\": $MIB, \"stall_s\": 20, \"stall_count\": 1}"
run "$V1" "$RC"
ok "OTAR-03 a stall is detected by the stall limit (curl 28) and the fetch resumes" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$RC_SHA' ] && grep -q 'curl exit 28' '$C/out' && [ \"\$(wire $RC_PATH)\" -le $((SIZE + 65536)) ]" \
   "rc=$(rc) wire=$(wire $RC_PATH) out: $(out)"

echo "--- slot choice ---"
fresh r04 "{\"missing\": [\"/$RC/\"]}"
run "$V1" "$RC"
ok "OTAR-04 per-rc slot 404: the PROD bundle is installed, verified against the prod sidecar" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$PROD_SHA' ]" "rc=$(rc) out: $(out)"

fresh r05 "{\"refuse\": [\"/$RC/\"]}"
INSTENV="GA_OTA_MAX_ATTEMPTS=3"
run "$V1" "$RC"
INSTENV=""
ok "OTAR-05 per-rc slot network error: NO fallback - the prod slot is never asked" \
   "[ -z \"\$(reqs $PROD_PATH)\" ] && [ \"\$(n_installs)\" = 0 ]" "prod reqs: $(reqs $PROD_PATH | tr '\n' ';') out: $(out)"
ok "OTAR-05b ... it is retried (3 attempts) and gives up with rc 3" \
   "[ \"\$(rc)\" = 3 ] && grep -q 'after 3 attempt' '$C/out'" "rc=$(rc) out: $(out)"

for code in 503 403; do
  fresh "r05-$code" "{\"error\": [[$code, \"/$RC/\"]]}"
  INSTENV="GA_OTA_MAX_ATTEMPTS=2"
  run "$V1" "$RC"
  INSTENV=""
  ok "OTAR-05c per-rc slot answers HTTP $code: NO fallback (only a 404 means not staged), retried, rc 3" \
     "[ -z \"\$(reqs $PROD_PATH)\" ] && [ -z \"\$(reqs $PROD_PATH.sha256)\" ] && [ \"\$(n_installs)\" = 0 ] && [ \"\$(rc)\" = 3 ] && grep -q 'HTTP $code' '$C/out'" \
     "rc=$(rc) out: $(out)"
done

echo "--- integrity ---"
fresh r06
printf '%s  %s\n' "$PROD_SHA" "haos_ihost-$V1.raucb" > "$WORK/store/$RC_PATH.sha256"
INSTENV="GA_OTA_MAX_ATTEMPTS=2"
run "$V1" "$RC"
INSTENV=""
ok "OTAR-06 sha256 mismatch: never installed, rc 3" \
   "[ \"\$(n_installs)\" = 0 ] && [ \"\$(rc)\" = 3 ] && grep -q 'sha256 mismatch' '$C/out'" "rc=$(rc) out: $(out)"
ok "OTAR-06b ... no partial or bundle is left in staging" \
   "[ -z \"\$(ls -A '$C/stage' | grep -v -e '\\.sidecar\$' -e '\\.hdr\$' -e '\\.code\$' -e '\\.sha256\$')\" ]" "stage: $(ls -A "$C/stage" | tr '\n' ' ')"
ok "OTAR-06c ... the status says failed with the reason" \
   "grep -q '\"phase\":\"failed\"' '$C/gm/ga-rauc-install.status' && grep -q 'sha256 mismatch' '$C/gm/ga-rauc-install.status'" \
   "status: $(cat "$C/gm/ga-rauc-install.status" 2>/dev/null)"

fresh r07
NEWB="$WORK/newbuild.raucb"; head -c "$SIZE" /dev/urandom > "$NEWB"
NEW_SHA=$(sha "$NEWB")
printf '%s  %s\n' "$NEW_SHA" "haos_ihost-$V1.raucb" > "$WORK/newbuild.sha256"
cat > "$C/control.json" <<EOF
{"cut_after": $MIB, "cut_count": 1,
 "write_file": {"path": "$WORK/store/$RC_PATH.sha256", "content": "$NEW_SHA  haos_ihost-$V1.raucb\\n", "after_requests": 1}}
EOF
# the new build's bytes go in place before the second attempt: the control
# swaps the sidecar; the bundle itself is replaced here and served after the cut
cp "$NEWB" "$WORK/store/$RC_PATH.next"
( sh -c "while [ ! -s '$C/log' ]; do sleep 0.05; done; mv -f '$WORK/store/$RC_PATH.next' '$WORK/store/$RC_PATH'" & )
run "$V1" "$RC"
ok "OTAR-07 the build changed between attempts: the partial is dropped, the NEW build is installed" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$NEW_SHA' ] && grep -q 'belongs to another build' '$C/out'" "rc=$(rc) installed=$(installed) out: $(out)"

fresh r14 "{\"cut_after\": $MIB, \"cut_count\": 1, \"etag_suffix_after\": 1}"
run "$V1" "$RC"
ok "OTAR-14 the same bytes re-published (new ETag): If-Range is refused, the fetch restarts and installs" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$RC_SHA' ] && reqs $RC_PATH | sed -n 2p | grep -q '^200 bytes=$MIB- \"' && grep -q 'did not resume' '$C/out' && ! grep -q 'sha256 mismatch' '$C/out'" \
   "rc=$(rc) reqs: $(reqs $RC_PATH | tr '\n' ';') out: $(out)"

fresh r15 "{\"cut_after\": $MIB, \"cut_count\": 1, \"no_ranges\": true}"
run "$V1" "$RC"
ok "OTAR-15 a store without Range support: the refused resume drops the partial, the next attempt fetches it whole" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$RC_SHA' ] && grep -q 'did not resume' '$C/out'" "rc=$(rc) reqs: $(reqs $RC_PATH | tr '\n' ';') out: $(out)"

echo "--- the request survives ---"
fresh r08 "{\"stall_after\": $MIB, \"stall_s\": 60, \"stall_count\": 1}"
INSTENV="GA_OTA_STALL_S=50"
KILL_AFTER=4
run "$V1" "$RC"
KILL_AFTER=""; INSTENV=""
PART_SZ=$(stat -c %s "$C/stage/ga-rauc-install-$V1.raucb.part" 2>/dev/null || echo 0)
ok "OTAR-08 a killed run leaves the accepted request and its partial ($PART_SZ bytes)" \
   "state_present && [ \"\$(sed -n 1p '$C/state/request')\" = '$V1' ] && [ \"\$(sed -n 2p '$C/state/request')\" = '$RC' ] && [ \"\$(sed -n 3p '$C/state/request')\" -ge 1 ] && [ '$PART_SZ' -ge $MIB ]" \
   "state: $(tr '\n' '|' < "$C/state/request" 2>/dev/null) out: $(out)"
printf '{}\n' > "$C/control.json"; : > "$C/log"
run
ok "OTAR-08b ... a run with no new request resumes it from the partial and installs" \
   "[ \"\$(rc)\" = 0 ] && grep -q 'resuming accepted request' '$C/out' && [ \"\$(installed)\" = '$RC_SHA' ] && [ \"\$(wire $RC_PATH)\" -le $((SIZE - PART_SZ + 65536)) ]" \
   "rc=$(rc) wire=$(wire $RC_PATH) out: $(out)"

fresh r16 '{"refuse": [".sha256"]}'
INSTENV="GA_OTA_DEADLINE_S=2 GA_OTA_MAX_ATTEMPTS=40"
run "$V1" "$RC"
INSTENV=""
N16=$(grep -c 'retrying in' "$C/out")
ok "OTAR-16 the per-run deadline (by uptime) ends the retries long before the attempt limit" \
   "[ \"\$(rc)\" = 3 ] && grep -q 'deadline of 2s' '$C/out' && [ $N16 -lt 10 ]" "rc=$(rc) retries=$N16 out: $(out)"

fresh r17 '{"refuse": [".sha256"]}'
printf '%s\n%s\n%s\n' "$V1" "$RC" 5 > "$C/state/request"
run
ok "OTAR-17 attempts carry across runs (reboots): 5 used + 1 = the limit of 6, gives up" \
   "[ \"\$(rc)\" = 3 ] && grep -q 'after 6 attempt' '$C/out' && [ \"\$(grep -c 'downloading https.*sha256' '$C/out')\" = 1 ]" "rc=$(rc) out: $(out)"

fresh r18 '{"refuse": [".sha256"]}'
INSTENV="GA_OTA_BACKOFF_S=65 GA_OTA_MAX_ATTEMPTS=2"
run "$V1" "$RC"
INSTENV=""
python3 -I - "$C/statuslog" > "$WORK/hb.check" 2>&1 <<'PYEOF2'
import json, sys
text = open(sys.argv[1]).read()
dec = json.JSONDecoder(); i = 0; seen = []
while i < len(text):
    while i < len(text) and text[i].isspace(): i += 1
    if i >= len(text): break
    obj, i = dec.raw_decode(text, i); seen.append(obj)
ts = sorted({s["updated"] for s in seen if s["phase"] == "retrying"})
print("retrying updates:", ts)
sys.exit(0 if len(ts) >= 2 and ts[-1] - ts[0] >= 55 else 1)
PYEOF2
_hb=$?
ok "OTAR-18 a backoff pause rewrites the status (heartbeat <= 60 s; readers treat > 10 min as stale)" \
   "[ $_hb = 0 ]" "$(tr '\n' ' ' < "$WORK/hb.check")"

fresh r09
printf '%s\n' "$V1" > "$C/gm/ga-rauc-install-request"
printf '%s\n' "$RC" > "$C/gm/ga-rauc-install-request.rc"
cat > "$C/control.json" <<EOF
{"cut_after": $MIB, "cut_count": 1,
 "write_file": {"path": "$C/gm/ga-rauc-install-request", "content": "$V2\\n", "after_requests": 1}}
EOF
run
ok "OTAR-09 a new request supersedes a retrying run: $V2 is installed, not $V1" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$V2_SHA' ] && grep -q 'supersedes' '$C/out' && [ ! -e '$C/gm/ga-rauc-install-request' ]" \
   "rc=$(rc) installed=$(installed) out: $(out)"
ok "OTAR-09b ... and the old version's partial is removed" \
   "[ ! -e '$C/stage/ga-rauc-install-$V1.raucb.part' ]" "stage: $(ls -A "$C/stage" | tr '\n' ' ')"

fresh r10
cp "$WORK/store/$RC_PATH" "$C/stage/ga-rauc-install-$V1.raucb.part"
printf '%s\n' "$RC_SHA" > "$C/stage/ga-rauc-install-$V1.raucb.part.sha256"
run "$V1" "$RC"
ok "OTAR-10 a complete partial: the store answers 416, the partial is verified and installed" \
   "[ \"\$(rc)\" = 0 ] && [ \"\$(installed)\" = '$RC_SHA' ] && [ \"\$(wire $RC_PATH)\" = 0 ] && reqs $RC_PATH | grep -q '^416 '" \
   "rc=$(rc) reqs: $(reqs $RC_PATH | tr '\n' ';') out: $(out)"

fresh r11 '{"missing": [".raucb"]}'
run "$V1" "$RC"
ok "OTAR-11 not staged in either slot: permanent - rc 3 after ONE attempt, nothing installed" \
   "[ \"\$(rc)\" = 3 ] && grep -q 'after 1 attempt' '$C/out' && [ \"\$(n_installs)\" = 0 ] && grep -q '\"phase\":\"failed\"' '$C/gm/ga-rauc-install.status'" \
   "rc=$(rc) out: $(out)"

echo "--- the status file (seam to ga_manager) ---"
# OTAR-12: the snapshots of the stall case (r03) must hold a downloading phase
C="$WORK/case/r03"
python3 -I - "$HERE/fixtures" "$C/statuslog" "$C/gm/ga-rauc-install.status" "$SIZE" > "$WORK/status.check" 2>&1 <<'PYEOF'
import json, sys, pathlib
fixdir, snaps, final, size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
fixtures = sorted(pathlib.Path(fixdir).glob("status-*.json"))
if not fixtures:
    print("no fixtures"); sys.exit(1)
ref = json.loads(fixtures[0].read_text())
for f in fixtures:
    d = json.loads(f.read_text())
    if set(d) != set(ref):
        print(f"fixture {f.name} has other keys"); sys.exit(1)
def typ(v): return "null" if v is None else type(v).__name__
seen = []
dec = json.JSONDecoder()
text = pathlib.Path(snaps).read_text() + pathlib.Path(final).read_text()
i = 0
while i < len(text):
    while i < len(text) and text[i].isspace(): i += 1
    if i >= len(text): break
    obj, i = dec.raw_decode(text, i)
    seen.append(obj)
if not seen:
    print("no status written"); sys.exit(1)
for s in seen:
    if set(s) != set(ref):
        print("keys differ:", sorted(set(s) ^ set(ref))); sys.exit(1)
    for k in ("schema", "attempt", "max_attempts", "updated"):
        if typ(s[k]) != "int":
            print("type", k, typ(s[k])); sys.exit(1)
    for k in ("bytes", "total", "next_retry_at"):
        if typ(s[k]) not in ("int", "null"):
            print("type", k, typ(s[k])); sys.exit(1)
    if s["schema"] != 1:
        print("schema", s["schema"]); sys.exit(1)
dl = [s for s in seen if s["phase"] == "downloading" and (s["bytes"] or 0) > 0 and s["total"] == size]
phases = sorted({s["phase"] for s in seen})
print("snapshots", len(seen), "phases", phases, "downloading-with-bytes", len(dl))
sys.exit(0 if dl and "retrying" in phases and seen[-1]["phase"] == "rebooting" else 1)
PYEOF
_st=$?
ok "OTAR-12 status: schema-1 JSON with the fixture's keys and types; downloading (bytes, total=$SIZE), retrying, rebooting" \
   "[ $_st = 0 ]" "$(tr '\n' ' ' < "$WORK/status.check")"

echo "--- units ---"
ok "OTAR-13 ga-rauc-install.service has no fixed start timeout" \
   "grep -qx 'TimeoutStartSec=infinity' '$UNITS/ga-rauc-install.service'"
ok "OTAR-13b the boot re-arm unit starts the ONE install unit when a request is accepted" \
   "grep -qx 'ConditionPathExists=/mnt/data/ga-ota/request' '$UNITS/ga-rauc-install-resume.service' && grep -qx 'ExecStart=/usr/bin/systemctl start --no-block ga-rauc-install.service' '$UNITS/ga-rauc-install-resume.service' && [ \"\$(readlink '$UNITS/multi-user.target.wants/ga-rauc-install-resume.service')\" = ../ga-rauc-install-resume.service ]"

# coverage (rule 9): every case must have actually run the installer
ran=0; for d in "$WORK"/case/*; do [ -s "$d/out" ] && ran=$((ran+1)); done
ok "OTAR-99 all 18 cases ran the installer" "[ $ran = 18 ]" "ran=$ran"

echo "--- ota_resume: $pass passed, $fail failed ---"
[ "$fail" = 0 ]
