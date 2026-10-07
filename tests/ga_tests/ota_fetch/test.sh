#!/bin/sh
# ota_fetch — OTA downloads use the endpoint ga-resolve-ota pinned, and the
# resolver pins only an endpoint that actually SERVES the store.
#
#   ga-resolve-ota   probes each mesh candidate in GA_OTA_IPS for the store's
#                    probe object (GA_OTA_PROBE_PATH) with TLS verification and
#                    --fail; writes the first that serves it to
#                    /run/ga-resolve-ota.active. 403/404/TLS failure = NOT
#                    reachable. Non-mesh candidates are never probed.
#   ga-rauc-install  downloads with `curl --resolve ota.greenautarky.com:443:<pin>`
#                    from that file, runs the resolver once if it is missing,
#                    and fails closed if there is still no mesh pin.
#
# Why the pin and not /etc/hosts: on the host nsswitch asks systemd-resolved
# before `files`, so the hosts entry ga-update-hosts writes is not what decides
# where a plain lookup of the OTA name connects.
#
# How: the REAL scripts run inside a bubblewrap sandbox (like host_control) with
# a temp dir mounted at /mnt/data and /run, and an empty /etc that carries only
# the ga-services.conf under test. Only curl, rauc, systemctl, sleep and sync
# are stubbed. The curl stub models a server per address: a plan file maps
# "<ip> <answer>" where answer is an HTTP code, "dead" (no connection) or "tls"
# (certificate rejected unless -k). A curl without --resolve is recorded as a
# lookup through name resolution ("DNS"), which this suite treats as a defect.
#
# Test addresses: mesh addresses are assembled at run time and the "public"
# one is from the documentation range (RFC 5737), so this file adds no real
# address to a public repository.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXT="$ROOT/buildroot-external/rootfs-overlay"
IHOST="$ROOT/buildroot-ihost/rootfs-overlay"
RESOLVER="$IHOST/usr/sbin/ga-resolve-ota"
INSTALLER="$EXT/usr/sbin/ga-rauc-install"
BAKED_CONF="$EXT/etc/ga-services.conf"
# Pinned here, not derived from the tree under test (working-method rule 7).
OTA_HOST=ota.greenautarky.com
PROBE=/ga-ota-health
M1=$(printf '100.%d.0.21' 100)
M2=$(printf '100.%d.0.22' 100)
PUB=198.51.100.7

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1${2:+ ($2)}"; fail=$((fail+1)); }
ok() { if eval "$2"; then PASS "$1"; else FAIL "$1" "${3:-}"; fi; }

# in_mesh — the same rule the scripts apply, restated here on purpose: an
# expectation must not be read out of the artifact it audits.
in_mesh() {
  case "$1" in
    "" | *[!0-9.]* | *..* | .* | *. | *.*.*.*.* ) return 1 ;;
    *.*.*.* ) ;;
    * ) return 1 ;;
  esac
  _o1=${1%%.*}; _r=${1#*.}; _o2=${_r%%.*}
  [ "$_o1" = 100 ] && [ "$_o2" -ge 64 ] 2>/dev/null && [ "$_o2" -le 127 ]
}

# ── static: the baked candidate list ────────────────────────────────────────
echo "--- the baked OTA candidate list ---"
ips=$( (. "$BAKED_CONF"; echo "${GA_OTA_IPS:-}") )
n=0; bad=""
for ip in $ips; do n=$((n+1)); in_mesh "$ip" || bad="$bad $ip"; done
ok "OTAF-01 every GA_OTA_IPS entry is a mesh address ($n inspected)" \
   "[ $n -ge 1 ] && [ -z '$bad' ]" "non-mesh:$bad"
probe=$( (. "$BAKED_CONF"; echo "${GA_OTA_PROBE_PATH:-}") )
ok "OTAF-02 ga-services.conf names the probe object ($PROBE)" "[ '$probe' = '$PROBE' ]" "got '$probe'"

# ── the sandbox runner ──────────────────────────────────────────────────────
BWRAP=""
if command -v bwrap >/dev/null 2>&1; then
  if timeout 20 bwrap --unshare-net --unshare-pid --ro-bind / / --proc /proc --dev /dev true 2>/dev/null; then
    BWRAP="bwrap"
  elif timeout 20 sudo -n bwrap --unshare-net --unshare-pid --ro-bind / / --proc /proc --dev /dev true 2>/dev/null; then
    BWRAP="sudo -n bwrap"
  fi
fi
if [ -z "$BWRAP" ]; then
  echo "FATAL: bubblewrap cannot create a sandbox here — this suite must not pass without running" >&2
  exit 1
fi

WORK="$(mktemp -d -t ota-fetch-XXXXXX)"
trap 'rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK" 2>/dev/null' EXIT

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
for c in rauc systemctl sleep sync; do
  printf '#!/bin/sh\necho "%s $*" >> /mnt/data/.calls\nexit 0\n' "$c" > "$STUBS/$c"
done
# curl: one line per call in /mnt/data/.calls ("curl <ip|DNS> <url> <args>"),
# answer from /mnt/data/.plan ("<ip|DNS> <code|dead|tls>"; "MISS <substr>"
# forces a 404 for URLs containing <substr>). Mirrors real curl: an HTTP error
# is exit 0 without --fail and 22 with it; no connection is 7; a rejected
# certificate is 60 unless -k.
cat > "$STUBS/curl" <<'EOF'
#!/bin/sh
ip=DNS; out=""; url=""; f=0; k=0; all="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    --resolve) ip=${2##*:}; shift 2 ;;
    --output|-o) out="$2"; shift 2 ;;
    --connect-timeout|--max-time|-w|--write-out) shift 2 ;;
    --fail) f=1; shift ;;
    --insecure) k=1; shift ;;
    --*) shift ;;
    -*) case "$1" in *f*) f=1 ;; esac; case "$1" in *k*) k=1 ;; esac; shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $ip $url $all" >> /mnt/data/.calls
ans=$(awk -v ip="$ip" '$1 == ip { print $2; exit }' /mnt/data/.plan)
[ -n "$ans" ] || ans=dead
while read -r a b; do
  [ "$a" = MISS ] && case "$url" in *"$b"*) ans=404 ;; esac
done < /mnt/data/.plan
case "$ans" in
  dead) exit 7 ;;
  tls) [ "$k" = 1 ] || exit 60; ans=200 ;;
esac
if [ "$ans" -ge 400 ]; then
  [ "$f" = 1 ] && exit 22
  exit 0
fi
[ -n "$out" ] && [ "$out" != /dev/null ] && echo bundle > "$out"
exit 0
EOF
chmod +x "$STUBS"/*

fresh() {  # <case> <GA_OTA_IPS> — a case dir with its own ga-services.conf
  C="$WORK/case/$1"; rm -rf "$C" 2>/dev/null || sudo -n rm -rf "$C"
  mkdir -p "$C/data/tmp" "$C/run" "$C/etc"
  : > "$C/data/.calls"; : > "$C/data/.plan"
  # The baked file, with only the candidate list replaced: everything else
  # (host, probe path) is what ships.
  sed "s|^GA_OTA_IPS=.*|GA_OTA_IPS=\"$2\"|" "$BAKED_CONF" > "$C/etc/ga-services.conf"
}
plan() { printf '%s\n' "$@" > "$C/data/.plan"; }
pin() { printf '%s\n' "$1" > "$C/run/ga-resolve-ota.active"; }
active() { cat "$C/run/ga-resolve-ota.active" 2>/dev/null | tr -d '[:space:]'; }
calls() { cat "$C/data/.calls"; }
curls() { grep '^curl ' "$C/data/.calls"; }

# The sandbox's /etc is empty but for ga-services.conf, so the runner's own
# GA files (none expected) cannot leak in. Debian-family runners resolve awk
# through /etc/alternatives; carry that directory over when it exists.
ALT_BIND=""
[ -d /etc/alternatives ] && ALT_BIND="--ro-bind /etc/alternatives /etc/alternatives"

sbx() {  # <cmd...>
  # shellcheck disable=SC2086  # $BWRAP and $ALT_BIND must word-split
  timeout -k 5 60 $BWRAP --unshare-net --unshare-ipc --unshare-uts --unshare-pid --die-with-parent \
    --ro-bind / / --proc /proc --dev /dev \
    --tmpfs /mnt --bind "$C/data" /mnt/data --bind "$C/run" /run \
    --tmpfs /etc --ro-bind "$C/etc/ga-services.conf" /etc/ga-services.conf $ALT_BIND \
    --ro-bind "$STUBS" /mnt/.stubs --ro-bind "$EXT" /mnt/.ext --ro-bind "$IHOST" /mnt/.ihost \
    --setenv PATH "/mnt/.stubs:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}
resolve() { sbx sh /mnt/.ihost/usr/sbin/ga-resolve-ota > "$C/out" 2>&1; echo $? > "$C/rc"; }
run_installer() {
  sbx env GA_RESOLVE_OTA_BIN=/mnt/.ihost/usr/sbin/ga-resolve-ota \
    sh /mnt/.ext/usr/sbin/ga-rauc-install "$@" > "$C/out" 2>&1
  echo $? > "$C/rc"
}
out() { tr '\n' ';' < "$C/out"; }

# ── ga-resolve-ota ──────────────────────────────────────────────────────────
echo "--- ga-resolve-ota pins only an endpoint that serves the store ---"

fresh r-403 "$M1 $M2"
plan "$M1 403" "$M2 200"
resolve
ok "OTAF-10 a 403 is NOT reachable: the next mesh path is pinned" \
   "[ \"\$(active)\" = '$M2' ]" "pinned '$(active)' out: $(out)"

fresh r-404 "$M1 $M2"
plan "$M1 404" "$M2 200"
resolve
ok "OTAF-11 a 404 is NOT reachable: the next mesh path is pinned" \
   "[ \"\$(active)\" = '$M2' ]" "pinned '$(active)'"

fresh r-tls "$M1 $M2"
plan "$M1 tls" "$M2 200"
resolve
ok "OTAF-12 a certificate the download would reject is NOT reachable" \
   "[ \"\$(active)\" = '$M2' ]" "pinned '$(active)'"

fresh r-path "$M1"
plan "$M1 200"
resolve
ok "OTAF-13 the probe asks for the store's probe object through --resolve" \
   "curls | grep -qF 'curl $M1 https://$OTA_HOST$PROBE '" "calls: $(curls | tr '\n' ';')"
ok "OTAF-13b ... and uses --fail, never -k" \
   "curls | grep -qE -- '(^| )(-[a-zA-Z]*f[a-zA-Z]*|--fail)( |$)' && ! curls | grep -qE -- '(^| )(-[a-zA-Z]*k[a-zA-Z]*|--insecure)( |$)'" "calls: $(curls | tr '\n' ';')"

fresh r-public "$PUB $M1"
plan "$PUB 200" "$M1 200"
resolve
ok "OTAF-14 a non-mesh candidate (stale override) is skipped, the mesh path pinned" \
   "[ \"\$(active)\" = '$M1' ]" "pinned '$(active)'"
ok "OTAF-14b ... it is never even probed" "! curls | grep -q ' $PUB '"
ok "OTAF-14c ... and the skip is logged as an error" "grep -q 'ERROR.*$PUB' '$C/out'" "out: $(out)"

fresh r-none "$M1 $M2"
plan "$M1 403" "$M2 dead"
resolve
ok "OTAF-15 nothing serves: the first mesh entry is pinned, flagged as unverified at error level" \
   "[ \"\$(active)\" = '$M1' ] && grep -q 'ERROR.*unverified' '$C/out'" "pinned '$(active)' out: $(out)"

fresh r-onlypub "$PUB"
plan "$PUB 200"
resolve
ok "OTAF-16 no mesh candidate at all: nothing is pinned and the resolver fails" \
   "[ ! -e '$C/run/ga-resolve-ota.active' ] && [ \"\$(cat '$C/rc')\" != 0 ]" "rc=$(cat "$C/rc") pinned '$(active)'"

# ── ga-rauc-install ─────────────────────────────────────────────────────────
echo "--- ga-rauc-install downloads through the pin ---"

fresh i-pinned "$M1 $M2"
plan "$M2 200" "DNS 200"
pin "$M2"
run_installer 16.3.1.9 BOSv1.4.0-rc3
ok "OTAF-20 the bundle is downloaded with --resolve $OTA_HOST:443:<pin>" \
   "curls | grep -q '^curl $M2 https://$OTA_HOST/releases/16.3.1.9/BOSv1.4.0-rc3/haos_ihost-16.3.1.9.raucb .*--resolve $OTA_HOST:443:$M2'" "calls: $(curls | tr '\n' ';') out: $(out)"
ok "OTAF-20b ... no download goes through name resolution" \
   "curls >/dev/null && ! curls | grep -q '^curl DNS '" "calls: $(curls | tr '\n' ';')"
ok "OTAF-20c ... and the bundle is installed" "calls | grep -q '^rauc install '"
ok "OTAF-20d ... TLS verification stays on (no -k / --insecure)" \
   "! curls | grep -qE -- '(^| )(-[a-zA-Z]*k[a-zA-Z]*|--insecure)( |$)'"

fresh i-fallback "$M1"
plan "$M1 200" "DNS 200" "MISS /BOSv1.4.0-rc3/"
pin "$M1"
run_installer 16.3.1.9 BOSv1.4.0-rc3
ok "OTAF-21 the prod-slot fallback is pinned too" \
   "curls | grep -q '^curl $M1 https://$OTA_HOST/releases/16.3.1.9/haos_ihost-16.3.1.9.raucb ' && ! curls | grep -q '^curl DNS '" "calls: $(curls | tr '\n' ';')"

fresh i-nopin "$M1 $M2"
plan "$M1 403" "$M2 200" "DNS 200"
run_installer 16.3.1.9
ok "OTAF-22 no pin yet: the resolver runs once and the download uses its pick" \
   "[ \"\$(active)\" = '$M2' ] && curls | grep -q '^curl $M2 https://$OTA_HOST/releases/16.3.1.9/haos_ihost-16.3.1.9.raucb '" "pinned '$(active)' calls: $(curls | tr '\n' ';') out: $(out)"

fresh i-publicpin "$M1"
plan "$M1 200" "$PUB 200" "DNS 200"
pin "$PUB"
run_installer 16.3.1.9
ok "OTAF-23 a non-mesh pin is ignored: the resolver re-pins and nothing is fetched from it" \
   "! curls | grep -q '^curl $PUB ' && curls | grep -q '^curl $M1 https://$OTA_HOST/releases/'" "calls: $(curls | tr '\n' ';') out: $(out)"

fresh i-failclosed "$PUB"
plan "$PUB 200" "DNS 200"
run_installer 16.3.1.9
ok "OTAF-24 no mesh endpoint at all: fail closed — no download, no install, non-zero exit" \
   "! curls | grep -q 'releases/' && ! calls | grep -q '^rauc install' && [ \"\$(cat '$C/rc')\" != 0 ] && grep -q 'FATAL' '$C/out'" "rc=$(cat "$C/rc") calls: $(calls | tr '\n' ';') out: $(out)"

fresh i-deadpin "$M1"
plan "$M1 dead" "DNS 200"
pin "$M1"
run_installer 16.3.1.9
ok "OTAF-25 the pinned endpoint does not answer: fail, never retry through name resolution" \
   "! curls | grep -q '^curl DNS ' && ! calls | grep -q '^rauc install' && [ \"\$(cat '$C/rc')\" = 3 ]" "rc=$(cat "$C/rc") calls: $(curls | tr '\n' ';')"

echo ""
echo "ota_fetch: $pass passed, $fail failed"
# Assert coverage, not exit code.
[ $((pass + fail)) -ge 20 ] || { echo "FATAL: only $((pass + fail)) checks ran" >&2; exit 1; }
[ "$fail" = 0 ]
