#!/bin/sh
# Second-slot mirror suite (Odoo #1750): /usr/sbin/ga-rauc-mirror-slot.
#
# The LIVE helper runs against stateful stubs of rauc, curl, busctl and systemctl
# (the system boundary: no rauc on a CI host). The rauc stub models what the RAUC
# 1.13 source says: mark-bad removes a slot from BOOT_ORDER, mark-good does NOT
# re-add it, mark-active puts a slot first, write-slot is a raw partition write
# with no hooks and no bootloader change, extract writes the images.
#
# must-skip : soak, uptime, 1.5, other slot already on the same line / unreadable,
#             booted not good, armed switch, no activation record, clock,
#             RAUC busy, ga-rauc-install running, a second run (flock)
# must-run  : 1.6 final, rc, other direction, lower-line other slot
# must-fail : download/space, wrong bundle release, manifest hash mismatch,
#             digest mismatch, write failure, wrong read-back, mark failures,
#             boot primary not restored (exit 6), retry of mark-active booted,
#             unreadable release/status/busctl, bad request, signal
# also      : units, no SPL/boot rewrite (no `rauc install`), result-symlink,
#             URL shape in step with ga-rauc-install, fluent-bit alert filters,
#             and mutants of the LIVE helper that each turn their guard red.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "RAUC second-slot mirror"

REPO="$SCRIPT_DIR/../../.."
OVL="$REPO/buildroot-external/rootfs-overlay"
HELPER="${GA_MIRROR_HELPER:-$OVL/usr/sbin/ga-rauc-mirror-slot}"
INSTALL="$OVL/usr/sbin/ga-rauc-install"
UNITS="$OVL/usr/lib/systemd/system"

if ! command -v jq >/dev/null 2>&1 || ! date -u -d @0 +%s >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
  skip_test "MIR-*" "second-slot mirror" "jq, GNU date and flock needed for the fixtures"
  suite_end
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NOW=1794000000                      # fixed clock
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# images the "bundle" contains
printf 'KERNEL-1.6' > "$WORK/kernel.img"; printf 'ROOTFS-1.6-data' > "$WORK/rootfs.img"
K_DIG="$(sha "$WORK/kernel.img")"; R_DIG="$(sha "$WORK/rootfs.img")"
K_SZ="$(wc -c < "$WORK/kernel.img" | tr -d ' ')"; R_SZ="$(wc -c < "$WORK/rootfs.img" | tr -d ' ')"

# --- stubs ------------------------------------------------------------------
# State lives in $S/state.env (our own code). Every call is appended to $S/calls.
cat > "$WORK/rauc" <<'STUB'
#!/bin/sh
S="$STUB_DIR"
. "$S/state.env"
echo "$*" >> "$S/calls"
setst() { sed -i "/^$1=/d" "$S/state.env"; printf "%s='%s'\n" "$1" "$2" >> "$S/state.env"; }
kname() { [ "$1" = A ] && echo kernel.0 || echo kernel.1; }
first() { echo "${ORDER%% *}"; }
slot() { # idx class name boot_status parent ver hash inst act status
  printf "RAUC_SLOT_STATE_%s='inactive'\nRAUC_SLOT_CLASS_%s='%s'\nRAUC_SLOT_DEVICE_%s='/dev/disk/by-partlabel/%s'\nRAUC_SLOT_TYPE_%s='raw'\nRAUC_SLOT_BOOTNAME_%s='%s'\nRAUC_SLOT_PARENT_%s='%s'\nRAUC_SLOT_BOOT_STATUS_%s='%s'\n" \
    "$1" "$1" "$2" "$1" "$PART" "$1" "$1" "$3" "$1" "$5" "$1" "$4"
  [ -n "$6" ] && printf "RAUC_SLOT_STATUS_BUNDLE_VERSION_%s='%s'\n" "$1" "$6"
  [ -n "$7" ] && printf "RAUC_SLOT_STATUS_BUNDLE_HASH_%s='%s'\n" "$1" "$7"
  [ -n "${10}" ] && printf "RAUC_SLOT_STATUS_STATUS_%s='%s'\n" "$1" "${10}"
  [ -n "$8" ] && printf "RAUC_SLOT_STATUS_INSTALLED_TIMESTAMP_%s='%s'\n" "$1" "$8"
  [ -n "$9" ] && printf "RAUC_SLOT_STATUS_ACTIVATED_TIMESTAMP_%s='%s'\n" "$1" "$9"
  return 0
}
case "$1 $2" in
  "status --detailed")
    [ -z "$STATUS_FAIL" ] || exit 1
    P="$(first)"
    # PRIMARY_LIE: a bootloader that does not take the write (readback must catch it)
    [ -z "$PRIMARY_LIE" ] || [ ! -f "$S/mark_active_n" ] || P="$PRIMARY_LIE"
    printf "RAUC_SYSTEM_COMPATIBLE='haos-ihost'\nRAUC_SYSTEM_BOOTED_BOOTNAME='%s'\nRAUC_BOOT_PRIMARY='%s'\n" "$BOOTED" "$(kname "$P")"
    echo "RAUC_SYSTEM_SLOTS='boot.0 kernel.0 rootfs.0 kernel.1 rootfs.1'"
    echo "RAUC_SLOTS='1 2 3 4 5'"
    echo "RAUC_SLOT_STATE_1='inactive'"; echo "RAUC_SLOT_CLASS_1='boot'"
    PART=hassos-kernel0 slot 2 kernel A "$A_BS" "" "" "" "" "$A_ACT" ""
    PART=hassos-system0 slot 3 rootfs "" "" kernel.0 "$A_VER" "$A_HASH" "$A_INST" "" "$A_STATUS"
    PART=hassos-kernel1 slot 4 kernel B "$B_BS" "" "" "" "" "$B_ACT" ""
    PART=hassos-system1 slot 5 rootfs "" "" kernel.1 "$B_VER" "$B_HASH" "$B_INST" "" "$B_STATUS"
    ;;
  "info --output-format=shell")
    [ -z "$INFO_FAIL" ] || exit 1
    [ -z "$BUNDLE_REL" ] || echo "RAUC_META_GA_RELEASE='$BUNDLE_REL'"
    echo "RAUC_MF_HASH='$MF_HASH'"
    echo "RAUC_MF_IMAGES=4"
    echo "RAUC_IMAGE_CLASS_0='boot'"; echo "RAUC_IMAGE_DIGEST_0='bootdigest'"; echo "RAUC_IMAGE_SIZE_0=16"
    echo "RAUC_IMAGE_CLASS_1='kernel'"; echo "RAUC_IMAGE_DIGEST_1='$K_DIG_M'"; echo "RAUC_IMAGE_SIZE_1=$K_SZ"
    echo "RAUC_IMAGE_CLASS_2='rootfs'"; echo "RAUC_IMAGE_DIGEST_2='$R_DIG_M'"; echo "RAUC_IMAGE_SIZE_2=$R_SZ"
    echo "RAUC_IMAGE_CLASS_3='spl'"; echo "RAUC_IMAGE_DIGEST_3='spldigest'"; echo "RAUC_IMAGE_SIZE_3=16"
    ;;
  "extract "*)
    [ -z "$EXTRACT_FAIL" ] || exit 1
    mkdir "$3" || exit 1
    cp "$IMG_DIR/kernel.img" "$3/kernel.img"; cp "$IMG_DIR/rootfs.img" "$3/rootfs.img"
    [ -z "$EXTRACT_CORRUPT" ] || printf 'X' >> "$3/rootfs.img"
    ;;
  "install "*)
    echo "RAUC INSTALL MUST NEVER BE CALLED (rewrites SPL + shared boot)" >&2; exit 99 ;;
  "write-slot "*)
    [ -n "$WRITE_SLEEP" ] && sleep "$WRITE_SLEEP"
    [ "$ORDER_AT_WRITE_CHECK" = 1 ] && echo "order-at-write: $ORDER bs_other: $A_BS/$B_BS" >> "$S/calls"
    case "$2" in kernel*) [ -z "$WRITE_FAIL_KERNEL" ] || exit 1 ;; *) [ -z "$WRITE_FAIL_ROOTFS" ] || exit 1 ;; esac
    case "$2" in
      kernel.0) dev=hassos-kernel0 ;; kernel.1) dev=hassos-kernel1 ;;
      rootfs.0) dev=hassos-system0 ;; rootfs.1) dev=hassos-system1 ;;
      *) exit 1 ;;
    esac
    cp "$3" "$DEVROOT/$dev"
    [ -z "$WRITE_CORRUPT" ] || printf 'Z' | dd of="$DEVROOT/$dev" bs=1 seek=2 conv=notrunc 2>/dev/null
    ;;
  "status mark-bad")
    [ -z "$MARKBAD_FAIL" ] || exit 1
    k="$3"; case "$k" in kernel.0) b=A ;; kernel.1) b=B ;; *) exit 1 ;; esac
    setst "${b}_BS" bad; setst ORDER "$(echo "$ORDER" | tr ' ' '\n' | grep -v "^$b\$" | tr '\n' ' ' | sed 's/ $//')"
    ;;
  "status mark-good")
    [ -z "$MARKGOOD_FAIL" ] || exit 1
    k="$3"; case "$k" in kernel.0) b=A ;; kernel.1) b=B ;; *) exit 1 ;; esac
    setst "${b}_BS" good      # NB: does not touch ORDER (bootchooser.c)
    ;;
  "status mark-active")
    n=$(cat "$S/mark_active_n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$S/mark_active_n"
    case "$3" in
      booted) b="$BOOTED"
              [ -z "$BOOTED_MARK_FAILS" ] || { [ "$n" -le "$BOOTED_MARK_FAILS" ] && exit 1; }
              [ -z "$BOOTED_MARK_NEVER" ] || exit 1 ;;
      kernel.0) b=A; [ -z "$OTHER_MARK_FAIL" ] || exit 1; SLEEP_AFTER="$OTHER_MARK_SLEEP" ;;
      kernel.1) b=B; [ -z "$OTHER_MARK_FAIL" ] || exit 1; SLEEP_AFTER="$OTHER_MARK_SLEEP" ;;
      *) exit 1 ;;
    esac
    setst ORDER "$b $(echo "$ORDER" | tr ' ' '\n' | grep -v "^$b\$" | tr '\n' ' ' | sed 's/ $//')"
    [ -z "$SLEEP_AFTER" ] || sleep "$SLEEP_AFTER"
    ;;
  *) exit 64 ;;
esac
STUB
chmod +x "$WORK/rauc"

cat > "$WORK/curl" <<'STUB'
#!/bin/sh
S="$STUB_DIR"; . "$S/state.env"
ALL_ARGS="$*"; out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in --output) out="$2"; shift 2 ;; --resolve|--connect-timeout|--max-time|--speed-limit|--speed-time) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "$url" >> "$S/curl_urls"
echo "$ALL_ARGS" > "$S/curl_flags"
[ -z "$CURL_FAIL" ] || exit 22
if [ -n "$CURL_FAIL_PRIMARY" ] && [ "$(wc -l < "$S/curl_urls")" -eq 1 ]; then exit 22; fi
echo bundle > "$out"
# things that happen WHILE the bundle downloads (up to 15 min on a slow uplink)
setst() { sed -i "/^$1=/d" "$S/state.env"; printf "%s='%s'\n" "$1" "$2" >> "$S/state.env"; }
[ -z "$CURL_SET_ORDER" ] || setst ORDER "$CURL_SET_ORDER"
[ -z "$CURL_SET_OP" ] || setst OPERATION "$CURL_SET_OP"
[ -z "$CURL_SET_UNIT" ] || setst INSTALL_UNIT_STATE "$CURL_SET_UNIT"
[ -z "$CURL_SET_BOOTED" ] || setst BOOTED "$CURL_SET_BOOTED"
[ -z "$CURL_SET_B_BS" ] || setst B_BS "$CURL_SET_B_BS"
if [ "$CURL_SET_OTHER_REL" = GONE ]; then rm -f "$OTHER_REL_FILE"; elif [ -n "$CURL_SET_OTHER_REL" ]; then echo "$CURL_SET_OTHER_REL" > "$OTHER_REL_FILE"; fi
STUB
chmod +x "$WORK/curl"
cat > "$WORK/mount" <<'STUB'
#!/bin/sh
# mount -o ro <dev> <dir>: "mounts" the case's other-slot tree
. "$STUB_DIR/state.env"
echo "mount $*" >> "$STUB_DIR/mounts"
n=$(grep -c '^mount' "$STUB_DIR/mounts")
[ -z "$MOUNT_FAIL" ] || exit 32
[ -z "$MOUNT_FAIL_NTH" ] || { [ "$n" -eq "$MOUNT_FAIL_NTH" ] && exit 32; }
mkdir -p "$4/etc"; cp "$OTHER_REL_FILE" "$4/etc/ga-release" 2>/dev/null
STUB
cat > "$WORK/umount" <<'STUB'
#!/bin/sh
echo "umount $*" >> "$STUB_DIR/mounts"
rm -rf "$1/etc"
STUB
chmod +x "$WORK/mount" "$WORK/umount"

cat > "$WORK/busctl" <<'STUB'
#!/bin/sh
. "$STUB_DIR/state.env"
[ -z "$BUSCTL_FAIL" ] || exit 1
echo "s \"${OPERATION:-idle}\""
STUB
chmod +x "$WORK/busctl"
cat > "$WORK/systemctl" <<'STUB'
#!/bin/sh
. "$STUB_DIR/state.env"
echo "${INSTALL_UNIT_STATE:-inactive}"
STUB
chmod +x "$WORK/systemctl"

# rts: run_test_show, but a mutant run (GA_MIRROR_ONLY=<id>) runs just its one test
rts() { if [ -n "${GA_MIRROR_ONLY:-}" ] && [ "$1" != "$GA_MIRROR_ONLY" ]; then return 0; fi; run_test_show "$@"; }

# new_case <name> — a healthy device that SHOULD run the mirror: booted B on 1.6
# (activated 30 h ago, up 5 h), slot A holds 1.5.
new_case() {
  C="$WORK/$1"; rm -rf "$C"
  mkdir -p "$C/root/etc" "$C/root/run" "$C/root/mnt/data/tmp" "$C/gm" "$C/dev" "$C/other/etc" "$C/imgs"
  CASE="$C"
  echo "BOSv1.6.0" > "$C/root/etc/ga-release"
  echo "BOSv1.5.3" > "$C/other/etc/ga-release"
  printf 'ID=haos\nVARIANT_ID="ihost"\n' > "$C/root/etc/os-release"
  cp "$WORK/kernel.img" "$WORK/rootfs.img" "$C/imgs/"
  printf 'OLD15-KERNEL' > "$C/dev/hassos-kernel0"; printf 'OLD15-ROOTFS' > "$C/dev/hassos-system0"
  printf 'NEW16-KERNEL' > "$C/dev/hassos-kernel1"; printf 'NEW16-ROOTFS' > "$C/dev/hassos-system1"
  printf "%s.%s.1.5\n" 100 100 > "$C/ota.active"   # a mesh-range address, assembled so no literal sits in the repo
  printf '#!/bin/sh\nexit 0\n' > "$C/resolve"; chmod +x "$C/resolve"
  cat > "$C/state.env" <<EOF
BOOTED='B'
ORDER='B A'
A_BS='good'
B_BS='good'
A_VER='16.3.1.9'
A_HASH='hashOLD15'
A_STATUS='ok'
A_INST='2026-10-01T10:00:00Z'
A_ACT='2026-10-01T10:01:00Z'
B_VER='16.3.1.10'
B_HASH='hashNEW16'
B_STATUS='ok'
B_INST="$(iso $((NOW - 31 * 3600)))"
B_ACT="$(iso $((NOW - 30 * 3600)))"
BUNDLE_REL='BOSv1.6.0'
MF_HASH='hashNEW16'
K_DIG_M='$K_DIG'
R_DIG_M='$R_DIG'
K_SZ='$K_SZ'
R_SZ='$R_SZ'
IMG_DIR='$C/imgs'
DEVROOT='$C/dev'
OTHER_REL_FILE='$C/other/etc/ga-release'
EOF
  : > "$C/mounts"
  : > "$C/calls"; : > "$C/curl_urls"
}
setv() { sed -i "/^$1=/d" "$CASE/state.env"; printf "%s='%s'\n" "$1" "$2" >> "$CASE/state.env"; }

# run_helper [request-id] -> sets RC, files under $CASE
run_helper() {
  printf '%s' "${1-req1}" > "$CASE/gm/ga-rauc-mirror-request"
  STUB_DIR="$CASE" GA_RAUC_BIN="$WORK/rauc" GA_CURL_BIN="$WORK/curl" \
  GA_BUSCTL_BIN="$WORK/busctl" GA_SYSTEMCTL_BIN="$WORK/systemctl" \
  GA_GM_DATA_DIR="$CASE/gm" GA_MIRROR_ROOT="$CASE/root" GA_MIRROR_NOW="${NOW_OVERRIDE:-$NOW}" \
  GA_MIRROR_UPTIME_S="${UPTIME_OVERRIDE:-18000}" GA_MIRROR_MIN_FREE_KB="${FREE_OVERRIDE:-0}" \
  GA_MIRROR_DEVROOT="$CASE/dev" GA_MIRROR_OTHER_ROOT="${OTHER_ROOT_OVERRIDE-$CASE/other}" \
  GA_MOUNT_BIN="$WORK/mount" GA_UMOUNT_BIN="$WORK/umount" GA_MIRROR_WRITTEN_RECORD="$CASE/written.json" \
  GA_RESOLVE_OTA_BIN="$CASE/resolve" GA_OTA_ACTIVE_FILE="$CASE/ota.active" \
    sh "$HELPER" > "$CASE/out" 2>&1
  RC=$?
}
res() { jq -r ".$1" "$CASE/gm/ga-rauc-mirror-result.json"; }
ncalls() { grep -c "^$1" "$CASE/calls" || true; }
order() { ( . "$CASE/state.env"; echo "$ORDER" ); }
dev() { cat "$CASE/dev/$1"; }

# must_skip <reason fragment>: ran, did nothing, said why
must_skip() {
  [ "$RC" -eq 0 ] || { echo "rc=$RC: $(cat "$CASE/out")"; return 1; }
  [ "$(res status)" = skipped ] || { echo "status=$(res status): $(res reason)"; return 1; }
  res reason | grep -q -- "$1" || { echo "reason '$(res reason)' lacks '$1'"; return 1; }
  [ "$(ncalls write-slot)" -eq 0 ] && [ "$(ncalls status\ mark-)" -eq 0 ] || { echo "touched the slot"; return 1; }
  [ ! -s "$CASE/curl_urls" ] || { echo "downloaded"; return 1; }
  [ ! -e "$CASE/gm/ga-rauc-mirror-request" ] || { echo "request not consumed"; return 1; }
}
must_fail() { # <rc> <reason fragment>
  [ "$RC" -eq "$1" ] || { echo "rc=$RC (want $1): $(cat "$CASE/out")"; return 1; }
  [ "$(res status)" = failed ] || { echo "status=$(res status)"; return 1; }
  res reason | grep -q -- "$2" || { echo "reason '$(res reason)' lacks '$2'"; return 1; }
}

t_run_ok() {
  new_case m01; run_helper
  [ "$RC" -eq 0 ] && [ "$(res status)" = done ] || { echo "rc=$RC $(cat "$CASE/out")"; return 1; }
  [ "$(ncalls install)" -eq 0 ] || { echo "rauc install was called"; return 1; }
  [ "$(ncalls write-slot)" -eq 2 ] || { echo "write-slot count $(ncalls write-slot)"; return 1; }
  # only the OTHER slot's partitions are written, with the bundle's images
  [ "$(dev hassos-kernel0)" = "KERNEL-1.6" ] && [ "$(dev hassos-system0)" = "ROOTFS-1.6-data" ] || { echo "slot A not written"; return 1; }
  [ "$(dev hassos-kernel1)" = "NEW16-KERNEL" ] && [ "$(dev hassos-system1)" = "NEW16-ROOTFS" ] || { echo "booted slot touched"; return 1; }
  # order: other out of BOOT_ORDER before the write, then back, booted first
  _bad="$(grep -n '^status mark-bad' "$CASE/calls" | head -1 | cut -d: -f1)"
  _w="$(grep -n '^write-slot' "$CASE/calls" | head -1 | cut -d: -f1)"
  _good="$(grep -n '^status mark-good' "$CASE/calls" | head -1 | cut -d: -f1)"
  [ -n "$_bad" ] && [ "$_bad" -lt "$_w" ] && [ "$_w" -lt "$_good" ] || { echo "order of calls wrong"; return 1; }
  [ "$(order)" = "B A" ] || { echo "BOOT_ORDER '$(order)' (want 'B A': booted first, other present)"; return 1; }
  [ "$(res request_id)" = req1 ] && [ "$(res other)" = A ] && [ "$(res booted)" = B ] || return 1
  grep -q 'releases/16.3.1.10/BOSv1.6.0/haos_ihost-16.3.1.10.raucb' "$CASE/curl_urls" || { echo "url: $(cat "$CASE/curl_urls")"; return 1; }
  [ -z "$(ls "$CASE/root/mnt/data/tmp")" ] || { echo "work dir left behind: $(ls "$CASE/root/mnt/data/tmp")"; return 1; }
}
t_never_install() { grep -v '^[[:space:]]*#' "$HELPER" | grep -qE '(\$RAUC|rauc)" install|rauc install' && return 1; return 0; }
t_other_out_of_order_during_write() {
  new_case m01b; setv ORDER_AT_WRITE_CHECK 1; run_helper
  [ "$(res status)" = done ] || return 1
  grep -q '^order-at-write: B bs_other: bad/good' "$CASE/calls" || { grep '^order-at-write' "$CASE/calls"; return 1; }
}
t_rc_runs() { new_case m03; echo BOSv1.6.0-rc1 > "$CASE/root/etc/ga-release"; setv BUNDLE_REL BOSv1.6.0-rc1; run_helper; [ "$RC" -eq 0 ] && [ "$(res status)" = done ]; }
t_other_direction() {
  new_case m24
  setv BOOTED A; setv ORDER "A B"
  setv A_HASH hashNEW16; setv A_VER 16.3.1.10; setv A_ACT "$(iso $((NOW - 30 * 3600)))"; setv A_INST "$(iso $((NOW - 31 * 3600)))"
  setv B_HASH hashOLD15; setv B_VER 16.3.1.9; setv B_ACT "2026-10-01T10:01:00Z"
  run_helper
  [ "$(res status)" = done ] && [ "$(res other)" = B ] && [ "$(order)" = "A B" ] || { echo "$(cat "$CASE/out")"; return 1; }
  [ "$(dev hassos-kernel1)" = "KERNEL-1.6" ] && [ "$(dev hassos-kernel0)" = "OLD15-KERNEL" ]
}
t_idempotent() {
  # after a successful mirror the other slot reads 1.6: the second request is a no-op
  new_case m02; run_helper; [ "$(res status)" = done ] || return 1
  echo BOSv1.6.0 > "$CASE/other/etc/ga-release"
  : > "$CASE/calls"; : > "$CASE/curl_urls"
  run_helper req2
  must_skip "same line"
}
t_same_line() { new_case m09; echo BOSv1.6.0-rc9 > "$CASE/other/etc/ga-release"; run_helper; must_skip "same line"; }
t_same_line_newer_patch() { new_case m09b; echo BOSv1.6.3 > "$CASE/other/etc/ga-release"; run_helper; must_skip "same line"; }
t_other_newer() { new_case m09c; echo BOSv1.7.0 > "$CASE/other/etc/ga-release"; run_helper; must_skip "same line"; }
t_other_unreadable() { new_case m09d; rm "$CASE/other/etc/ga-release"; run_helper; must_skip "other slot unreadable"; }
t_other_garbage() { new_case m09e; echo garbage > "$CASE/other/etc/ga-release"; run_helper; must_skip "other slot unreadable"; }
t_other_older_major() { new_case m09f; echo BOSv1.4.0 > "$CASE/other/etc/ga-release"; run_helper; [ "$(res status)" = done ]; }
t_soak() { new_case m05; setv B_ACT "$(iso $((NOW - 2 * 3600)))"; run_helper; must_skip "soak not reached"; }
t_soak_edge() { new_case m06; setv B_ACT "$(iso $((NOW - 86399)))"; run_helper; must_skip "soak not reached"; }
t_soak_exact() { new_case m06b; setv B_ACT "$(iso $((NOW - 86400)))"; run_helper; [ "$(res status)" = done ]; }
t_uptime() { new_case m07; UPTIME_OVERRIDE=1200 run_helper; must_skip "uptime"; }
t_15() { new_case m08; echo BOSv1.5.3 > "$CASE/root/etc/ga-release"; run_helper; must_skip "below BOSv1.6"; }
t_15rc() { new_case m08b; echo BOSv1.5.3-rc2 > "$CASE/root/etc/ga-release"; run_helper; must_skip "below BOSv1.6"; }
t_notgood() { new_case m10; setv B_BS bad; run_helper; must_skip "not marked good"; }
t_primary() { new_case m11; setv ORDER "A B"; run_helper; must_skip "switch is armed"; }
t_noact() { new_case m12; setv B_ACT ""; run_helper; must_skip "no activation record"; }
t_clock() { new_case m13; NOW_OVERRIDE=$((NOW - 40 * 3600)) run_helper; must_skip "clock"; }
# --- the re-check after the download (reviewer PoC: an OTA finishing meanwhile) ---
t_recheck_skip() { # <skip fragment>: downloaded, but nothing written, no bootloader change
  [ "$RC" -eq 0 ] && [ "$(res status)" = skipped ] || { echo "rc=$RC status=$(res status): $(cat "$CASE/out")"; return 1; }
  res reason | grep -q -- "$1" || { echo "reason '$(res reason)' lacks '$1'"; return 1; }
  [ -s "$CASE/curl_urls" ] || { echo "the download did not happen: the case proves nothing"; return 1; }
  [ "$(ncalls write-slot)" -eq 0 ] && [ "$(ncalls 'status mark-')" -eq 0 ] || { echo "the slot was touched"; return 1; }
}
t_recheck_primary() {
  new_case m40; setv CURL_SET_ORDER "A B"; run_helper
  t_recheck_skip "boot primary is now" || return 1
  [ "$(order)" = "A B" ] || { echo "the finished OTA's BOOT_ORDER was changed: '$(order)'"; return 1; }
  [ "$(dev hassos-kernel0)" = "OLD15-KERNEL" ] || { echo "slot A (freshly installed by the OTA) was overwritten"; return 1; }
}
t_recheck_busy() { new_case m41; setv CURL_SET_OP installing; run_helper; t_recheck_skip "RAUC is busy at the re-check"; }
t_recheck_unit() { new_case m42; setv CURL_SET_UNIT activating; run_helper; t_recheck_skip "started an install during the download"; }
t_recheck_booted_changed() { new_case m49; setv CURL_SET_BOOTED A; run_helper; t_recheck_skip "booted slot changed during the download"; }
t_recheck_booted_bad() { new_case m49b; setv CURL_SET_B_BS bad; run_helper; t_recheck_skip "no longer good"; }
t_recheck_other_same_line() { new_case m43; setv CURL_SET_OTHER_REL BOSv1.6.0; run_helper; t_recheck_skip "same line"; }
t_recheck_other_gone() { new_case m43b; setv CURL_SET_OTHER_REL GONE; run_helper; [ "$(res status)" = skipped ] && res reason | grep -q "unreadable" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_install_untouched() {
  # the normal OTA path stays free of anything this feature added: no slot lock,
  # no flock, no mention of the mirror in ga-rauc-install
  ! grep -q -e 'slot-write' -e 'flock' -e 'mirror' "$INSTALL" || { echo "ga-rauc-install carries mirror/lock code"; return 1; }
  ! grep -q 'slot-write' "$HELPER" || { echo "the helper still refers to a shared slot lock"; return 1; }
}
# the journal dump and the other-slot read come BEFORE the decisive checks, so only
# mark-bad follows directly after them
t_window_order() {
  _j="$(grep -n 'ga-journal-dump rauc-mirror-slot' "$HELPER" | tail -1 | cut -d: -f1)"
  _o="$(grep -n '^other_release; OTHER_REL2=' "$HELPER" | cut -d: -f1)"
  _s="$(grep -n 'STATUS="$(read_status)" || STATUS=""' "$HELPER" | awk -F: -v j="$_j" '$1 > j {print $1; exit}')"
  _b="$(grep -n 'OP="$("$BUSCTL"' "$HELPER" | tail -1 | cut -d: -f1)"
  _m="$(grep -n 'status mark-bad' "$HELPER" | grep -v '^[0-9]*:#' | tail -1 | cut -d: -f1)"
  [ -n "$_j" ] && [ -n "$_o" ] && [ -n "$_s" ] && [ -n "$_b" ] && [ -n "$_m" ] || { echo "markers missing: $_j $_o $_s $_b $_m"; return 1; }
  [ "$_j" -lt "$_s" ] && [ "$_o" -lt "$_s" ] && [ "$_s" -lt "$_b" ] && [ "$_b" -lt "$_m" ] || { echo "order wrong: journal $_j other $_o status $_s busctl $_b mark-bad $_m"; return 1; }
  # between the Operation read and mark-bad: only the busy verdict and the log line
  _n="$(sed -n "$((_b + 1)),$((_m - 1))p" "$HELPER" | grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' -e '^\[ "\$OP" = ' -e '^|| fail 7' -e '^    || fail 7' -e '^log "writing' | wc -l)"
  [ "$_n" -le 1 ] || { echo "$_n extra statements between the busctl re-check and mark-bad"; return 1; }
}
# --- the other slot's rootfs is mounted (not the test hook) ---
t_mount_ok() {
  new_case m45; OTHER_ROOT_OVERRIDE= run_helper
  [ "$(res status)" = done ] || { echo "$(cat "$CASE/out")"; return 1; }
  [ "$(grep -c '^mount' "$CASE/mounts")" -eq 2 ] && [ "$(grep -c '^umount' "$CASE/mounts")" -eq 2 ] || { echo "mounts: $(cat "$CASE/mounts")"; return 1; }
  grep -q 'mount -o ro .*hassos-system0' "$CASE/mounts" || { echo "not the other rootfs, read-only: $(cat "$CASE/mounts")"; return 1; }
}
t_mount_fail() {
  new_case m46; setv MOUNT_FAIL 1; OTHER_ROOT_OVERRIDE= run_helper
  [ "$RC" -eq 0 ] && [ "$(res status)" = skipped ] && res reason | grep -q '^other slot unreadable: its rootfs does not mount' || { echo "rc=$RC $(cat "$CASE/gm/ga-rauc-mirror-result.json")"; return 1; }
  grep -q '^<3>.*unreadable' "$CASE/out" || { echo "no err-priority line: $(cat "$CASE/out")"; return 1; }
  [ "$(ncalls write-slot)" -eq 0 ]
}
t_mount_fail_at_recheck() {
  new_case m47; setv MOUNT_FAIL_NTH 2; OTHER_ROOT_OVERRIDE= run_helper
  [ "$(res status)" = skipped ] && res reason | grep -q 'unreadable' && [ "$(ncalls write-slot)" -eq 0 ] && [ -s "$CASE/curl_urls" ]
}
t_written_record() {
  new_case m48; run_helper
  [ "$(res status)" = done ] || return 1
  jq -e --arg rel BOSv1.6.0 '.A.release == $rel and .A.bundle_version == "16.3.1.10" and (.A.at | type) == "number" and (.A.rootfs_digest | length) == 64' "$CASE/written.json" >/dev/null || { echo "record: $(cat "$CASE/written.json" 2>&1)"; return 1; }
  # a failed write leaves no record
  new_case m48b; setv WRITE_CORRUPT 1; run_helper
  [ ! -e "$CASE/written.json" ]
}
# the helper finds ga_manager's data dir through ga-data-root.sh (apps/ on 1.6)
t_data_root_apps() {
  new_case m50; mkdir -p "$CASE/sup/apps/data/99f1cad4_ga_manager"
  printf 'req-apps' > "$CASE/sup/apps/data/99f1cad4_ga_manager/ga-rauc-mirror-request"
  env -u GA_GM_DATA_DIR GA_SUPERVISOR_DIR="$CASE/sup" \
    GA_DATA_ROOT_LIB="$OVL/usr/libexec/ga-data-root.sh" \
    STUB_DIR="$CASE" GA_RAUC_BIN="$WORK/rauc" GA_CURL_BIN="$WORK/curl" GA_BUSCTL_BIN="$WORK/busctl" GA_SYSTEMCTL_BIN="$WORK/systemctl" \
    GA_MIRROR_ROOT="$CASE/root" GA_MIRROR_NOW=$NOW GA_MIRROR_UPTIME_S=18000 GA_MIRROR_MIN_FREE_KB=0 \
    GA_MIRROR_DEVROOT="$CASE/dev" GA_MIRROR_OTHER_ROOT="$CASE/other" GA_MIRROR_WRITTEN_RECORD="$CASE/written.json" \
    GA_RESOLVE_OTA_BIN="$CASE/resolve" GA_OTA_ACTIVE_FILE="$CASE/ota.active" \
    sh "$HELPER" > "$CASE/out" 2>&1
  [ $? -eq 0 ] || { echo "rc!=0: $(cat "$CASE/out")"; return 1; }
  _r="$CASE/sup/apps/data/99f1cad4_ga_manager/ga-rauc-mirror-result.json"
  [ -s "$_r" ] && [ "$(jq -r .request_id "$_r")" = req-apps ] && [ "$(jq -r .status "$_r")" = done ] || { echo "no result under apps/data: $(cat "$CASE/out")"; return 1; }
}
t_busy() { new_case m26; setv OPERATION installing; run_helper; must_skip "RAUC is busy"; }
t_install_unit_running() { new_case m27; setv INSTALL_UNIT_STATE activating; run_helper; must_skip "running an install"; }
t_install_unit_done() { new_case m27b; setv INSTALL_UNIT_STATE active; run_helper; [ "$(res status)" = done ]; }
t_busctl_fail() { new_case m28; setv BUSCTL_FAIL 1; run_helper; must_fail 7 "RAUC Operation"; [ "$(ncalls write-slot)" -eq 0 ]; }
t_flock() {
  new_case m29
  ( flock 9; sleep 4 ) 9>"$CASE/root/run/ga-rauc-mirror-slot.lock" &
  _bg=$!; sleep 0.5
  run_helper; wait "$_bg" 2>/dev/null
  must_skip "another ga-rauc-mirror-slot run"
}
t_space() { new_case m30; FREE_OVERRIDE=999999999999 run_helper; must_fail 3 "KiB free"; [ "$(ncalls write-slot)" -eq 0 ] && [ ! -s "$CASE/curl_urls" ]; }
t_dl_fail() { new_case m15; setv CURL_FAIL 1; run_helper; must_fail 3 "download failed" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_dl_fallback() {
  new_case m15b; setv CURL_FAIL_PRIMARY 1; run_helper
  [ "$(res status)" = done ] && [ "$(wc -l < "$CASE/curl_urls")" -eq 2 ] \
    && ! sed -n 2p "$CASE/curl_urls" | grep -q BOSv1.6.0/ || { echo "$(cat "$CASE/curl_urls")"; return 1; }
}
t_curl_limits() {
  new_case m15c; run_helper
  grep -q -e '--max-time 900' -e '--speed-limit' "$CASE/curl_flags" || grep -q 'max-time' "$CASE/curl_flags" || { echo "curl got no time limits: $(cat "$CASE/curl_flags")"; return 1; }
  grep -q 'speed-limit' "$CASE/curl_flags"
}
t_wrong_release() {
  new_case m16; setv BUNDLE_REL BOSv1.5.3; run_helper; must_fail 4 "not the running release" && [ "$(ncalls write-slot)" -eq 0 ] || return 1
  new_case m16b; setv BUNDLE_REL ""; run_helper; must_fail 4 "none" && [ "$(ncalls write-slot)" -eq 0 ]
}
t_board_unreadable() { new_case m16e; rm "$CASE/root/etc/os-release"; run_helper; must_fail 7 "VARIANT_ID" && [ "$(ncalls write-slot)" -eq 0 ] && [ ! -s "$CASE/curl_urls" ]; }
t_board_dsgw() { new_case m16f; printf 'VARIANT_ID=dsgw210\n' > "$CASE/root/etc/os-release"; run_helper; grep -q 'haos_dsgw210-16.3.1.10.raucb' "$CASE/curl_urls"; }
t_mf_hash() { new_case m16c; setv MF_HASH hashOTHER; run_helper; must_fail 4 "manifest hash" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_mf_hash_absent_ok() { new_case m16d; setv B_HASH ""; setv MF_HASH hashOTHER; run_helper; [ "$(res status)" = done ]; }
t_info_fail() { new_case m17; setv INFO_FAIL 1; run_helper; must_fail 4 "refuses the bundle" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_extract_fail() { new_case m17b; setv EXTRACT_FAIL 1; run_helper; must_fail 4 "extract" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_digest_mismatch() { new_case m17c; setv EXTRACT_CORRUPT 1; run_helper; must_fail 4 "manifest digest" && [ "$(ncalls write-slot)" -eq 0 ] && [ "$(ncalls status\ mark-bad)" -eq 0 ]; }
t_markbad_fail() { new_case m18a; setv MARKBAD_FAIL 1; run_helper; must_fail 5 "before writing" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_write_fail() {
  new_case m18; setv WRITE_FAIL_ROOTFS 1; run_helper
  must_fail 5 "rootfs" || return 1
  grep -q "left marked bad" "$CASE/gm/ga-rauc-mirror-result.json" || return 1
  . "$CASE/state.env"; [ "$A_BS" = bad ] && [ "$(order)" = "B" ] || { echo "half-written slot not kept out of BOOT_ORDER ('$(order)')"; return 1; }
}
t_write_kernel_fail() { new_case m18b; setv WRITE_FAIL_KERNEL 1; run_helper; must_fail 5 "kernel" && [ "$(ncalls write-slot)" -eq 1 ]; }
t_readback() { new_case m19; setv WRITE_CORRUPT 1; run_helper; must_fail 5 "read-back" && [ "$(ncalls status\ mark-good)" -eq 0 ]; }
t_markgood_fail() { new_case m19b; setv MARKGOOD_FAIL 1; run_helper; must_fail 5 "mark"; }
t_restore_retry() {
  new_case m20a; setv BOOTED_MARK_FAILS 2; run_helper
  [ "$(res status)" = done ] && [ "$(order)" = "B A" ] || { echo "rc=$RC $(cat "$CASE/out")"; return 1; }
}
t_restore_never() {
  new_case m20; setv BOOTED_MARK_NEVER 1; run_helper
  must_fail 6 CRITICAL || return 1
  [ "$(ncalls 'status mark-active booted')" -ge 3 ] || { echo "no retries"; return 1; }
}
t_restore_lie() {
  # the bootloader reports a wrong primary after a "successful" mark-active: readback must catch it
  new_case m20b; setv PRIMARY_LIE A; run_helper; must_fail 6 CRITICAL
}
t_other_mark_fail_no_restore_needed() {
  new_case m20c; setv OTHER_MARK_FAIL 1; run_helper
  # primary never left the booted slot: nothing to restore, so no mark-active booted
  [ "$(ncalls 'status mark-active booted')" -eq 0 ] || { echo "mark-active booted without our own mark-active"; return 1; }
  [ "$(res status)" = done ] || [ "$(res status)" = failed ]
}
t_unreadable_release() { new_case m21; rm "$CASE/root/etc/ga-release"; run_helper; must_fail 7 "unreadable" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_status_fail() { new_case m22; setv STATUS_FAIL 1; run_helper; must_fail 7 "no output" && [ "$(ncalls write-slot)" -eq 0 ]; }
t_bad_request() {
  new_case m23; run_helper 'a b;rm'; [ "$RC" -eq 2 ] && [ "$(ncalls write-slot)" -eq 0 ] || { echo "rc=$RC"; return 1; }
  new_case m23b; ln -s /etc/passwd "$CASE/gm/ga-rauc-mirror-request"
  STUB_DIR="$CASE" GA_RAUC_BIN="$WORK/rauc" GA_GM_DATA_DIR="$CASE/gm" GA_MIRROR_ROOT="$CASE/root" GA_MIRROR_NOW=$NOW sh "$HELPER" >/dev/null 2>&1
  [ $? -eq 2 ] && [ ! -e "$CASE/gm/ga-rauc-mirror-request" ] && [ -e /etc/passwd ]
}
t_result_symlink() {
  # the add-on can plant a symlink where the result goes: it must be replaced, never followed
  new_case m31; echo precious > "$CASE/victim"; ln -s "$CASE/victim" "$CASE/gm/ga-rauc-mirror-result.json"
  run_helper
  [ "$(cat "$CASE/victim")" = precious ] || { echo "the symlink target was overwritten"; return 1; }
  [ ! -L "$CASE/gm/ga-rauc-mirror-result.json" ] && [ "$(res status)" = done ]
}
t_signal() {
  new_case m32; setv WRITE_SLEEP 5
  printf 'req1' > "$CASE/gm/ga-rauc-mirror-request"
  ( STUB_DIR="$CASE" GA_RAUC_BIN="$WORK/rauc" GA_CURL_BIN="$WORK/curl" GA_BUSCTL_BIN="$WORK/busctl" GA_SYSTEMCTL_BIN="$WORK/systemctl" \
    GA_GM_DATA_DIR="$CASE/gm" GA_MIRROR_ROOT="$CASE/root" GA_MIRROR_NOW=$NOW GA_MIRROR_UPTIME_S=18000 GA_MIRROR_MIN_FREE_KB=0 \
    GA_MIRROR_DEVROOT="$CASE/dev" GA_MIRROR_OTHER_ROOT="$CASE/other" GA_RESOLVE_OTA_BIN="$CASE/resolve" GA_OTA_ACTIVE_FILE="$CASE/ota.active" \
    exec sh "$HELPER" > "$CASE/out" 2>&1 ) &
  _p=$!; sleep 1.5; kill -TERM "$_p"; wait "$_p"; RC=$?
  [ "$RC" -eq 143 ] || { echo "rc=$RC"; return 1; }
  [ "$(res status)" = failed ] && res reason | grep -q interrupted || return 1
  [ -z "$(ls "$CASE/root/mnt/data/tmp")" ] || { echo "work dir left: $(ls "$CASE/root/mnt/data/tmp")"; return 1; }
}
t_signal_after_mark_active() {
  # a signal after our own mark-active <other>: the primary must be put back
  new_case m33; setv OTHER_MARK_SLEEP 3
  printf 'req1' > "$CASE/gm/ga-rauc-mirror-request"
  ( STUB_DIR="$CASE" GA_RAUC_BIN="$WORK/rauc" GA_CURL_BIN="$WORK/curl" GA_BUSCTL_BIN="$WORK/busctl" GA_SYSTEMCTL_BIN="$WORK/systemctl" \
    GA_GM_DATA_DIR="$CASE/gm" GA_MIRROR_ROOT="$CASE/root" GA_MIRROR_NOW=$NOW GA_MIRROR_UPTIME_S=18000 GA_MIRROR_MIN_FREE_KB=0 \
    GA_MIRROR_DEVROOT="$CASE/dev" GA_MIRROR_OTHER_ROOT="$CASE/other" GA_MIRROR_WRITTEN_RECORD="$CASE/written.json" \
    GA_RESOLVE_OTA_BIN="$CASE/resolve" GA_OTA_ACTIVE_FILE="$CASE/ota.active" \
    exec sh "$HELPER" > "$CASE/out" 2>&1 ) &
  _p=$!; sleep 2; kill -TERM "$_p"; wait "$_p"; RC=$?
  [ "$RC" -eq 143 ] || { echo "rc=$RC"; return 1; }
  [ "$(order)" = "B A" ] || { echo "BOOT_ORDER '$(order)': the primary was not restored after the signal"; return 1; }
  res reason | grep -q 'restore attempted: yes' || { echo "reason: $(res reason)"; return 1; }
}
t_epoch() {
  sed -n '/^rfc3339_epoch()/,/^}/p' "$HELPER" > "$WORK/epoch.sh"
  [ -s "$WORK/epoch.sh" ] || { echo "rfc3339_epoch not found in the helper"; return 1; }
  for e in 0 951782400 1709164800 1794000000 1830297599 4102444800; do
    got="$(. "$WORK/epoch.sh"; rfc3339_epoch "$(iso "$e")")"
    [ "$got" = "$e" ] || { echo "epoch $e -> '$got'"; return 1; }
  done
  [ -z "$(. "$WORK/epoch.sh"; rfc3339_epoch "garbage")" ]
}

t_no_reboot() { ! grep -v '^[[:space:]]*#' "$HELPER" | grep -Eq 'reboot|poweroff|shutdown|systemctl (start|restart|stop)'; }
t_no_activate_installed_false() {
  # system.conf.gtpl lives in buildroot-external/ota on the 1.5 line and in the
  # haos submodule (haos/buildroot-external/ota) on the 1.6 line. Zero files
  # found is reported as an explicit SKIP at the call site (have_system_conf),
  # never as a pass.
  for f in "$REPO/buildroot-external/ota/system.conf.gtpl" "$REPO/haos/buildroot-external/ota/system.conf.gtpl"; do
    [ -f "$f" ] || continue
    ! grep -q 'activate-installed' "$f" || { echo "$f sets activate-installed"; return 1; }
  done
  return 0
}
have_system_conf() { [ -f "$REPO/buildroot-external/ota/system.conf.gtpl" ] || [ -f "$REPO/haos/buildroot-external/ota/system.conf.gtpl" ]; }
t_url_shape() {
  for f in "$HELPER" "$INSTALL"; do
    grep -q 'BASE_URL="https://${OTA_HOST}/releases/${VERSION}"' "$f" || { echo "BASE_URL differs in $f"; return 1; }
    grep -q '/haos_${BOARD}-${VERSION}.raucb"' "$f" || { echo "bundle name differs in $f"; return 1; }
  done
  grep -q 'OTA_HOST="ota.greenautarky.com"' "$HELPER" && grep -q -- '--resolve "${OTA_HOST}:443:${OTA_IP}"' "$HELPER"
}
t_units() {
  grep -q '^PathChanged=/mnt/data/supervisor/addons/data/99f1cad4_ga_manager/ga-rauc-mirror-request$' "$UNITS/ga-rauc-mirror-slot.path" || return 1
  grep -q '^PathChanged=/mnt/data/supervisor/apps/data/99f1cad4_ga_manager/ga-rauc-mirror-request$' "$UNITS/ga-rauc-mirror-slot.path" || { echo "apps/ variant not watched: the unit never fires on 1.6"; return 1; }
  grep -q '^Unit=ga-rauc-mirror-slot.service' "$UNITS/ga-rauc-mirror-slot.path" || return 1
  grep -q '^ExecStart=/usr/sbin/ga-rauc-mirror-slot$' "$UNITS/ga-rauc-mirror-slot.service" || return 1
  ! grep -q '^Conflicts=' "$UNITS/ga-rauc-mirror-slot.service" || return 1
  [ -L "$UNITS/multi-user.target.wants/ga-rauc-mirror-slot.path" ] || return 1
  [ -x "$HELPER" ] || return 1
  ! grep -v '^[[:space:]]*#' "$UNITS/ga-rauc-mirror-slot.path" | grep -q '/share'
}
t_alert_filters() {
  grep -q '_SYSTEMD_UNIT=ga-rauc-mirror-slot.service' "$REPO/buildroot-external/package/fluent-bit-config/fluent-bit.conf" || { echo "tier-1 filter missing"; return 1; }
  grep -q '_SYSTEMD_UNIT=ga-rauc-mirror-slot.service' "$REPO/buildroot-external/rootfs-overlay/etc/fluent-bit/fluent-bit-tier0-os.conf" || { echo "tier-0 filter missing"; return 1; }
}

rts "MIR-01" "must-run: 1.6 soaked, other slot 1.5 -> only kernel+rootfs of the other slot written, order B A, done" t_run_ok
rts "MIR-02" "never calls 'rauc install' (it would rewrite SPL + the shared boot partition)" t_never_install
rts "MIR-03" "the other slot is out of BOOT_ORDER (bad) while it is written" t_other_out_of_order_during_write
rts "MIR-04" "must-run: a 1.6 release candidate" t_rc_runs
rts "MIR-05" "other direction: booted A mirrors into B, order stays A B" t_other_direction
rts "MIR-06" "must-run: other slot on 1.4 (lower major)" t_other_older_major
rts "MIR-07" "idempotent: after the mirror the other slot reads 1.6 -> skipped same line" t_idempotent
rts "MIR-10" "must-skip: soak not reached (2 h)" t_soak
rts "MIR-11" "must-skip: one second short of 24 h" t_soak_edge
rts "MIR-12" "must-run: exactly 24 h" t_soak_exact
rts "MIR-13" "must-skip: uptime below 1 h" t_uptime
rts "MIR-14" "must-skip: BOSv1.5.3 (never on the 1.5 line)" t_15
rts "MIR-15" "must-skip: BOSv1.5.3-rc2" t_15rc
rts "MIR-16" "must-skip: other slot is BOSv1.6.0-rc9 (same line, never overwritten)" t_same_line
rts "MIR-17" "must-skip: other slot is BOSv1.6.3 (same line, newer patch)" t_same_line_newer_patch
rts "MIR-18" "must-skip: other slot is BOSv1.7.0 (not lower)" t_other_newer
rts "MIR-19" "must-skip: other slot's release unreadable / garbage -> not overwriting what cannot be read" "t_other_unreadable && t_other_garbage"
rts "MIR-20" "must-skip: booted slot not good" t_notgood
rts "MIR-21" "must-skip: a slot switch is armed" t_primary
rts "MIR-22" "must-skip: no activation record" t_noact
rts "MIR-23" "must-skip: clock before the activation" t_clock
rts "MIR-24f" "a verified write is recorded for ga-rauc-slots (release, bundle version, digests); a failed write records nothing" t_written_record
rts "MIR-24a" "re-check after the download: an OTA finished meanwhile (BOOT_ORDER A B, other slot fresh) -> skipped, nothing overwritten" t_recheck_primary
rts "MIR-24b" "re-check: RAUC became busy / ga-rauc-install started during the download -> skipped" "t_recheck_busy && t_recheck_unit"
rts "MIR-24g" "re-check: the booted slot changed / became non-good during the download -> skipped" "t_recheck_booted_changed && t_recheck_booted_bad"
rts "MIR-24h" "the helper resolves ga_manager's data dir through ga-data-root.sh: request read and result written under apps/data (1.6)" t_data_root_apps
rts "MIR-24c" "re-check: the other slot became the same line / unreadable during the download -> skipped" "t_recheck_other_same_line && t_recheck_other_gone"
rts "MIR-24d" "ga-rauc-install (all-device OTA path) carries no lock/mirror code; journal dump and other-slot read precede the decisive checks" "t_install_untouched && t_window_order"
rts "MIR-24e" "other rootfs is mounted read-only and unmounted (both reads); mount failure -> own 'other slot unreadable' status + err-priority log" "t_mount_ok && t_mount_fail && t_mount_fail_at_recheck"
rts "MIR-24" "must-skip: RAUC Operation is not idle (Supervisor InstallBundle etc.)" t_busy
rts "MIR-25" "must-skip: ga-rauc-install.service is activating; 'active' (RemainAfterExit) does not block" "t_install_unit_running && t_install_unit_done"
rts "MIR-26" "must-skip: a second run holds the flock" t_flock
rts "MIR-27" "must-fail: RAUC Operation unreadable (busctl) -> exit 7, nothing written" t_busctl_fail
rts "MIR-30" "must-fail: not enough free space -> exit 3, nothing downloaded" t_space
rts "MIR-31" "must-fail: download fails -> exit 3" t_dl_fail
rts "MIR-32" "per-release slot miss falls back to the prod slot" t_dl_fallback
rts "MIR-33" "curl carries connect/max-time and speed limits" t_curl_limits
rts "MIR-34" "must-fail: bundle release is not the running release / has none -> exit 4" t_wrong_release
rts "MIR-35" "must-fail: manifest hash differs from the booted slot's recorded bundle -> exit 4; absent record is fine" "t_mf_hash && t_mf_hash_absent_ok"
rts "MIR-3a" "board: VARIANT_ID names the bundle (dsgw210), unreadable -> exit 7, nothing downloaded" "t_board_dsgw && t_board_unreadable"
rts "MIR-36" "must-fail: rauc info / rauc extract refuse the bundle -> exit 4" "t_info_fail && t_extract_fail"
rts "MIR-37" "must-fail: extracted image digest differs from the manifest -> exit 4, slot untouched" t_digest_mismatch
rts "MIR-38" "must-fail: mark-bad fails -> exit 5 before any write" t_markbad_fail
rts "MIR-39" "must-fail: write-slot fails -> exit 5, slot stays bad and out of BOOT_ORDER" "t_write_fail && t_write_kernel_fail"
rts "MIR-40" "must-fail: wrong read-back after the write -> exit 5, not marked good" t_readback
rts "MIR-41" "must-fail: mark-good fails -> exit 5" t_markgood_fail
rts "MIR-42" "mark-active booted is retried (2 failures, then ok)" t_restore_retry
rts "MIR-43" "must-fail: mark-active booted never works -> 3 tries, exit 6 CRITICAL" t_restore_never
rts "MIR-44" "must-fail: primary read-back wrong after a 'successful' mark-active -> exit 6" t_restore_lie
rts "MIR-45" "no mark-active booted unless our own mark-active ran" t_other_mark_fail_no_restore_needed
rts "MIR-46" "must-fail: release unreadable -> exit 7" t_unreadable_release
rts "MIR-47" "must-fail: rauc status unreadable -> exit 7" t_status_fail
rts "MIR-48" "bad request id / symlinked request file -> exit 2" t_bad_request
rts "MIR-49" "a symlink planted at the result path is replaced, never followed" t_result_symlink
rts "MIR-50" "SIGTERM mid-write: loud failed result, work dir removed, exit 143" t_signal
rts "MIR-50b" "SIGTERM after our own mark-active <other>: the primary is restored" t_signal_after_mark_active
rts "MIR-51" "civil-date arithmetic equals GNU date" t_epoch
rts "MIR-52" "helper never reboots or starts/stops units" t_no_reboot
if have_system_conf; then
  rts "MIR-53" "system.conf keeps activate-installed default" t_no_activate_installed_false
else
  [ -n "${GA_MIRROR_ONLY:-}" ] || skip_test "MIR-53" "system.conf keeps activate-installed default" "system.conf.gtpl not present (haos submodule not checked out)"
fi
rts "MIR-54" "download URL shape and endpoint pinning match ga-rauc-install" t_url_shape
rts "MIR-55" "units wired: path -> service, enabled, ga_manager's data dir only, no Conflicts=" t_units
rts "MIR-56" "the mirror unit is in the tier-1 and tier-0 fluent-bit filters" t_alert_filters

# --- counter-check: break the LIVE helper, the SPECIFIC guard must go red -----
# Each mutant is the live helper with one guard edited out; the named test must
# FAIL on it. A pattern that no longer matches fails the check (never skips).
mutant_red() { # <name> <old> <new> <test id that must fail>
  _mf="$WORK/mutant_$1.sh"
  python3 - "$HELPER" "$_mf" "$2" "$3" <<'PY' || { echo "mutation pattern for $1 not found in the helper"; return 1; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.exit(1)
open(dst, "w").write(s.replace(old, new, 1))
PY
  _o="$(GA_MIRROR_ONLY="$4" GA_MIRROR_NO_MUTANTS=1 GA_MIRROR_HELPER="$_mf" sh "$0" 2>&1)"
  printf '%s\n' "$_o" | grep -q "FAIL  $4:" || { echo "mutant $1 did not turn $4 red"; return 1; }
}
if [ -z "${GA_MIRROR_NO_MUTANTS:-}" ] && command -v python3 >/dev/null 2>&1; then
  rts "MIR-60" "red: without the soak check MIR-10 goes red" \
    "mutant_red soak '[ \"\$AGE\" -ge \"\$SOAK_S\" ] ||' 'true ||' MIR-10"
  rts "MIR-61" "red: without the 1.5 check MIR-14 goes red" \
    "mutant_red r15 'skip \"release \$RELEASE is below' ': \"release \$RELEASE is below' MIR-14"
  rts "MIR-62" "red: without the same-line check MIR-16 goes red" \
    "mutant_red sameline 'if ! line_lt \"\$OTHER_LINE\" \"\$RUN_LINE\"; then' 'if false; then' MIR-16"
  rts "MIR-63" "red: without the bundle-release check MIR-34 goes red" \
    "mutant_red rel '[ \"\$B_REL\" = \"\$RELEASE\" ] ||' 'true ||' MIR-34"
  rts "MIR-64" "red: without the armed-switch check MIR-21 goes red" \
    "mutant_red primary '[ \"\$(get RAUC_BOOT_PRIMARY)\" = \"\$BK\" ] \\' 'true \\' MIR-21"
  rts "MIR-65" "red: without the busy check MIR-24 goes red" \
    "mutant_red busy 'skip \"RAUC is busy' ': \"RAUC is busy' MIR-24"
  rts "MIR-66" "red: without the activating check MIR-25 goes red" \
    "mutant_red unit '= activating ]; then' '= NEVER ]; then' MIR-25"
  rts "MIR-67" "red: without the flock MIR-26 goes red" \
    "mutant_red flock 'flock -n 9 ||' 'true ||' MIR-26"
  rts "MIR-68" "red: without the free-space check MIR-30 goes red" \
    "mutant_red space '[ \"\$FREE_KB\" -ge \"\$MIN_FREE_KB\" ] ||' 'true ||' MIR-30"
  rts "MIR-69" "red: without the manifest-hash check MIR-35 goes red" \
    "mutant_red mfhash 'if [ -n \"\$BOOTED_HASH\" ] && [ \"\$MF_HASH\" != \"\$BOOTED_HASH\" ]; then' 'if false; then' MIR-35"
  rts "MIR-70" "red: without the digest check MIR-37 goes red" \
    "mutant_red digest '[ \"\$_have\" = \"\${_p#*:}\" ] ||' 'true ||' MIR-37"
  rts "MIR-71" "red: without mark-bad before the write MIR-03 goes red" \
    "mutant_red markbad '\"\$RAUC\" status mark-bad \"\$OK\" >/dev/null 2>&1 ||' 'true ||' MIR-03"
  rts "MIR-72" "red: without the read-back MIR-40 goes red" \
    "mutant_red readback '[ \"\$_got\" = \"\$_dg\" ] ||' 'true ||' MIR-40"
  rts "MIR-73" "red: without the primary read-back MIR-44 goes red" \
    "mutant_red primrb '[ \"\$(get RAUC_BOOT_PRIMARY)\" = \"\$BK\" ] && return 0' 'return 0' MIR-44"
  rts "MIR-74" "red: without the mark-active retry MIR-42 goes red" \
    "mutant_red retry 'while [ \"\$_rp_i\" -lt 3 ]; do' 'while [ \"\$_rp_i\" -lt 1 ]; do' MIR-42"
  rts "MIR-75" "red: following a result symlink (plain > redirect) MIR-49 goes red" \
    "mutant_red symlink 'mv -f \"\$_wr_tmp\" \"\$RESULT_FILE\" ||' 'cat \"\$_wr_tmp\" > \"\$RESULT_FILE\" ||' MIR-49"
  rts "MIR-77" "red: without the primary re-check MIR-24a goes red" \
    "mutant_red recheckprim 'skip \"boot primary is now' ': \"boot primary is now' MIR-24a"
  rts "MIR-78" "red: without the re-check busy gate MIR-24b goes red" \
    "mutant_red recheckbusy 'skip \"RAUC is busy at the re-check' ': \"RAUC is busy at the re-check' MIR-24b"
  rts "MIR-79" "red: journal dump moved back after the re-check MIR-24d goes red" \
    "mutant_red windowmove 'log \"writing \$RELEASE into slot' '/usr/libexec/ga-journal-dump rauc-mirror-slot
log \"writing \$RELEASE into slot' MIR-24d"
  rts "MIR-83" "red: without the booted-bootname re-check MIR-24g goes red" \
    "mutant_red recheckbooted 'skip \"booted slot changed during the download' ': \"booted slot changed during the download' MIR-24g"
  rts "MIR-84" "red: without the booted-good re-check MIR-24g goes red" \
    "mutant_red recheckgood 'skip \"booted slot no longer good' ': \"booted slot no longer good' MIR-24g"
  rts "MIR-85" "red: data dir hard-coded to addons/ MIR-24h goes red" \
    "mutant_red dataroot 'GM_DATA_DIR=\"\$(ga_data_root_or_unresolved)/99f1cad4_ga_manager\"' 'GM_DATA_DIR=\"/mnt/data/supervisor/addons/data/99f1cad4_ga_manager\"' MIR-24h"
  rts "MIR-80" "red: MARKED_OTHER never set (signal handler skips the restore) MIR-50b goes red" \
    "mutant_red markedother 'MARKED_OTHER=yes' 'MARKED_OTHER=no' MIR-50b"
  rts "MIR-81" "red: mount failure no longer a loud skip MIR-24e goes red" \
    "mutant_red mountfail '[ -z \"\$OTHER_ERR\" ] || unreadable_skip \"its rootfs does not mount\"' ': ' MIR-24e"
  rts "MIR-82" "red: no umount after the read MIR-24e goes red" \
    "mutant_red umount '    \"\$UMOUNT\" \"\$OTHER_MNT\" 2>/dev/null
    rmdir' '    true
    rmdir' MIR-24e"
  rts "MIR-76" "red: without the signal trap MIR-50 goes red" \
    "mutant_red trap 'trap on_signal TERM INT HUP' 'true' MIR-50"
fi

suite_end
