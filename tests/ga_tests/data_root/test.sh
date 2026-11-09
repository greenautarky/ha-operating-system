#!/bin/sh
# ga-data-root.sh: the one resolver for Supervisor's add-on data root (Odoo #1610).
#   DR-0x  the four layouts: apps only, addons only, both (apps wins), neither
#          (loud failure, nothing printed on stdout, no default invented)
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
LIB="$OV/usr/libexec/ga-data-root.sh"
SH="${GA_T_SHELL:-sh}"
MODE="${1:-new}"
W="$(mktemp -d "${TMPDIR:-/tmp}/dataroot.XXXXXX")"
[ -n "${KEEP:-}" ] || trap 'rm -rf "$W"' EXIT

mk() { rm -rf "$W/$1"; mkdir -p "$W/$1/supervisor"; for d in $2; do mkdir -p "$W/$1/supervisor/$d/data"; done; }
mk apps_only apps; mk addons_only addons; mk both "apps addons"; mk neither ""
resolve() { GA_SUPERVISOR_DIR="$W/$1/supervisor" $SH -c ". '$LIB'; ga_data_root" 2>"$W/$1.err"; }

run_test "DR-00" "resolver present" "test -s '$LIB'"
run_test "DR-01" "apps only -> apps/data" "[ \"\$(resolve apps_only)\" = '$W/apps_only/supervisor/apps/data' ]"
run_test "DR-02" "addons only (1.5.x, downgrade) -> addons/data" "[ \"\$(resolve addons_only)\" = '$W/addons_only/supervisor/addons/data' ]"
run_test "DR-03" "both present -> apps wins" "[ \"\$(resolve both)\" = '$W/both/supervisor/apps/data' ]"
run_test "DR-04" "neither: rc 1, empty stdout, ERROR on stderr naming both paths" \
  "out=\$(resolve neither); rc=\$?; [ \$rc -eq 1 ] && [ -z \"\$out\" ] && grep -q 'ERROR' '$W/neither.err' && grep -q 'apps/data' '$W/neither.err' && grep -q 'addons/data' '$W/neither.err'"
run_test "DR-05" "neither, lenient form: loud stderr too, prints a path that cannot exist, rc 0" \
  "out=\$(GA_SUPERVISOR_DIR='$W/neither/supervisor' $SH -c \". '$LIB'; ga_data_root_or_unresolved\" 2>'$W/n2.err'); [ -n \"\$out\" ] && [ ! -e \"\$out\" ] && grep -q ERROR '$W/n2.err'"
run_test "DR-06" "a stale addons/ does not outrank apps/ (both, files only under addons)" \
  "mkdir -p '$W/both/supervisor/addons/data/x'; [ \"\$(resolve both)\" = '$W/both/supervisor/apps/data' ]"

# --- consumers ---------------------------------------------------------------
fetch() {  # fetch <path-in-repo> <dest>: live file, or the baseline ref's in old mode
  if [ "$MODE" = old ]; then
    git -C "$R" show "${GA_DATAROOT_BASELINE_REF:?old mode needs GA_DATAROOT_BASELINE_REF}:$1" > "$2" || { echo "cannot read $1"; exit 2; }
  else cp "$R/$1" "$2"; fi
}
GMSLUG=99f1cad4_ga_manager
mkdir -p "$W/bin"
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
suite_end
