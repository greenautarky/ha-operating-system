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
RESOLVER="$EXT/usr/sbin/ga-resolve-ota"
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
ip=DNS; out=""; url=""; f=0; k=0; all="$*"; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) cfg="$2"; shift 2 ;;
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
# A --config file is what carries the device identity: record its mode and
# content (the tokens in this suite are fakes) so a check can assert on them.
[ -n "$cfg" ] && echo "curlcfg $(stat -c %a "$cfg") $(tr '\n' '|' < "$cfg")" >> /mnt/data/.calls
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
  mkdir -p "$C/data/tmp" "$C/data/gm" "$C/run" "$C/etc"
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
    --setenv GA_SERVICES_CONF_LIB /mnt/.ext/usr/libexec/ga-services-conf.sh \
    --setenv GA_DATA_ROOT_LIB /mnt/.ext/usr/libexec/ga-data-root.sh \
    "$@"
}
resolve() { sbx sh /mnt/.ext/usr/sbin/ga-resolve-ota > "$C/out" 2>&1; echo $? > "$C/rc"; }
run_installer() {
  sbx env GA_GM_DATA_DIR=/mnt/data/gm $INSTENV GA_RESOLVE_OTA_BIN=/mnt/.ext/usr/sbin/ga-resolve-ota \
    sh /mnt/.ext/usr/sbin/ga-rauc-install "$@" > "$C/out" 2>&1
  echo $? > "$C/rc"
}
INSTENV=""
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

# ── device identity (OTA hardening stage 1, Odoo #2160) ─────────────────────
# The installer SENDS the device's fleet-manager token + id when it has them,
# and downloads anonymously (loudly) when it has not. The store is open in
# stage 1, so "no identity" must never stop an update: that is the lockout
# guard this block pins. Expected header lines are pinned constants.
echo "--- ga-rauc-install sends a device identity, and works without one ---"
TOK=Zq3Xr8Lm0Pw5Yt2Uv7Nb4Hc9Kd1Je6Gs
ID=KIB-SON-00000017
# What yaml.safe_dump(sort_keys=True) writes: other blocks carry decoy
# `token:` / `device_id:` keys on either side of the fleet block.
write_creds() {  # <token-line-value> — a v2 bundle with that fleet token
  cat > "$C/data/gm/ga-fleet-credentials.yaml" <<YAML
aaa:
  device_id: DECOY-ID-BEFORE
  token: DECOY-TOKEN-BEFORE-0123456789
device_id: $ID
fleet:
  token: $1
  url: https://fleet.example.invalid
mqtt:
  password: pw
  token: DECOY-TOKEN-AFTER-0123456789
version: 2
YAML
}
cfgs() { grep '^curlcfg ' "$C/data/.calls"; }
idents_left() { ls "$C"/run/ga-rauc-install-ident.* 2>/dev/null; }

fresh id-ok "$M1"
plan "$M1 200" "DNS 200"; pin "$M1"; write_creds "$TOK"
run_installer 16.3.1.9 BOSv1.4.0-rc3
ok "OTAF-30 a device with a fleet token sends it as a Bearer header + its id" \
   "cfgs | grep -qF 'header = \"Authorization: Bearer $TOK\"|header = \"X-GA-Device-Id: $ID\"|'" "cfgs: $(cfgs) out: $(out)"
ok "OTAF-30b ... the identity file is mode 600" "cfgs | grep -q '^curlcfg 600 '" "cfgs: $(cfgs)"
ok "OTAF-30c ... the token is NOT on the curl command line (ps would show it)" \
   "! curls | grep -qF '$TOK' && ! grep -qF '$TOK' '$C/out'" "calls: $(curls | tr '\n' ';')"
ok "OTAF-30d ... the identity file is gone once the installer exits" "[ -z \"\$(idents_left)\" ]" "left: $(idents_left)"
ok "OTAF-30e ... the bundle is still downloaded and installed" \
   "curls | grep -q 'releases/16.3.1.9/BOSv1.4.0-rc3/haos_ihost-16.3.1.9.raucb' && calls | grep -q '^rauc install '" "out: $(out)"
ok "OTAF-30f ... the decoy token/id of other blocks are not used" \
   "! cfgs | grep -q DECOY"

fresh id-fallback "$M1"
plan "$M1 200" "DNS 200" "MISS /BOSv1.4.0-rc3/"; pin "$M1"; write_creds "$TOK"
run_installer 16.3.1.9 BOSv1.4.0-rc3
ok "OTAF-31 the prod-slot fallback download carries the identity too" \
   "[ \$(cfgs | wc -l) -eq 2 ] && curls | tail -1 | grep -q 'releases/16.3.1.9/haos_ihost-16.3.1.9.raucb'" "cfgs: $(cfgs)"

fresh id-quoted "$M1"
plan "$M1 200"; pin "$M1"; write_creds "'$TOK'"
run_installer 16.3.1.9
ok "OTAF-32 a quoted yaml scalar is unquoted" \
   "cfgs | grep -qF 'Bearer $TOK\"|'" "cfgs: $(cfgs)"

# ---- the lockout guard: no identity must still download in stage 1 ----
fresh id-none "$M1"
plan "$M1 200"; pin "$M1"
run_installer 16.3.1.9 BOSv1.4.0-rc3
ok "OTAF-40 STAGE-1 NO-LOCKOUT: no credentials file -> the bundle is still downloaded + installed, rc 0" \
   "[ \"\$(cat '$C/rc')\" = 0 ] && calls | grep -q '^rauc install ' && curls | grep -q 'releases/'" "rc=$(cat "$C/rc") out: $(out)"
ok "OTAF-40b ... sent without any identity header" "! cfgs | grep -q . && ! curls | grep -qi 'authorization'"
ok "OTAF-40c ... and the anonymous download is announced at WARNING level" "grep -q 'WARNING: no device identity' '$C/out'" "out: $(out)"

fresh id-v1 "$M1"
plan "$M1 200"; pin "$M1"
printf 'device_id: %s\nmqtt:\n  password: pw\nversion: 1\n' "$ID" > "$C/data/gm/ga-fleet-credentials.yaml"
run_installer 16.3.1.9
ok "OTAF-41 a v1 bundle without a fleet block: downloads anonymously, installs, warns" \
   "[ \"\$(cat '$C/rc')\" = 0 ] && ! cfgs | grep -q . && calls | grep -q '^rauc install ' && grep -q 'WARNING: no device identity' '$C/out'" "out: $(out)"

for bad in "short" "has space in it 0123456789" 'a;b;c;0123456789abcdefghijk' '$(reboot)0123456789abcdefghij'; do
  fresh id-bad "$M1"
  plan "$M1 200"; pin "$M1"; write_creds "$bad"
  run_installer 16.3.1.9
  ok "OTAF-42 a malformed token ('$bad') is never sent: anonymous, installs, warns" \
     "[ \"\$(cat '$C/rc')\" = 0 ] && ! cfgs | grep -q . && calls | grep -q '^rauc install ' && grep -q 'WARNING: no device identity' '$C/out'" "out: $(out)"
done

fresh id-link "$M1"
plan "$M1 200"; pin "$M1"; write_creds "$TOK"
mv "$C/data/gm/ga-fleet-credentials.yaml" "$C/data/real-creds"
ln -s /mnt/data/real-creds "$C/data/gm/ga-fleet-credentials.yaml"
run_installer 16.3.1.9
ok "OTAF-43 a symlinked credentials file is not followed: anonymous, installs, warns" \
   "[ \"\$(cat '$C/rc')\" = 0 ] && ! cfgs | grep -q . && calls | grep -q '^rauc install '" "out: $(out)"

fresh id-dead "$M1"
plan "$M1 dead"; pin "$M1"; write_creds "$TOK"
run_installer 16.3.1.9
ok "OTAF-44 a failed download still leaves no identity file behind" \
   "[ \"\$(cat '$C/rc')\" = 3 ] && [ -z \"\$(idents_left)\" ]" "rc=$(cat "$C/rc") left: $(idents_left)"

echo ""
echo "ota_fetch: $pass passed, $fail failed"
# Assert coverage, not exit code.
[ $((pass + fail)) -ge 36 ] || { echo "FATAL: only $((pass + fail)) checks ran" >&2; exit 1; }
[ "$fail" = 0 ]
