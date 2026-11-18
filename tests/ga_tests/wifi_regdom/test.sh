#!/bin/sh
# ga-wifi-regdom (Odoo #2183, CE R1): the Wi-Fi country is configuration, applied
# explicitly: /mnt/boot/ga-wifi-country > board default > nothing. Host test
# against a stub `iw`; the REAL script and the REAL DSGW board file are the
# subjects. On-device proof: tests/ga_tests/wifi_regdom/device.sh.
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SUBJ="$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-wifi-regdom"
DSGW_CONF="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay/usr/share/ga-board.conf"
UNIT="$ROOT/buildroot-external/rootfs-overlay/etc/systemd/system/ga-wifi-regdom.service"
WANTS="$ROOT/buildroot-external/rootfs-overlay/etc/systemd/system/multi-user.target.wants/ga-wifi-regdom.service"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }
cat > "$WORK/iw" <<'STUB'
#!/bin/sh
echo "iw $*" >> "$IW_LOG"
case "$1 $2" in
  "reg set") [ "${IW_SET_FAIL:-0}" = 1 ] && exit 1; printf '%s\n' "${IW_REPORT:-$3}" > "$IW_STATE"; exit 0 ;;
  "reg get") printf 'global\ncountry %s: DFS-ETSI\n\t(2400 - 2483 @ 40), (N/A, 20), (N/A)\n\n' "$(cat "$IW_STATE" 2>/dev/null || echo 00)"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$WORK/iw"
run() {  # run <board-conf> [country-file-content|-]
    : > "$WORK/iw.log"; rm -f "$WORK/state" "$WORK/country"
    [ "${2:--}" != - ] && printf '%s\n' "$2" > "$WORK/country"
    env -u GA_WIFI_COUNTRY GA_BOARD_CONF="$1" GA_WIFI_COUNTRY_FILE="$WORK/country" GA_IW="$WORK/iw" \
        IW_LOG="$WORK/iw.log" IW_STATE="$WORK/state" GA_WIFI_REGDOM_SETTLE_S=0 GA_WIFI_REGDOM_LOG_STDERR=1 sh "$SUBJ" > "$WORK/out" 2>&1
    echo $? > "$WORK/rc"
}
set_to() { grep -o 'reg set [A-Z0-9]*' "$WORK/iw.log" | head -1 | cut -d' ' -f3; }
echo "=== ga-wifi-regdom (Odoo #2183) ==="
: > "$WORK/no-board.conf"
run "$DSGW_CONF"; [ "$(set_to)" = DE ] && PASS "DSGW, no site file: board default DE applied" || FAIL "DSGW default" "set '$(set_to)'"
run "$DSGW_CONF" "NL"; [ "$(set_to)" = NL ] && PASS "site file NL overrides the board default" || FAIL "file override" "set '$(set_to)'"
run "$DSGW_CONF" " AT  "; [ "$(set_to)" = AT ] && PASS "site file whitespace is trimmed" || FAIL "trim" "set '$(set_to)'"
run "$DSGW_CONF" "de"; [ "$(set_to)" = DE ] && grep -q "ignoring" "$WORK/out" && PASS "invalid site file (lower case) is refused loudly, board default stays" || FAIL "invalid file" "set '$(set_to)' out=$(cat "$WORK/out")"
run "$DSGW_CONF" "DEU"; [ "$(set_to)" = DE ] && grep -q "ignoring" "$WORK/out" && PASS "invalid site file (3 letters) is refused loudly" || FAIL "3 letters" "set '$(set_to)'"
run "$WORK/no-board.conf"; [ ! -s "$WORK/iw.log" ] && [ "$(cat "$WORK/rc")" = 0 ] && PASS "iHost / no board default, no file: iw never called, exit 0" || FAIL "inert" "$(cat "$WORK/iw.log")"
run "$WORK/no-board.conf" "FR"; [ "$(set_to)" = FR ] && PASS "no board default but a site file: the file is applied" || FAIL "file only" "set '$(set_to)'"
IW_REPORT=98 run "$DSGW_CONF"; grep -q "intersection '98'" "$WORK/out" && [ "$(cat "$WORK/rc")" = 0 ] && PASS "AP advertises another country (98): reported loudly, not an error" || FAIL "98" "$(cat "$WORK/out")"
IW_SET_FAIL=1 run "$DSGW_CONF"; [ "$(cat "$WORK/rc")" = 1 ] && grep -q "FAILED" "$WORK/out" && PASS "iw reg set fails: exit 1 and a loud line" || FAIL "set fail" "rc=$(cat "$WORK/rc") $(cat "$WORK/out")"
# The iHost gate (rc3 source, Odoo #2183): the iHost image ships NO ga-board.conf and
# NO ga-wifi-country, so the script finds no country and never calls iw.
run "$WORK/does-not-exist.conf"; [ ! -s "$WORK/iw.log" ] && [ "$(cat "$WORK/rc")" = 0 ] && PASS "iHost reality (no board file at all, no site file): iw never called, exit 0" || FAIL "iHost gate" "$(cat "$WORK/iw.log")"
_ih=$(find "$ROOT/buildroot-ihost" "$ROOT/buildroot-external/rootfs-overlay" -name ga-board.conf -o -name ga-wifi-country 2>/dev/null | head -3)
[ -z "$_ih" ] && PASS "no iHost/shared overlay ships ga-board.conf or ga-wifi-country (the DSGW file is the only source of a default)" || FAIL "iHost overlay" "$_ih"
grep -qx 'RequiresMountsFor=/mnt/boot' "$UNIT" && grep -qx 'Before=NetworkManager.service' "$UNIT" && PASS "unit: after /mnt/boot is mounted, before NetworkManager" || FAIL "unit order" "$(grep -E '^(Requires|Before)' "$UNIT")"
[ "$(readlink "$WANTS")" = ../ga-wifi-regdom.service ] && PASS "unit is enabled (multi-user.target.wants)" || FAIL "enabled" "$(readlink "$WANTS")"
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
