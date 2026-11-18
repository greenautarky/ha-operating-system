#!/bin/sh
# ga-lora-gate (Odoo #2183 c): the DSGW-210 LoRa concentrator is OFF by default,
# enabled by the fleet flag or the /mnt/boot marker, powered with Dusun's stock
# sequence, probed over spidev, and a missing card is reported LOUDLY.
# Host test: the REAL script against a stub sysfs GPIO tree and stub spi-tools.
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
OVL="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay"
SUBJ="$OVL/usr/libexec/ga-lora-gate"
UNIT="$OVL/etc/systemd/system/ga-lora.service"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }
cat > "$WORK/spi-pipe" <<'STUB'
#!/bin/sh
cat > /dev/null
echo "spi-pipe $*" >> "$SPI_LOG"
printf "\\$(printf '%03o' 0)\\$(printf '%03o' 0)\\$(printf '%03o' 0)\\$(printf '%03o' 0)\\$(printf '%03o' "$((0x${SPI_VERSION:-ff}))")"
STUB
printf '#!/bin/sh\necho "spi-config $*" >> "$SPI_LOG"\n' > "$WORK/spi-config"
chmod +x "$WORK/spi-pipe" "$WORK/spi-config"
setup() {
    rm -rf "$WORK/gpio" "$WORK/data" "$WORK/marker" "$WORK/status.json" "$WORK/stage" "$WORK/spidev"; : > "$WORK/spi.log"
    mkdir -p "$WORK/gpio" "$WORK/data/apps/data/99f1cad4_ga_manager"; : > "$WORK/gpio/export"
    for n in 43 83 85 86 87; do mkdir -p "$WORK/gpio/gpio$n"; : > "$WORK/gpio/gpio$n/value"; : > "$WORK/gpio/gpio$n/direction"; done
    : > "$WORK/spidev"
}
run() {
    GA_LORA_GPIO_DIR="$WORK/gpio" GA_LORA_SPIDEV="$WORK/spidev" GA_SPI_PIPE="$WORK/spi-pipe" GA_SPI_CONFIG="$WORK/spi-config" \
    GA_LORA_BOOT_MARKER="$WORK/marker" GA_GM_DATA_DIR="$WORK/data/apps/data/99f1cad4_ga_manager" GA_LORA_STATUS="$WORK/status.json" \
    GA_SHARE_PUBLISH="$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish" GA_SHARE_STAGE_DIR="$WORK/stage" \
    GA_LORA_STEP_S=0 GA_LORA_LOG_STDERR=1 SPI_LOG="$WORK/spi.log" sh "$SUBJ" > "$WORK/out" 2>&1
    echo $? > "$WORK/rc"
}
val() { tr -d '\n' < "$WORK/gpio/gpio$1/value"; }
js() { jq -r "$1" "$WORK/status.json" 2>/dev/null; }
echo "=== ga-lora-gate (Odoo #2183 c) ==="
setup; run
[ "$(cat "$WORK/rc")" = 0 ] && [ "$(js .enabled)" = false ] && [ ! -s "$WORK/spi.log" ] && [ -z "$(val 83)$(val 86)$(val 43)" ] \
  && PASS "default OFF: no flag, no marker -> GPIOs untouched, no SPI access, status enabled=false" || FAIL "default off" "rc=$(cat "$WORK/rc") $(cat "$WORK/status.json" 2>&1) spi=$(cat "$WORK/spi.log")"
setup; : > "$WORK/marker"; SPI_VERSION=10 run
[ "$(cat "$WORK/rc")" = 0 ] && [ "$(js .present)" = true ] && [ "$(js .chip)" = SX1302 ] && [ "$(js .source)" = boot-marker ] \
  && PASS "boot marker + SX1302 answers (0x10): present, chip, source in the status" || FAIL "marker sx1302" "$(cat "$WORK/out") $(cat "$WORK/status.json" 2>&1)"
[ "$(val 83)$(val 86)" = 11 ] && [ "$(val 43)$(val 87)$(val 85)" = 011 ] && PASS "after the sequence: power 83+86 on, resets released (43=0, 87=1, 85=1)" || FAIL "gpio end state" "83=$(val 83) 86=$(val 86) 43=$(val 43) 87=$(val 87) 85=$(val 85)"
grep -q -- "-b 5" "$WORK/spi.log" && PASS "probe reads 5 bytes over spidev" || FAIL "probe" "$(cat "$WORK/spi.log")"
setup; : > "$WORK/data/apps/data/99f1cad4_ga_manager/ga-lora-enabled"; SPI_VERSION=12 run
[ "$(js .source)" = fleet ] && [ "$(js .chip)" = SX1303 ] && PASS "fleet flag in ga_manager's data dir enables it; SX1303 (0x12) recognised" || FAIL "fleet sx1303" "$(cat "$WORK/status.json" 2>&1)"
setup; : > "$WORK/marker"; SPI_VERSION=ff run
[ "$(cat "$WORK/rc")" = 1 ] && [ "$(js .present)" = false ] && grep -q "no concentrator found" "$WORK/out" \
  && PASS "enabled but no answer (0xff): exit 1, present=false, loud warning" || FAIL "no card" "rc=$(cat "$WORK/rc") $(cat "$WORK/out")"
setup; : > "$WORK/marker"; rm -f "$WORK/spidev"; run
[ "$(cat "$WORK/rc")" = 1 ] && js .reason | grep -q "missing" && PASS "enabled but no spidev node: exit 1, reason names it" || FAIL "no spidev" "$(cat "$WORK/status.json" 2>&1)"
setup; : > "$WORK/marker"; mkdir -p "$WORK/share-flag"; mkdir -p "$WORK/data/share"; rm -f "$WORK/marker"; : > "$WORK/data/share/ga-lora-enabled"; run
[ "$(js .enabled)" = false ] && PASS "a flag in /share is NOT an enable source (any add-on can write /share)" || FAIL "share flag ignored" "$(cat "$WORK/status.json" 2>&1)"
grep -qx 'RequiresMountsFor=/mnt/data /mnt/boot' "$UNIT" && [ "$(readlink "$OVL/etc/systemd/system/multi-user.target.wants/ga-lora.service")" = ../ga-lora.service ] \
  && PASS "unit waits for /mnt/data + /mnt/boot and is enabled" || FAIL "unit" "$(grep Requires "$UNIT")"
[ -z "$(find "$ROOT/buildroot-external/rootfs-overlay" "$ROOT/buildroot-ihost" -name 'ga-lora*' 2>/dev/null | head -1)" ] && PASS "iHost / shared overlay carry no ga-lora files (DSGW-only by construction)" || FAIL "iHost free" "found"
grep -qx 'BR2_PACKAGE_SPI_TOOLS=y' "$ROOT/buildroot-dsgw210/configs/dsgw210_defconfig" && PASS "dsgw210 defconfig ships spi-tools (spi-pipe/spi-config)" || FAIL "spi-tools" "missing"
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
