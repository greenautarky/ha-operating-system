#!/bin/sh
# ga-data-root.sh: the one resolver for Supervisor's add-on data root (Odoo #1610).
#   DR-0x  the layouts: apps only, addons only, both trees (the RUNNING Supervisor's
#          version decides: 2025.x -> addons, 2026.10 -> apps; not running -> newest
#          ga_manager slug dir), empty stale tree, neither (loud failure, nothing
#          printed on stdout, no default invented)
#   DR-1x  REAL consumers driven against an apps-only tree (the BOSv1.6 layout):
#          ga-fluent-bit-env derives the label and loki cred, ga-telegraf-env finds
#          the influx cred, ga-rauc-slots finds the add-on data dir
# Usage: test.sh [new|old]   old = RED PROOF: the consumers from
#   $GA_DATAROOT_BASELINE_REF (a git ref before the fix; resolver stays the live one).
# Needs sh, coreutils, sed, grep. No device.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "ga-data-root resolver and its consumers"
R="$SCRIPT_DIR/../../.."
OV="$R/buildroot-external/rootfs-overlay"
LIB="${GA_DATAROOT_LIB_UNDER_TEST:-$OV/usr/libexec/ga-data-root.sh}"
SH="${GA_T_SHELL:-sh}"
MODE="${1:-new}"
W="$(mktemp -d "${TMPDIR:-/tmp}/dataroot.XXXXXX")"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$W"' EXIT

GMSLUG=99f1cad4_ga_manager
mkdir -p "$W/bin"
# Fake `docker`: answers `docker inspect ... hassio_supervisor` with the version in
# $GA_T_SUPVER ("none" = container not running). The resolver under test is the real one.
cat > "$W/bin/docker" <<'FAKE'
#!/bin/sh
[ "$1" = inspect ] || exit 2
case "$*" in *hassio_supervisor*) ;; *) exit 1 ;; esac
[ "${GA_T_SUPVER:-none}" = none ] && { echo "Error: No such object: hassio_supervisor" >&2; exit 1; }
echo "$GA_T_SUPVER"
FAKE
chmod +x "$W/bin/docker"
GA_T_SUPVER=none; export GA_T_SUPVER
# mk <name> "<trees>": empty data dirs. gm <name> <tree> <epoch>: ga_manager slug dir with that mtime.
mk() { rm -rf "$W/$1"; mkdir -p "$W/$1/supervisor"; for d in $2; do mkdir -p "$W/$1/supervisor/$d/data"; done; }
gm() { mkdir -p "$W/$1/supervisor/$2/data/$GMSLUG"; touch -d "@$3" "$W/$1/supervisor/$2/data/$GMSLUG"; }
mk apps_only apps; gm apps_only apps 1000
mk addons_only addons; gm addons_only addons 1000
mk both "apps addons"; gm both apps 1000; gm both addons 1000
mk neither ""
mk stale_apps "apps addons"; gm stale_apps addons 1000          # empty apps/data next to live addons/data
mk apps_newer "apps addons"; gm apps_newer apps 2000; gm apps_newer addons 1000
mk addons_newer "apps addons"; gm addons_newer apps 1000; gm addons_newer addons 2000
mk only_addons_dir addons                                        # addons/data present, no add-on in it yet
resolve() { PATH="$W/bin:$PATH" GA_SUPERVISOR_DIR="$W/$1/supervisor" GA_T_SUPVER="${2:-none}" $SH -c ". '$LIB'; ga_data_root" 2>"$W/$1.err"; }
P="$W"

run_test "DR-00" "resolver present" "test -s '$LIB'"
run_test "DR-01" "Supervisor not running, apps only -> apps/data" "[ \"\$(resolve apps_only)\" = '$P/apps_only/supervisor/apps/data' ]"
run_test "DR-02" "Supervisor not running, addons only (1.5.x) -> addons/data" "[ \"\$(resolve addons_only)\" = '$P/addons_only/supervisor/addons/data' ]"
run_test "DR-03" "1.6 (Supervisor 2026.10.5.4), both trees -> apps/data" "[ \"\$(resolve both 2026.10.5.4)\" = '$P/both/supervisor/apps/data' ]"
run_test "DR-03b" "ROLLBACK (Supervisor 2025.11.5.4), both trees -> addons/data" "[ \"\$(resolve both 2025.11.5.4)\" = '$P/both/supervisor/addons/data' ]"
run_test "DR-03c" "ROLLBACK, stale apps/ has the NEWER slug dir -> still addons/data (running Supervisor beats mtime)" "[ \"\$(resolve apps_newer 2025.11.5.4)\" = '$P/apps_newer/supervisor/addons/data' ]"
run_test "DR-03d" "Supervisor 2026.10.5.4 but apps/data missing: rc 1 + ERROR, no silent fallback to addons/" \
  "out=\$(resolve addons_only 2026.10.5.4); rc=\$?; [ \$rc -eq 1 ] && [ -z \"\$out\" ] && grep -q ERROR '$W/addons_only.err'"
run_test "DR-04" "neither: rc 1, empty stdout, ERROR on stderr naming both paths" \
  "out=\$(resolve neither); rc=\$?; [ \$rc -eq 1 ] && [ -z \"\$out\" ] && grep -q 'ERROR' '$W/neither.err' && grep -q 'apps/data' '$W/neither.err' && grep -q 'addons/data' '$W/neither.err'"
run_test "DR-05" "neither, lenient form: loud stderr too, prints a path that cannot exist, rc 0" \
  "out=\$(PATH='$W/bin:'\$PATH GA_SUPERVISOR_DIR='$W/neither/supervisor' $SH -c \". '$LIB'; ga_data_root_or_unresolved\" 2>'$W/n2.err'); [ -n \"\$out\" ] && [ ! -e \"\$out\" ] && grep -q ERROR '$W/n2.err'"
run_test "DR-06" "empty apps/data next to live addons/data -> addons/data (Supervisor not running AND 2025.x)" \
  "[ \"\$(resolve stale_apps)\" = '$P/stale_apps/supervisor/addons/data' ] && [ \"\$(resolve stale_apps 2025.11.5.4)\" = '$P/stale_apps/supervisor/addons/data' ]"
run_test "DR-07" "Supervisor not running, both trees with slug dirs -> newest slug dir wins (both directions)" \
  "[ \"\$(resolve apps_newer)\" = '$P/apps_newer/supervisor/apps/data' ] && [ \"\$(resolve addons_newer)\" = '$P/addons_newer/supervisor/addons/data' ]"
run_test "DR-08" "Supervisor not running, both with slug dirs and equal mtime: rc 1 + ERROR, nothing on stdout" \
  "out=\$(resolve both); rc=\$?; [ \$rc -eq 1 ] && [ -z \"\$out\" ] && grep -q ERROR '$W/both.err'"
run_test "DR-09" "unparseable Supervisor label falls back to the slug-dir rule" \
  "[ \"\$(resolve addons_newer dev)\" = '$P/addons_newer/supervisor/addons/data' ]"
run_test "DR-09b" "Supervisor not running, a tree without any ga_manager dir does not count: rc 1 + ERROR" \
  "out=\$(resolve only_addons_dir); rc=\$?; [ \$rc -eq 1 ] && [ -z \"\$out\" ] && grep -q ERROR '$W/only_addons_dir.err'"

# --- consumers ---------------------------------------------------------------
fetch() {  # fetch <path-in-repo> <dest>: live file, or the baseline ref's in old mode
  if [ "$MODE" = old ]; then
    git -C "$R" show "${GA_DATAROOT_BASELINE_REF:?old mode needs GA_DATAROOT_BASELINE_REF}:$1" > "$2" || { echo "cannot read $1"; exit 2; }
  else cp "$R/$1" "$2"; fi
}
for t in logger sleep; do printf '#!/bin/sh\nexit 0\n' > "$W/bin/$t"; chmod +x "$W/bin/$t"; done
# apps-only data tree with the three files the OS-side consumers read
mk fx apps
G="$W/fx/supervisor/apps/data/$GMSLUG"; mkdir -p "$G"
printf '{"device_id": "KIB-SON-00000999"}\n' > "$G/ga-identity.json"
printf 'host: loki.example\nport: 443\nusername: u999\npassword: p999\ntenant: t999\n' > "$G/ga-fleet-loki.yaml"
printf 'url: https://influx.example\nusername: i999\npassword: q999\n' > "$G/ga-fleet-influx.yaml"
# a fluent-bit-env copy whose fixed device paths are redirected into $W
fetch buildroot-external/package/fluent-bit-config/ga-fluent-bit-env "$W/fbenv.raw"
sed -e "s|/mnt/data/supervisor/homeassistant|$W/fx/ha|g" -e "s|/mnt/data/ga-device-label|$W/fx/nolabel|g" \
    -e "s|/mnt/data/fluent-bit|$W/fx/fb|g" "$W/fbenv.raw" > "$W/fbenv"
grep -n '^FB_DIR=\|FB_DIR=' "$W/fbenv" | head -1 >/dev/null
run_test "DR-10" "fluent-bit-env on an apps-only tree: DEVICE_LABEL from ga-identity.json, per-device loki user (not anonymous)" \
  "PATH='$W/bin:'\$PATH GA_SUPERVISOR_DIR='$W/fx/supervisor' GA_DATA_ROOT_LIB='$LIB' $SH '$W/fbenv' >'$W/fb.out' 2>&1; cat '$W'/fx/fb/env 2>/dev/null | grep -q 'DEVICE_LABEL=KIB-SON-00000999' && cat '$W'/fx/fb/env | grep -q 'LOKI_USER=u999'"
fetch buildroot-external/package/telegraf/ga-telegraf-env "$W/tgenv.raw"
sed -e "s|/mnt/data/ga-device-label|$W/fx/nolabel|g" -e "s|/mnt/data/telegraf|$W/fx/tg|g" "$W/tgenv.raw" > "$W/tgenv"
GA_TELEGRAF_DIR="$W/fx/tg"; export GA_TELEGRAF_DIR
run_test "DR-11" "telegraf-env on an apps-only tree finds the per-device influx cred" \
  "PATH='$W/bin:'\$PATH GA_SUPERVISOR_DIR='$W/fx/supervisor' GA_DATA_ROOT_LIB='$LIB' $SH '$W/tgenv' >'$W/tg.out' 2>&1; grep -q 'INFLUX_USER=i999' '$W'/fx/tg/env && grep -q 'KIB-SON-00000999' '$W'/fx/tg/env"
fetch buildroot-external/rootfs-overlay/usr/libexec/ga-rauc-slots "$W/slots"
FIXSH="$R/tests/ga_tests/rauc_slots/fixtures/dual-slot-healthy.shell"
GA_RAUC_SLOTS_TS=1753790000 GA_SUPERVISOR_DIR="$W/fx/supervisor" GA_DATA_ROOT_LIB="$LIB" GA_RAUC_SLOTS_INPUT="$FIXSH" \
  $SH "$W/slots" >"$W/slots.out" 2>&1
run_test "DR-12" "ga-rauc-slots on an apps-only tree publishes ga-rauc-slots.json into apps/data/<slug>/ (not 'publishing nothing')" \
  "test -s '$G/ga-rauc-slots.json' && ! grep -q 'publishing nothing' '$W/slots.out'"
# ga-rauc-install (real script, real entry path, no VERSION arg): the request is read from
# the root the RUNNING Supervisor uses. Rolled-back device: Supervisor 2025.x, request only
# under addons/, a stale apps/ with a NEWER ga_manager dir next to it. The script stops at
# its "no pinned OTA endpoint" FATAL (rc 3), after the request was read and removed.
fetch buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install "$W/rinst"
mk rb "apps addons"; gm rb apps 2000; gm rb addons 1000
printf '1.2.3.4\n' > "$W/rb/supervisor/addons/data/$GMSLUG/ga-rauc-install-request"
rinst() { PATH="$W/bin:$PATH" GA_T_SUPVER="$2" GA_SUPERVISOR_DIR="$W/$1/supervisor" GA_DATA_ROOT_LIB="$LIB" \
  GA_OTA_ACTIVE_FILE="$W/none.active" GA_RESOLVE_OTA_BIN=/bin/true $SH "$W/rinst" >"$W/$1.rinst.out" 2>&1; }
run_test "DR-13" "ga-rauc-install on a rolled-back device (Supervisor 2025.x, request only under addons/): request read from addons/, removed, run reaches the OTA step" \
  "rinst rb 2025.11.5.4; [ \$? -eq 3 ] && grep -q \"read VERSION='1.2.3.4'.*addons/data\" '$W/rb.rinst.out' && [ ! -e '$W/rb/supervisor/addons/data/$GMSLUG/ga-rauc-install-request' ]"
mk up "apps addons"; gm up apps 1000; gm up addons 2000
printf '5.6.7.8\n' > "$W/up/supervisor/apps/data/$GMSLUG/ga-rauc-install-request"
run_test "DR-13b" "ga-rauc-install on 1.6 (Supervisor 2026.10, request under apps/, stale addons/ newer): request read from apps/" \
  "rinst up 2026.10.5.4; [ \$? -eq 3 ] && grep -q \"read VERSION='5.6.7.8'.*apps/data\" '$W/up.rinst.out' && [ ! -e '$W/up/supervisor/apps/data/$GMSLUG/ga-rauc-install-request' ]"
suite_end
