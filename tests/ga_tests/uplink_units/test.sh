#!/bin/sh
# Uplink door: the three ways a device can still be reached, and the one rule
# each of them has to keep. Runs HOST-SIDE against the real scripts and unit
# files in this tree — no device, no image.
#
# Why this file exists (measured 2026-09-19 on a converged bench device):
#   * the flash-time Ethernet override could not work at all. ga-ethernet-retire
#     deleted the marker at 12:48:11.850, ga-ethernet-guard read it at
#     12:48:14.940 and found nothing. The on-site path the comments promise —
#     put the card in a reader, recreate the file, boot — was a no-op on every
#     device that had ever converged. A field unit moved to an Ethernet-only
#     site came up dark with no way in (KIB-SON-00000037, 2026-09-18).
#   * the LTE fallback disables itself in silence when the image was built
#     without the shared key: one `exit 0`, no log line, fleet-wide.
#   * a CONFIG/network import from the SD card wipes EVERY NetworkManager
#     profile, including the install WiFi the device is rescued with.
#
# Each check runs the real thing and asserts the OUTCOME. The must-not-flag
# half is as important as the must-flag half: a gate that fires on a healthy
# device gets overridden by reflex.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OVL="$ROOT/buildroot-ihost/rootfs-overlay"
UNITS="$OVL/etc/systemd/system"
SBIN="$OVL/usr/sbin"
WORK="$(mktemp -d -t uplink-units-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }

echo ""
echo "=== uplink door ==="

# --- 1. Ethernet: the marker is read before it is retired -------------------
echo "--- ethernet override ordering ---"
if grep -qE "^After=.*\bga-ethernet-guard\.service\b" "$UNITS/ga-ethernet-retire.service"; then
    PASS "retire is ordered after the unit that reads the marker"
else
    FAIL "retire is ordered after ga-ethernet-guard" "no After= line — retire will outrun apply and the on-site override is dead"
fi
if grep -qE "^Requires=" "$UNITS/ga-ethernet-retire.service"; then
    FAIL "retire does not REQUIRE the guard" "Requires= would fail the retirement when the guard is absent"
else
    PASS "ordering only, no Requires (a late .path trigger must not hang)"
fi

# --- 2. Ethernet: the retirement is loud when nothing declares the uplink ---
echo "--- retirement is loud ---"
mkdir -p "$WORK/boot" "$WORK/data" "$WORK/share" "$WORK/addons"
: > "$WORK/boot/ga-ethernet-force"
run_retire() {
    GA_FORCE_BOOT="$WORK/boot/ga-ethernet-force" \
    GA_ENV_FILE="$1" \
    GA_SHARE_DIR="$WORK/share" \
    GA_ADDON_DATA_GLOB="$WORK/addons/*_ga_manager" \
    GA_LABEL_FILE="$WORK/data/ga-device-label" \
    sh "$SBIN/ga-manage-ethernet" retire 2>&1
}
OUT="$(run_retire "$WORK/data/ga-env.conf")"
if echo "$OUT" | grep -q "WARNING"; then
    PASS "no declaration anywhere -> retirement warns about the next boot"
else
    FAIL "retirement warns when nothing declares Ethernet" "$(echo "$OUT" | tr '\n' ';')"
fi
if [ -f "$WORK/boot/ga-ethernet-force" ]; then
    FAIL "retirement removes the marker" "file still present"
else
    PASS "retirement removes the marker"
fi
# must-NOT-flag: a device the fleet HAS declared must retire quietly
: > "$WORK/boot/ga-ethernet-force"
printf 'GA_ETHERNET_ENABLED=true\n' > "$WORK/data/ga-env.conf"
OUT="$(run_retire "$WORK/data/ga-env.conf")"
if echo "$OUT" | grep -q "WARNING"; then
    FAIL "a declared device retires quietly" "warned although GA_ETHERNET_ENABLED=true"
else
    PASS "a declared device retires quietly (no false alarm)"
fi

# --- 3. LTE: the fallback never disables itself in silence ------------------
echo "--- LTE fallback is never silent ---"
OUT="$(KEY_FILE=/nonexistent sh -c 'sed "s#^KEY_FILE=.*#KEY_FILE=/nonexistent/openstick.key#" "$1" > "$2/stick.sh"; sh "$2/stick.sh" 2>&1' _ "$SBIN/ga-openstick-autoconnect" "$WORK")"
if echo "$OUT" | grep -qi "NO SHARED KEY"; then
    PASS "missing shared key is announced, not swallowed"
else
    FAIL "missing shared key is announced" "script said: $(echo "$OUT" | tr '\n' ';')"
fi

# --- 4. The built-in WiFi fallback comes back after a CONFIG import ---------
echo "--- WiFi fallback restore ---"
mkdir -p "$WORK/nm" "$WORK/share-wifi"
printf '[connection]\nid=GreenAutarky-Install\n' > "$WORK/share-wifi/GreenAutarky-Install.nmconnection"
cat > "$WORK/nmcli" <<'STUB'
#!/bin/sh
echo "$*" >> "$NMCLI_LOG"
STUB
chmod +x "$WORK/nmcli"
: > "$WORK/nmcli.log"
GA_WIFI_DEFAULT="$WORK/share-wifi/GreenAutarky-Install.nmconnection" \
GA_NM_DIR="$WORK/nm" GA_NMCLI="$WORK/nmcli" NMCLI_LOG="$WORK/nmcli.log" \
  sh "$SBIN/ga-wifi-fallback-restore" >/dev/null 2>&1
if [ -f "$WORK/nm/GreenAutarky-Install.nmconnection" ] && grep -q "connection reload" "$WORK/nmcli.log"; then
    PASS "a wiped fallback profile is restored and NetworkManager reloaded"
else
    FAIL "wiped fallback is restored" "file or reload missing"
fi
# must-NOT-flag: nothing to do when the profile is there
: > "$WORK/nmcli.log"
GA_WIFI_DEFAULT="$WORK/share-wifi/GreenAutarky-Install.nmconnection" \
GA_NM_DIR="$WORK/nm" GA_NMCLI="$WORK/nmcli" NMCLI_LOG="$WORK/nmcli.log" \
  sh "$SBIN/ga-wifi-fallback-restore" >/dev/null 2>&1
if [ -s "$WORK/nmcli.log" ]; then
    FAIL "an intact device is left alone" "NetworkManager was reloaded for nothing"
else
    PASS "an intact device is left alone (no reload, no churn)"
fi
if grep -qE "^After=.*hassos-config\.service" "$UNITS/ga-wifi-fallback-restore.service"; then
    PASS "restore runs after the import that wipes"
else
    FAIL "restore runs after hassos-config" "wrong order — the restore would be wiped again"
fi
if [ -L "$UNITS/multi-user.target.wants/ga-wifi-fallback-restore.service" ]; then
    PASS "restore unit is enabled"
else
    FAIL "restore unit is enabled" "no multi-user.target.wants symlink"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
