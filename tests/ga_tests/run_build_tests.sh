#!/bin/bash
# Build-time test runner — verifies build output tree after ga_build.sh
# Usage: run_build_tests.sh <output_dir>
#   e.g.: run_build_tests.sh /build/ga_output
#
# Exit code: number of failures (0 = all pass)
set -u

OUT="${1:?Usage: $0 <output_dir>}"
TARGET="${OUT}/target"

pass=0 fail=0 skip=0

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' RESET='\033[0m'
[[ -t 1 ]] || { GREEN=''; RED=''; YELLOW=''; RESET=''; }

_pass() { echo -e "${GREEN}  PASS${RESET}  $1"; pass=$((pass+1)); }
_fail() { echo -e "${RED}  FAIL${RESET}  $1"; fail=$((fail+1)); }
_skip() { echo -e "${YELLOW}  SKIP${RESET}  $1 ($2)"; skip=$((skip+1)); }

echo ""
echo "=== Build-time verification tests ==="
echo "  Output: $OUT"
echo ""

# =========================================================================
# Config files on rootfs
# =========================================================================
echo "--- Config files ---"

# CFG-01: telegraf.conf exists
[[ -f "${TARGET}/etc/telegraf/telegraf.conf" ]] \
  && _pass "CFG-01: telegraf.conf exists on rootfs" \
  || _fail "CFG-01: telegraf.conf missing"

# CFG-02: telegraf.conf has device_label
grep -q 'device_label' "${TARGET}/etc/telegraf/telegraf.conf" 2>/dev/null \
  && _pass "CFG-02: telegraf.conf has device_label tag" \
  || _fail "CFG-02: telegraf.conf missing device_label"

# CFG-03: telegraf.conf has uuid
grep -q 'uuid' "${TARGET}/etc/telegraf/telegraf.conf" 2>/dev/null \
  && _pass "CFG-03: telegraf.conf has uuid tag" \
  || _fail "CFG-03: telegraf.conf missing uuid"

# CFG-06: telegraf.service has safe default
grep -q 'DEVICE_LABEL' "${TARGET}/etc/systemd/system/telegraf.service" 2>/dev/null \
  && _pass "CFG-06: telegraf.service has DEVICE_LABEL" \
  || _fail "CFG-06: telegraf.service missing DEVICE_LABEL"

# CFG-04: telegraf.conf has wireless input
grep -q '\[\[inputs.wireless\]\]' "${TARGET}/etc/telegraf/telegraf.conf" 2>/dev/null \
  && _pass "CFG-04: telegraf.conf has WiFi signal input (inputs.wireless)" \
  || _fail "CFG-04: telegraf.conf missing inputs.wireless"

# CFG-05: telegraf.conf monitors wlan0
grep -q 'wlan0' "${TARGET}/etc/telegraf/telegraf.conf" 2>/dev/null \
  && _pass "CFG-05: telegraf.conf monitors wlan0 interface" \
  || _fail "CFG-05: telegraf.conf missing wlan0 in net interfaces"

# CFG-07: fluent-bit.conf exists
[[ -f "${TARGET}/etc/fluent-bit/fluent-bit.conf" ]] \
  && _pass "CFG-07: fluent-bit.conf exists on rootfs" \
  || _fail "CFG-07: fluent-bit.conf missing"

# CFG-08: fluent-bit.conf has device_label in record_modifier
grep -q 'device_label' "${TARGET}/etc/fluent-bit/fluent-bit.conf" 2>/dev/null \
  && _pass "CFG-08: fluent-bit.conf has device_label" \
  || _fail "CFG-08: fluent-bit.conf missing device_label"

# CFG-11: fluent-bit.service has safe default
FB_SVC="${TARGET}/usr/lib/systemd/system/fluent-bit.service"
grep -q 'DEVICE_LABEL' "$FB_SVC" 2>/dev/null \
  && _pass "CFG-11: fluent-bit.service has DEVICE_LABEL" \
  || _fail "CFG-11: fluent-bit.service missing DEVICE_LABEL"

# CFG-13/14: GA DNS fallback entries in ga-defaults (applied at runtime by ga-overlay-init)
grep -q 'influx.greenautarky.com' "${TARGET}/usr/share/ga-defaults/hosts" 2>/dev/null \
  && _pass "CFG-13: ga-defaults/hosts has influx fallback" \
  || _fail "CFG-13: ga-defaults/hosts missing influx fallback"

grep -q 'loki.greenautarky.com' "${TARGET}/usr/share/ga-defaults/hosts" 2>/dev/null \
  && _pass "CFG-14: ga-defaults/hosts has loki fallback" \
  || _fail "CFG-14: ga-defaults/hosts missing loki fallback"

# CFG-15/16: Service ordering
grep -q 'netbird' "${TARGET}/etc/systemd/system/telegraf.service" 2>/dev/null \
  && _pass "CFG-15: telegraf.service ordered after netbird" \
  || _fail "CFG-15: telegraf.service missing netbird ordering"

grep -q 'netbird' "$FB_SVC" 2>/dev/null \
  && _pass "CFG-16: fluent-bit.service ordered after netbird" \
  || _fail "CFG-16: fluent-bit.service missing netbird ordering"

# CFG-19/20: parsers.conf
[[ -f "${TARGET}/etc/fluent-bit/parsers.conf" ]] \
  && _pass "CFG-19: parsers.conf exists" \
  || _fail "CFG-19: parsers.conf missing"

grep -q 'homeassistant' "${TARGET}/etc/fluent-bit/parsers.conf" 2>/dev/null \
  && _pass "CFG-20: parsers.conf has homeassistant parser" \
  || _fail "CFG-20: parsers.conf missing homeassistant parser"

# CFG-22: storage buffer
grep -qE 'storage\.total_limit_size\s+300M' "${TARGET}/etc/fluent-bit/fluent-bit.conf" 2>/dev/null \
  && _pass "CFG-22: fluent-bit storage buffer >= 300M" \
  || _fail "CFG-22: fluent-bit storage buffer not 300M"

# CFG-23: ga-manage-ethernet script on rootfs
[[ -x "${TARGET}/usr/sbin/ga-manage-ethernet" ]] \
  && _pass "CFG-23: ga-manage-ethernet script exists and executable" \
  || _fail "CFG-23: ga-manage-ethernet NOT found on rootfs"

# CFG-24: ga-ethernet-guard.service exists and enabled
[[ -f "${TARGET}/etc/systemd/system/ga-ethernet-guard.service" ]] \
  && _pass "CFG-24a: ga-ethernet-guard.service unit exists" \
  || _fail "CFG-24a: ga-ethernet-guard.service NOT found"
[[ -L "${TARGET}/etc/systemd/system/multi-user.target.wants/ga-ethernet-guard.service" ]] \
  && _pass "CFG-24b: ga-ethernet-guard.service enabled at boot" \
  || _fail "CFG-24b: ga-ethernet-guard.service NOT enabled"

echo ""
echo "--- NetworkManager WiFi defaults ---"

NM_CONF="${TARGET}/etc/NetworkManager/NetworkManager.conf"
if [[ -f "$NM_CONF" ]]; then
  # WIFI-01: MAC randomization disabled for scanning
  grep -q 'wifi.scan-rand-mac-address=no' "$NM_CONF" 2>/dev/null \
    && _pass "WIFI-01: scan MAC randomization disabled" \
    || _fail "WIFI-01: scan MAC randomization NOT disabled"

  # WIFI-02: Power save disabled
  grep -q 'wifi.powersave=2' "$NM_CONF" 2>/dev/null \
    && _pass "WIFI-02: WiFi power save disabled" \
    || _fail "WIFI-02: WiFi power save NOT disabled"

  # WIFI-03: Permanent MAC address
  grep -q 'wifi.cloned-mac-address=permanent' "$NM_CONF" 2>/dev/null \
    && _pass "WIFI-03: cloned-mac-address set to permanent" \
    || _fail "WIFI-03: cloned-mac-address NOT set to permanent"

  # WIFI-04: Infinite autoconnect retries
  grep -q 'connection.autoconnect-retries=0' "$NM_CONF" 2>/dev/null \
    && _pass "WIFI-04: infinite autoconnect retries (0)" \
    || _fail "WIFI-04: autoconnect-retries NOT set to 0"

  # WIFI-05: Hidden SSID scanning enabled
  grep -q 'wifi.hidden=true' "$NM_CONF" 2>/dev/null \
    && _pass "WIFI-05: hidden SSID scanning enabled" \
    || _fail "WIFI-05: hidden SSID scanning NOT enabled"

  # WIFI-06: High autoconnect priority
  grep -q 'connection.autoconnect-priority=100' "$NM_CONF" 2>/dev/null \
    && _pass "WIFI-06: WiFi autoconnect priority=100" \
    || _fail "WIFI-06: WiFi autoconnect priority NOT set to 100"

  # WIFI-07: match-device targets wifi type
  grep -q 'match-device=type:wifi' "$NM_CONF" 2>/dev/null \
    && _pass "WIFI-07: WiFi defaults scoped to type:wifi" \
    || _fail "WIFI-07: WiFi defaults NOT scoped to type:wifi"
else
  _skip "WIFI-01..07" "NetworkManager.conf not found"
fi

# WIFI-08: GreenAutarky-Install fallback WiFi connection
# NOTE: WiFi config lives in /usr/share/ga-wifi/ (not /etc/NetworkManager/system-connections/)
# because HAOS bind-mounts an overlay partition over /etc/NM/system-connections/.
# A first-boot service (ga-wifi-install.service) copies it to the overlay.
INSTALL_WIFI="${TARGET}/usr/share/ga-wifi/GreenAutarky-Install.nmconnection"
if [[ -f "$INSTALL_WIFI" ]]; then
  grep -q 'ssid=GreenAutarky-Install' "$INSTALL_WIFI" 2>/dev/null \
    && _pass "WIFI-08a: Install WiFi SSID configured" \
    || _fail "WIFI-08a: Install WiFi SSID missing"
  grep -q 'autoconnect-priority=-10' "$INSTALL_WIFI" 2>/dev/null \
    && _pass "WIFI-08b: Install WiFi low priority (Ethernet wins)" \
    || _fail "WIFI-08b: Install WiFi priority not set to -10"
  # Verify PSK was injected (not placeholder)
  if grep -q '__WIFI_INSTALL_PSK__' "$INSTALL_WIFI" 2>/dev/null; then
    _fail "WIFI-08c: Install WiFi PSK is still placeholder (secrets/wifi-install.psk missing?)"
  else
    grep -q 'psk=' "$INSTALL_WIFI" 2>/dev/null \
      && _pass "WIFI-08c: Install WiFi PSK injected" \
      || _fail "WIFI-08c: Install WiFi PSK field missing"
  fi
  # Verify permissions (NM requires 0600)
  PERMS=$(stat -c '%a' "$INSTALL_WIFI" 2>/dev/null)
  [[ "$PERMS" == "600" ]] \
    && _pass "WIFI-08d: Install WiFi file permissions 0600" \
    || _fail "WIFI-08d: Install WiFi permissions $PERMS (need 0600)"
else
  _fail "WIFI-08: GreenAutarky-Install.nmconnection not found in /usr/share/ga-wifi/"
fi

# WIFI-09: ga-overlay-init handles WiFi copy (consolidated service)
grep -q 'ga-wifi' "${TARGET}/usr/sbin/ga-overlay-init" 2>/dev/null \
  && _pass "WIFI-09: ga-overlay-init copies WiFi config to overlay" \
  || _fail "WIFI-09: ga-overlay-init missing WiFi copy logic"

# WIFI-11: OpenStick WiFi shared secret injected
OSTICK_KEY="${TARGET}/usr/share/ga-wifi/openstick-wifi.key"
if [[ -f "$OSTICK_KEY" ]]; then
  OSTICK_PERMS=$(stat -c '%a' "$OSTICK_KEY" 2>/dev/null)
  [[ "$OSTICK_PERMS" == "600" ]] \
    && _pass "WIFI-11a: openstick-wifi.key permissions 0600" \
    || _fail "WIFI-11a: openstick-wifi.key permissions $OSTICK_PERMS (need 0600)"
  OSTICK_LEN=$(tr -d '\n' < "$OSTICK_KEY" | wc -c)
  [[ "$OSTICK_LEN" == "64" ]] \
    && _pass "WIFI-11b: openstick-wifi.key is 64 hex chars (256-bit)" \
    || _fail "WIFI-11b: openstick-wifi.key length $OSTICK_LEN (expected 64)"
  grep -qE '^[0-9a-f]{64}$' "$OSTICK_KEY" 2>/dev/null \
    && _pass "WIFI-11c: openstick-wifi.key is valid hex" \
    || _fail "WIFI-11c: openstick-wifi.key is not valid hex"
else
  _skip "WIFI-11a..c" "openstick-wifi.key not found (secrets/openstick-wifi.key missing?)"
fi

# WIFI-10: WiFi config must NOT be in /etc/NM/system-connections (overlay hides it!)
if [[ -f "${TARGET}/etc/NetworkManager/system-connections/GreenAutarky-Install.nmconnection" ]]; then
  _fail "WIFI-10: WiFi config in /etc/NM/system-connections/ — will be hidden by HAOS overlay mount! Move to /usr/share/ga-wifi/"
else
  _pass "WIFI-10: WiFi config correctly NOT in overlaid /etc/NM/system-connections/"
fi

# --- HAOS Overlay Safety Checks ---
# HAOS bind-mounts /mnt/overlay/etc/{hosts,hostname,systemd/timesyncd.conf,...}
# over the rootfs. Any file placed in these paths at build time will be INVISIBLE
# at runtime. GA defaults must live in /usr/share/ga-defaults/ and be copied to
# the overlay by ga-overlay-init.service on first boot.

# OVL-01: No GA content in overlaid /etc/hosts
if [[ -f "${TARGET}/etc/hosts" ]] && grep -q 'greenautarky' "${TARGET}/etc/hosts" 2>/dev/null; then
  _fail "OVL-01: /etc/hosts has GA entries — will be hidden by HAOS overlay! Use /usr/share/ga-defaults/hosts"
else
  _pass "OVL-01: /etc/hosts does not have GA entries (safe)"
fi

# OVL-02: GA hosts defaults in safe location
[[ -f "${TARGET}/usr/share/ga-defaults/hosts" ]] && grep -q 'greenautarky' "${TARGET}/usr/share/ga-defaults/hosts" 2>/dev/null \
  && _pass "OVL-02: GA DNS entries in /usr/share/ga-defaults/hosts" \
  || _fail "OVL-02: GA DNS entries missing from /usr/share/ga-defaults/hosts"

# OVL-03: GA timesyncd.conf not in overlaid path (upstream Buildroot default is OK)
if grep -q 'greenautarky\|time.cloudflare.com' "${TARGET}/etc/systemd/timesyncd.conf" 2>/dev/null; then
  _fail "OVL-03: GA timesyncd.conf in /etc/systemd/ — will be hidden by HAOS overlay! Use /usr/share/ga-defaults/"
else
  _pass "OVL-03: GA timesyncd.conf not in overlaid path (safe)"
fi

# OVL-04: timesyncd defaults in safe location
[[ -f "${TARGET}/usr/share/ga-defaults/timesyncd.conf" ]] \
  && _pass "OVL-04: timesyncd.conf in /usr/share/ga-defaults/" \
  || _fail "OVL-04: timesyncd.conf missing from /usr/share/ga-defaults/"

# OVL-05: ga-overlay-init service exists and enabled
[[ -f "${TARGET}/etc/systemd/system/ga-overlay-init.service" ]] \
  && _pass "OVL-05a: ga-overlay-init.service exists" \
  || _fail "OVL-05a: ga-overlay-init.service NOT found"
[[ -L "${TARGET}/etc/systemd/system/multi-user.target.wants/ga-overlay-init.service" ]] \
  && _pass "OVL-05b: ga-overlay-init.service enabled at boot" \
  || _fail "OVL-05b: ga-overlay-init.service NOT enabled"

# --- Additional rootfs checks ---

# CFG-25: audio-setup masking handled by ga-overlay-init at runtime
# Cannot mask at build time — Buildroot's preset phase fails on masked units.
grep -q 'audio-setup' "${TARGET}/usr/sbin/ga-overlay-init" 2>/dev/null \
  && _pass "CFG-25: ga-overlay-init masks audio-setup.service at runtime" \
  || _fail "CFG-25: ga-overlay-init missing audio-setup masking"

# CFG-26: NM connectivity check configured
grep -q 'checkonline.greenautarky.com' "${TARGET}/etc/NetworkManager/NetworkManager.conf" 2>/dev/null \
  && _pass "CFG-26a: NM connectivity check URI configured" \
  || _fail "CFG-26a: NM connectivity check URI missing"
grep -q 'response=NetworkManager is online' "${TARGET}/etc/NetworkManager/NetworkManager.conf" 2>/dev/null \
  && _pass "CFG-26b: NM connectivity check response string set" \
  || _fail "CFG-26b: NM connectivity check response string missing"

# CFG-27: Fluent-Bit systemd filter includes ga-disk-guard.service
grep -q 'ga-disk-guard.service' "${TARGET}/etc/fluent-bit/fluent-bit.conf" 2>/dev/null \
  && _pass "CFG-27: Fluent-Bit captures ga-disk-guard logs" \
  || _fail "CFG-27: Fluent-Bit missing ga-disk-guard.service in systemd filter"

echo ""
echo "--- Environment ---"

# ENV-01: ga-env.conf
[[ -f "${TARGET}/etc/ga-env.conf" ]] \
  && _pass "ENV-01: ga-env.conf exists" \
  || _fail "ENV-01: ga-env.conf missing"

# ENV-02: GA_ENV value
GA_ENV_VAL="$(grep '^GA_ENV=' "${TARGET}/etc/ga-env.conf" 2>/dev/null | cut -d= -f2)"
case "$GA_ENV_VAL" in
  dev|prod) _pass "ENV-02: GA_ENV=$GA_ENV_VAL" ;;
  *) _fail "ENV-02: GA_ENV invalid: '$GA_ENV_VAL'" ;;
esac

# ENV-08: os-release (may be at /etc/os-release or /usr/lib/os-release)
{ grep -q 'GA_BUILD_ID' "${TARGET}/etc/os-release" 2>/dev/null || \
  grep -q 'GA_BUILD_ID' "${TARGET}/usr/lib/os-release" 2>/dev/null; } \
  && _pass "ENV-08: os-release has GA_BUILD_ID" \
  || _fail "ENV-08: os-release missing GA_BUILD_ID"

echo ""
echo "--- Services ---"

# CRASH-01: crash detection services enabled
SVC_DIR="${TARGET}/etc/systemd/system"
for svc in ga-crash-marker.service ga-boot-check.service; do
  if [[ -f "${TARGET}/usr/lib/systemd/system/${svc}" ]] || \
     [[ -L "${SVC_DIR}/sysinit.target.wants/${svc}" ]]; then
    _pass "CRASH-01: $svc installed"
  else
    _fail "CRASH-01: $svc missing"
  fi
done

# Service enable checks
for svc in netbird.service telegraf.service fluent-bit.service; do
  found=false
  for wants_dir in "${SVC_DIR}/multi-user.target.wants" "${TARGET}/usr/lib/systemd/system-preset"; do
    if [[ -L "${wants_dir}/${svc}" ]] || [[ -f "${wants_dir}/${svc}" ]]; then
      found=true; break
    fi
  done
  $found && _pass "SVC: $svc enabled" || _fail "SVC: $svc NOT enabled"
done

# DG-01: disk guard installed
[[ -f "${TARGET}/usr/sbin/ga_disk_guard" ]] || [[ -f "${TARGET}/usr/bin/ga_disk_guard" ]] \
  && _pass "DG-01: disk guard script installed" \
  || _fail "DG-01: disk guard script missing"

echo ""
echo "--- Binaries ---"

# NetBird
NB="${TARGET}/usr/bin/netbird"
[[ -x "$NB" ]] \
  && _pass "BIN: netbird binary exists" \
  || _fail "BIN: netbird binary missing"

# OS-Agent
[[ -x "${TARGET}/usr/bin/os-agent" ]] \
  && _pass "BIN: os-agent binary exists" \
  || _fail "BIN: os-agent binary missing"

echo ""
echo "--- Build artifacts ---"

# SD-01: Image file exists
IMG_XZ="$(ls "${OUT}/images/"*.img.xz 2>/dev/null | head -1)"
[[ -n "$IMG_XZ" ]] \
  && _pass "SD-01: Image file exists: $(basename "$IMG_XZ")" \
  || _fail "SD-01: No .img.xz found"

# RAUC bundle
RAUCB="$(ls "${OUT}/images/"*.raucb 2>/dev/null | head -1)"
[[ -n "$RAUCB" ]] \
  && _pass "BLD: RAUC bundle exists" \
  || _fail "BLD: No .raucb found"

# version.json
VER_JSON="${OUT}/build/hassio-1.0.0/version.json"
if [[ -f "$VER_JSON" ]]; then
  grep -q 'greenautarky' "$VER_JSON" \
    && _pass "BLD: version.json references greenautarky" \
    || _fail "BLD: version.json missing greenautarky"

  CORE_TAG="$(jq -r '.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  [[ "$CORE_TAG" =~ ^2025\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    && _pass "BLD: Core image tag is '$CORE_TAG'" \
    || _fail "BLD: Core tag is '$CORE_TAG' (expected HA calver like 2025.11.3 or 2025.11.3.1)"

  # REG: Verify all image refs use greenautarky (not upstream home-assistant or oliverc7)
  SUP_IMG="$(jq -r '.images.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
  CORE_IMG="$(jq -r '.images.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  [[ "$SUP_IMG" == *greenautarky* ]] \
    && _pass "REG-01: Supervisor image is greenautarky: $SUP_IMG" \
    || _fail "REG-01: Supervisor image is NOT greenautarky: $SUP_IMG"
  [[ "$CORE_IMG" == *greenautarky* ]] \
    && _pass "REG-02: Core image is greenautarky: $CORE_IMG" \
    || _fail "REG-02: Core image is NOT greenautarky: $CORE_IMG"

  # REG: No upstream or oliverc7 refs in version.json
  if grep -qE 'oliverc7|iHost-Open-Source' "$VER_JSON" 2>/dev/null; then
    _fail "REG-03: version.json has stale upstream refs (oliverc7 or iHost-Open-Source)"
  else
    _pass "REG-03: version.json has no stale upstream refs"
  fi

  # -----------------------------------------------------------------------
  # Version chain verification — catch "latest" or wrong-registry values
  # that break provisioning
  # -----------------------------------------------------------------------
  echo ""
  echo "--- Version chain verification ---"

  # VER-01: supervisor version is not "latest"
  VER_SUP="$(jq -r '.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
  if [[ "$VER_SUP" == "latest" ]]; then
    _fail "VER-01: version.json supervisor is 'latest' (must be a real version)"
  elif [[ "$VER_SUP" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    _pass "VER-01: version.json supervisor is a real version: $VER_SUP"
  else
    _fail "VER-01: version.json supervisor is unexpected value: '$VER_SUP'"
  fi

  # VER-02: core version is not "latest"
  VER_CORE="$(jq -r '.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  if [[ "$VER_CORE" == "latest" ]]; then
    _fail "VER-02: version.json core is 'latest' (must be a real version)"
  elif [[ "$VER_CORE" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+ ]]; then
    _pass "VER-02: version.json core is a real version: $VER_CORE"
  else
    _fail "VER-02: version.json core is unexpected value: '$VER_CORE'"
  fi

  # VER-03: homeassistant.tinker is not "latest"
  VER_TINKER="$(jq -r '.homeassistant.tinker // "unknown"' "$VER_JSON" 2>/dev/null)"
  if [[ "$VER_TINKER" == "latest" ]]; then
    _fail "VER-03: version.json tinker HA is 'latest' (must be a real version)"
  elif [[ "$VER_TINKER" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+ ]]; then
    _pass "VER-03: version.json tinker HA is a real version: $VER_TINKER"
  else
    _fail "VER-03: version.json tinker HA is unexpected value: '$VER_TINKER'"
  fi

  # VER-04: supervisor image uses greenautarky registry (both image and images)
  VER_IMG_SUP="$(jq -r '.image.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
  VER_IMGS_SUP="$(jq -r '.images.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
  if [[ "$VER_IMG_SUP" == *greenautarky* ]] && [[ "$VER_IMGS_SUP" == *greenautarky* ]]; then
    _pass "VER-04: supervisor image refs both use greenautarky"
  else
    [[ "$VER_IMG_SUP" != *greenautarky* ]] && _fail "VER-04: image.supervisor is NOT greenautarky: $VER_IMG_SUP"
    [[ "$VER_IMGS_SUP" != *greenautarky* ]] && _fail "VER-04: images.supervisor is NOT greenautarky: $VER_IMGS_SUP"
  fi

  # VER-05: core image uses greenautarky registry (both image and images)
  VER_IMG_CORE="$(jq -r '.image.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  VER_IMGS_CORE="$(jq -r '.images.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  if [[ "$VER_IMG_CORE" == *greenautarky* ]] && [[ "$VER_IMGS_CORE" == *greenautarky* ]]; then
    _pass "VER-05: core image refs both use greenautarky"
  else
    [[ "$VER_IMG_CORE" != *greenautarky* ]] && _fail "VER-05: image.core is NOT greenautarky: $VER_IMG_CORE"
    [[ "$VER_IMGS_CORE" != *greenautarky* ]] && _fail "VER-05: images.core is NOT greenautarky: $VER_IMGS_CORE"
  fi

  # VER-06: OTA URL points to greenautarky
  VER_OTA="$(jq -r '.ota // "unknown"' "$VER_JSON" 2>/dev/null)"
  [[ "$VER_OTA" == *greenautarky* ]] \
    && _pass "VER-06: OTA URL points to greenautarky" \
    || _fail "VER-06: OTA URL does NOT point to greenautarky: $VER_OTA"

  # VER-07: Core image digest matches GHCR (not stale cache)
  IMAGES_DIR="$(ls -d ${OUT}/build/hassio-*/images 2>/dev/null | head -n 1 || true)"
  if [[ -d "$IMAGES_DIR" ]] && command -v skopeo >/dev/null 2>&1; then
    CORE_TAR="$(ls "$IMAGES_DIR"/*homeassistant*.tar 2>/dev/null | head -n 1 || true)"
    if [[ -n "$CORE_TAR" ]]; then
      # Extract digest from tar filename (format: ...@sha256_XXXX.tar)
      BUILD_DIGEST="$(basename "$CORE_TAR" .tar | grep -oP 'sha256_\K[a-f0-9]+' || true)"
      # Query current digest from GHCR
      CORE_REF="$(jq -r '.images.core // .image.core' "$VER_JSON" 2>/dev/null | sed "s/{machine}/${MACHINE:-tinker}/;s/{arch}/${ARCH:-armv7}/")"
      CORE_TAG="$(jq -r '.homeassistant."'${MACHINE:-tinker}'" // .core' "$VER_JSON" 2>/dev/null)"
      if [[ -n "$CORE_REF" ]] && [[ -n "$CORE_TAG" ]] && [[ "$CORE_TAG" != "null" ]]; then
        GHCR_DIGEST="$(skopeo inspect --override-arch arm --override-variant v7 "docker://${CORE_REF}:${CORE_TAG}" 2>/dev/null | jq -r '.Digest' | sed 's/sha256://' || true)"
        if [[ -n "$BUILD_DIGEST" ]] && [[ -n "$GHCR_DIGEST" ]]; then
          if [[ "$BUILD_DIGEST" == "$GHCR_DIGEST" ]]; then
            _pass "VER-07: Core image digest matches GHCR (fresh)"
          else
            _fail "VER-07: Core image STALE — build digest ${BUILD_DIGEST:0:12} != GHCR ${GHCR_DIGEST:0:12} (cached tar not refreshed)"
          fi
        else
          _skip "VER-07" "could not extract digests (build=$BUILD_DIGEST ghcr=$GHCR_DIGEST)"
        fi
      else
        _skip "VER-07" "could not resolve core image ref from version.json"
      fi
    else
      _skip "VER-07" "no core tar found in $IMAGES_DIR"
    fi
  else
    _skip "VER-07" "skopeo not available or no images dir"
  fi

else
  _skip "BLD: version.json" "only present after full build"
fi

echo ""
echo "--- Registry consistency ---"

# REG-04: hassos-supervisor uses greenautarky image
HSUP="${TARGET}/usr/sbin/hassos-supervisor"
if [[ -f "$HSUP" ]]; then
  grep -q 'SUPERVISOR_IMAGE="ghcr.io/greenautarky/' "$HSUP" \
    && _pass "REG-04: hassos-supervisor SUPERVISOR_IMAGE is greenautarky" \
    || _fail "REG-04: hassos-supervisor SUPERVISOR_IMAGE is NOT greenautarky"

  # REG-05: fallback URL uses greenautarky
  grep -q 'greenautarky/haos-version' "$HSUP" \
    && _pass "REG-05: hassos-supervisor fallback URL is greenautarky" \
    || _fail "REG-05: hassos-supervisor fallback URL is NOT greenautarky"

  # REG-06: no oliverc7 or iHost-Open-Source references
  if grep -qE 'oliverc7|iHost-Open-Source' "$HSUP" 2>/dev/null; then
    _fail "REG-06: hassos-supervisor has stale upstream refs"
  else
    _pass "REG-06: hassos-supervisor has no stale upstream refs"
  fi
else
  _skip "REG-04/05/06: hassos-supervisor" "not found in target"
fi

# REG-07: Supervisor image tar uses greenautarky (only after full build)
SUP_TAR="$(ls "${OUT}/build/hassio-1.0.0/images/"*hassio-supervisor* 2>/dev/null | head -1)"
if [[ -n "$SUP_TAR" ]]; then
  [[ "$SUP_TAR" == *greenautarky* ]] \
    && _pass "REG-07: Supervisor tar is greenautarky: $(basename "$SUP_TAR")" \
    || _fail "REG-07: Supervisor tar is NOT greenautarky: $(basename "$SUP_TAR")"
else
  _skip "REG-07: Supervisor tar" "only present after full build"
fi

# BLD-FE: Verify HA Core container image contains greenautarky onboarding frontend
echo ""
echo "--- Frontend in Core image ---"

CORE_TAR="$(ls "${OUT}/build/hassio-1.0.0/images/"*homeassistant* 2>/dev/null | head -1)"
if [[ -n "$CORE_TAR" ]]; then
  # Docker archive tars contain layer tars; list recursively to find frontend files
  # The greenautarky-setup.html is installed via the wheel into the HA Core image
  CORE_FE_FOUND=false
  # Collect ALL layer tars from the archive — images may contain multiple formats
  # simultaneously (OCI directory layout + Docker flat format). Search all of them.
  #   1. <hash>/layer.tar  (OCI legacy directory layout)
  #   2. blobs/sha256/<hash>  (OCI content-addressable)
  #   3. <hash>.tar  (Docker save flat format)
  LAYER_LIST="$(tar -tf "$CORE_TAR" 2>/dev/null | grep -E 'layer\.tar$|^blobs/|^[a-f0-9]{64}\.tar$' || true)"
  for layer in $LAYER_LIST; do
    if tar -xf "$CORE_TAR" --to-stdout "$layer" 2>/dev/null | tar -tf - 2>/dev/null | grep -q 'greenautarky-setup\.html'; then
      CORE_FE_FOUND=true
      break
    fi
  done
  if $CORE_FE_FOUND; then
    _pass "BLD-FE-01: Core image contains greenautarky-setup.html"
  else
    _fail "BLD-FE-01: Core image does NOT contain greenautarky-setup.html"
  fi

  # BLD-FE-02: Verify the greenautarky-setup JS entrypoint bundle exists (separate from .html)
  CORE_JS_FOUND=false
  for layer in $LAYER_LIST; do
    if tar -xf "$CORE_TAR" --to-stdout "$layer" 2>/dev/null | tar -tf - 2>/dev/null | grep -qE 'greenautarky-setup.*\.js'; then
      CORE_JS_FOUND=true
      break
    fi
  done
  if $CORE_JS_FOUND; then
    _pass "BLD-FE-02: Core image contains greenautarky-setup JS bundle"
  else
    _fail "BLD-FE-02: Core image does NOT contain greenautarky-setup JS bundle"
  fi
else
  _skip "BLD-FE-01/02: Core image frontend check" "only present after full build"
fi

# =========================================================================
# Device tree verification
# Compares the patched device tree against a known-good reference to catch
# silent patch failures (fuzz, offset, dropped hunks)
# =========================================================================
echo ""
echo "--- Device tree verification ---"

DTSI_EXPECTED=""
DTSI_ACTUAL=""

# Find the reference file
for ref_dir in "${SRC:-}/tests/ga_tests/build/reference" "$(dirname "$0")/build/reference"; do
  if [[ -f "${ref_dir}/rv1126-sonoff-ihost.dtsi.expected" ]]; then
    DTSI_EXPECTED="${ref_dir}/rv1126-sonoff-ihost.dtsi.expected"
    break
  fi
done

# Find the patched dtsi in the build output
DTSI_ACTUAL="${OUT}/build/linux-6.12.51/arch/arm/boot/dts/rockchip/rv1126-sonoff-ihost.dtsi"
# Fall back to other kernel versions
if [[ ! -f "$DTSI_ACTUAL" ]]; then
  DTSI_ACTUAL="$(ls "${OUT}"/build/linux-*/arch/arm/boot/dts/rockchip/rv1126-sonoff-ihost.dtsi 2>/dev/null | head -1)"
fi

if [[ -z "$DTSI_EXPECTED" ]]; then
  _skip "DT-01: Device tree reference comparison" "reference file not found"
elif [[ -z "$DTSI_ACTUAL" ]] || [[ ! -f "$DTSI_ACTUAL" ]]; then
  _skip "DT-01: Device tree reference comparison" "patched dtsi not found (linux not built yet)"
else
  DT_DIFF="$(diff -u "$DTSI_EXPECTED" "$DTSI_ACTUAL" 2>/dev/null)"
  if [[ -z "$DT_DIFF" ]]; then
    _pass "DT-01: Patched device tree matches known-good reference"
  else
    _fail "DT-01: Patched device tree DIFFERS from reference"
    echo "         Diff (first 20 lines):"
    echo "$DT_DIFF" | head -20 | sed 's/^/         /'
    echo "         Reference: $DTSI_EXPECTED"
    echo "         Actual:    $DTSI_ACTUAL"
    echo "         If intentional, update reference: cp \"\$ACTUAL\" \"\$EXPECTED\""
  fi

  # DT-02: Verify critical properties exist in patched dtsi
  for prop in "vmmc-supply" "vqmmc-supply" "supports-sdio" "dr_mode.*peripheral"; do
    grep -q "$prop" "$DTSI_ACTUAL" 2>/dev/null \
      && _pass "DT-02: dtsi has '$prop'" \
      || _fail "DT-02: dtsi MISSING '$prop' (patch may have been silently dropped)"
  done

  # DT-03: USB host should be enabled (for RNDIS router stick support)
  for node in "u2phy1" "u2phy_host" "usb_host0_ehci" "usb_host0_ohci"; do
    if grep -A1 "^&${node}" "$DTSI_ACTUAL" 2>/dev/null | grep -q 'okay'; then
      _pass "DT-03: &${node} is enabled"
    else
      _fail "DT-03: &${node} is NOT enabled (USB host should be active for RNDIS support)"
    fi
  done
fi

# =========================================================================
# Source file consistency (checks source tree, not build output)
# These catch misconfigurations BEFORE a full build completes
# =========================================================================
echo ""
echo "--- Source file consistency ---"

# Determine source root (container: /build, host: parent of output dir)
if [[ -d "/build/buildroot-external" ]]; then
  SRC="/build"
elif [[ -d "${OUT}/../buildroot-external" ]]; then
  SRC="$(cd "${OUT}/.." && pwd)"
else
  SRC=""
fi

if [[ -n "$SRC" ]]; then
  # SRC-01: hassio.mk VERSION_URL
  HASSIO_MK="${SRC}/buildroot-external/package/hassio/hassio.mk"
  if [[ -f "$HASSIO_MK" ]]; then
    grep -q 'greenautarky/haos-version' "$HASSIO_MK" \
      && _pass "SRC-01: hassio.mk VERSION_URL is greenautarky" \
      || _fail "SRC-01: hassio.mk VERSION_URL is NOT greenautarky"

    # SRC-02: no stale refs in hassio.mk
    if grep -qE 'oliverc7|iHost-Open-Source' "$HASSIO_MK" 2>/dev/null; then
      _fail "SRC-02: hassio.mk has stale upstream refs"
    else
      _pass "SRC-02: hassio.mk has no stale upstream refs"
    fi
  else
    _skip "SRC-01/02" "hassio.mk not found"
  fi

  # SRC-03: dind-import-containers.sh tags greenautarky
  DIND="${SRC}/buildroot-external/package/hassio/dind-import-containers.sh"
  if [[ -f "$DIND" ]]; then
    grep -q 'ghcr.io/greenautarky.*hassio-supervisor' "$DIND" \
      && _pass "SRC-03: dind-import tags supervisor as greenautarky" \
      || _fail "SRC-03: dind-import does NOT tag supervisor as greenautarky"

    # SRC-04: no stale refs in dind-import
    if grep -qE 'oliverc7|iHost-Open-Source' "$DIND" 2>/dev/null; then
      _fail "SRC-04: dind-import has stale upstream refs"
    else
      _pass "SRC-04: dind-import has no stale upstream refs"
    fi
  else
    _skip "SRC-03/04" "dind-import-containers.sh not found"
  fi

  # SRC-05: hassos-supervisor source matches dind-import tag prefix
  HSUP_SRC="${SRC}/buildroot-external/rootfs-overlay/usr/sbin/hassos-supervisor"
  if [[ -f "$HSUP_SRC" ]] && [[ -f "$DIND" ]]; then
    # Extract the image prefix from both files and compare
    HSUP_PREFIX="$(grep 'SUPERVISOR_IMAGE=' "$HSUP_SRC" | head -1 | sed 's/.*"\(.*\)\/.*/\1/')"
    DIND_PREFIX="$(grep 'docker tag.*hassio-supervisor' "$DIND" | head -1 | sed 's/.*"\(.*\)\/.*/\1/')"
    if [[ "$HSUP_PREFIX" == "$DIND_PREFIX" ]] && [[ -n "$HSUP_PREFIX" ]]; then
      _pass "SRC-05: hassos-supervisor and dind-import use same prefix: $HSUP_PREFIX"
    else
      _fail "SRC-05: prefix mismatch: hassos-supervisor='$HSUP_PREFIX' vs dind-import='$DIND_PREFIX'"
    fi
  else
    _skip "SRC-05" "source files not found"
  fi

  # SRC-06: updater.json core version is read dynamically from version.json (not hardcoded)
  if [[ -f "$DIND" ]]; then
    if grep -q 'version\.json' "$DIND" && grep -q '\.core' "$DIND"; then
      _pass "SRC-06: updater.json core version is read dynamically from version.json"
    elif grep 'updater.json' "$DIND" | grep -q '"latest"'; then
      _fail "SRC-06: updater.json uses 'latest' (HA rejects this)"
    else
      _fail "SRC-06: updater.json core version is not read from version.json (may be hardcoded)"
    fi
  fi

  # SRC-07: ga_build.sh exports GA_BUILD_TIMESTAMP and GA_ENV
  GA_BUILD="${SRC}/scripts/ga_build.sh"
  if [[ -f "$GA_BUILD" ]]; then
    grep -q 'export GA_BUILD_TIMESTAMP' "$GA_BUILD" \
      && _pass "SRC-07: ga_build.sh exports GA_BUILD_TIMESTAMP" \
      || _fail "SRC-07: ga_build.sh does NOT export GA_BUILD_TIMESTAMP"
  else
    _skip "SRC-07" "ga_build.sh not found"
  fi

  # SRC-08: post-build.sh stamps GA_BUILD_ID into os-release
  POST_BUILD="${SRC}/buildroot-external/scripts/post-build.sh"
  if [[ -f "$POST_BUILD" ]]; then
    grep -q 'GA_BUILD_ID' "$POST_BUILD" \
      && _pass "SRC-08: post-build.sh stamps GA_BUILD_ID" \
      || _fail "SRC-08: post-build.sh does NOT stamp GA_BUILD_ID"
  else
    _skip "SRC-08" "post-build.sh not found"
  fi

  # SRC-10: Frontend build pipeline has greenautarky-setup entrypoint
  FE_ROOT=""
  for fe_dir in "${SRC}/../homeassistant_frontend" "/home/user/git/homeassistant_frontend"; do
    [[ -d "$fe_dir/src" ]] && FE_ROOT="$fe_dir" && break
  done
  if [[ -n "$FE_ROOT" ]]; then
    # SRC-10a: HTML template exists
    [[ -f "${FE_ROOT}/src/html/greenautarky-setup.html.template" ]] \
      && _pass "SRC-10a: greenautarky-setup.html.template exists" \
      || _fail "SRC-10a: greenautarky-setup.html.template MISSING — frontend build will not produce GA setup page"

    # SRC-10b: Entrypoint TS exists
    [[ -f "${FE_ROOT}/src/entrypoints/greenautarky-setup.ts" ]] \
      && _pass "SRC-10b: greenautarky-setup.ts entrypoint exists" \
      || _fail "SRC-10b: greenautarky-setup.ts entrypoint MISSING"

    # SRC-10c: bundle.cjs references the entrypoint
    grep -q '"greenautarky-setup"' "${FE_ROOT}/build-scripts/bundle.cjs" 2>/dev/null \
      && _pass "SRC-10c: bundle.cjs has greenautarky-setup entry" \
      || _fail "SRC-10c: bundle.cjs MISSING greenautarky-setup entry — JS won't be compiled"

    # SRC-10d: entry-html.js has the page in APP_PAGE_ENTRIES
    grep -q '"greenautarky-setup.html"' "${FE_ROOT}/build-scripts/gulp/entry-html.js" 2>/dev/null \
      && _pass "SRC-10d: entry-html.js has greenautarky-setup.html page" \
      || _fail "SRC-10d: entry-html.js MISSING greenautarky-setup.html — HTML page won't be generated"

    # SRC-10e: Panel Lit component with user creation step
    grep -q 'ga-setup-create-user' "${FE_ROOT}/src/panels/greenautarky-setup/ha-panel-greenautarky-setup.ts" 2>/dev/null \
      && _pass "SRC-10e: Lit panel includes user creation step" \
      || _fail "SRC-10e: Lit panel MISSING user creation step"

    # SRC-10f: build_frontend script has post-build verification
    grep -q 'greenautarky-setup.html' "${FE_ROOT}/script/build_frontend" 2>/dev/null \
      && _pass "SRC-10f: build_frontend verifies greenautarky-setup.html" \
      || _fail "SRC-10f: build_frontend has NO verification for greenautarky-setup.html"
  else
    _skip "SRC-10a..f" "frontend repo not found"
  fi

  # SRC-11: Core CI workflow verifies wheel contents
  CORE_ROOT=""
  for core_dir in "${SRC}/../homeassisant_core" "/home/user/git/homeassisant_core"; do
    [[ -d "$core_dir/.github" ]] && CORE_ROOT="$core_dir" && break
  done
  if [[ -n "$CORE_ROOT" ]]; then
    CORE_WF="${CORE_ROOT}/.github/workflows/build-ga-core.yml"
    if [[ -f "$CORE_WF" ]]; then
      grep -q 'greenautarky-setup.html' "$CORE_WF" 2>/dev/null \
        && _pass "SRC-11: Core CI workflow verifies greenautarky-setup.html in wheel" \
        || _fail "SRC-11: Core CI workflow does NOT verify greenautarky-setup.html in wheel"
    else
      _skip "SRC-11" "build-ga-core.yml not found"
    fi
  else
    _skip "SRC-11" "ha-core repo not found"
  fi

  # SRC-12: authorize.ts app-flow redirect (GA onboarding intercept)
  # Verifies that authorize.ts contains the GA pre-check that redirects the HA
  # Companion app to the GA setup wizard before auth, and that the panel
  # handles the return redirect and Admin-Login escape hatch.
  if [[ -n "$FE_ROOT" ]]; then
    AUTH_TS="${FE_ROOT}/src/entrypoints/authorize.ts"
    PANEL_TS="${FE_ROOT}/src/panels/greenautarky-setup/ha-panel-greenautarky-setup.ts"

    # SRC-12a: authorize.ts fetches the GA onboarding status endpoint
    grep -q 'greenautarky_onboarding/status' "$AUTH_TS" 2>/dev/null \
      && _pass "SRC-12a: authorize.ts fetches GA onboarding status" \
      || _fail "SRC-12a: authorize.ts does NOT fetch GA onboarding status — app-flow redirect will not fire"

    # SRC-12b: authorize.ts has the ga_bypass admin escape hatch
    grep -q 'ga_bypass' "$AUTH_TS" 2>/dev/null \
      && _pass "SRC-12b: authorize.ts has ga_bypass admin bypass" \
      || _fail "SRC-12b: authorize.ts missing ga_bypass — admin cannot skip GA redirect"

    # SRC-12c: authorize.ts stores the auth URL for return-redirect after setup
    grep -q 'ga_auth_redirect' "$AUTH_TS" 2>/dev/null \
      && _pass "SRC-12c: authorize.ts stores ga_auth_redirect in sessionStorage" \
      || _fail "SRC-12c: authorize.ts does NOT store ga_auth_redirect — return redirect after onboarding will fail"

    # SRC-12d: Panel reads ga_auth_redirect on completion (return to auth URL)
    grep -q 'ga_auth_redirect' "$PANEL_TS" 2>/dev/null \
      && _pass "SRC-12d: panel reads ga_auth_redirect for post-completion redirect" \
      || _fail "SRC-12d: panel does NOT read ga_auth_redirect — app will not return to auth after onboarding"

    # SRC-12e: Panel renders Admin-Login link (escape hatch for admins)
    grep -q 'admin-login' "$PANEL_TS" 2>/dev/null \
      && _pass "SRC-12e: panel renders admin-login link" \
      || _fail "SRC-12e: panel missing admin-login link — admins cannot bypass GA setup"
  else
    _skip "SRC-12a..e" "frontend repo not found"
  fi

  # SRC-13: Frontend version is CI-managed (pyproject.toml must use 0.0.0.dev0 placeholder)
  if [[ -n "$FE_ROOT" ]]; then
    # SRC-13a: pyproject.toml must NOT contain a hardcoded YYYYMMDD version
    if grep -qE '^version\s*=\s*"202[0-9]{5}\.' "${FE_ROOT}/pyproject.toml" 2>/dev/null; then
      _fail "SRC-13a: pyproject.toml has a hardcoded date version — must be 0.0.0.dev0 (CI injects the real version)"
    else
      _pass "SRC-13a: pyproject.toml uses placeholder version (CI-managed)"
    fi

    # SRC-13b: Core CI workflow has the version injection step
    CORE_ROOT=""
    for core_dir in "${SRC}/../homeassisant_core" "/home/user/git/homeassisant_core"; do
      [[ -d "$core_dir/.github" ]] && CORE_ROOT="$core_dir" && break
    done
    if [[ -n "$CORE_ROOT" ]]; then
      CORE_WF="${CORE_ROOT}/.github/workflows/build-ga-core.yml"
      grep -q 'Compute and inject frontend version' "$CORE_WF" 2>/dev/null \
        && _pass "SRC-13b: Core CI has version injection step" \
        || _fail "SRC-13b: Core CI is MISSING version injection step — builds will use placeholder version"

      # SRC-13c: Core pin files use placeholder (not a stale hardcoded version)
      if grep -qE 'home-assistant-frontend==202[0-9]{5}\.' \
        "${CORE_ROOT}/homeassistant/components/frontend/manifest.json" \
        "${CORE_ROOT}/requirements_all.txt" 2>/dev/null; then
        _fail "SRC-13c: Core repo has hardcoded frontend version — must be 0.0.0.dev0 (CI injects the real version)"
      else
        _pass "SRC-13c: Core pin files use placeholder version (CI-managed)"
      fi
    else
      _skip "SRC-13b..c" "ha-core repo not found"
    fi
  else
    _skip "SRC-13a..c" "frontend repo not found"
  fi

  # SRC-14: PIN verification integration (frontend + core)
  if [[ -n "$FE_ROOT" ]]; then
    # SRC-14a: Frontend has PIN step component
    [[ -f "${FE_ROOT}/src/panels/greenautarky-setup/ga-setup-pin.ts" ]] \
      && _pass "SRC-14a: ga-setup-pin.ts component exists" \
      || _fail "SRC-14a: ga-setup-pin.ts missing — PIN step not in frontend"

    # SRC-14b: Wizard includes PIN step
    grep -q '"pin"' "${FE_ROOT}/src/panels/greenautarky-setup/ha-panel-greenautarky-setup.ts" 2>/dev/null \
      && _pass "SRC-14b: wizard STEPS includes pin" \
      || _fail "SRC-14b: wizard STEPS missing pin step"

    # SRC-14c: API client has verifyGASetupPin
    grep -q 'verifyGASetupPin' "${FE_ROOT}/src/data/greenautarky_setup.ts" 2>/dev/null \
      && _pass "SRC-14c: verifyGASetupPin API function exists" \
      || _fail "SRC-14c: verifyGASetupPin missing from API client"
  else
    _skip "SRC-14a..c" "frontend repo not found"
  fi

  if [[ -n "$CORE_ROOT" ]]; then
    # SRC-14d: Core has verify_pin endpoint
    grep -q 'verify_pin' "${CORE_ROOT}/homeassistant/components/greenautarky_onboarding/http.py" 2>/dev/null \
      && _pass "SRC-14d: Core has verify_pin endpoint" \
      || _fail "SRC-14d: Core missing verify_pin endpoint"

    # SRC-14e: Core has PIN rate limiting (exponential backoff)
    grep -q 'pin_locked_until' "${CORE_ROOT}/homeassistant/components/greenautarky_onboarding/http.py" 2>/dev/null \
      && _pass "SRC-14e: Core has PIN rate limiting" \
      || _fail "SRC-14e: Core missing PIN rate limiting"
  else
    _skip "SRC-14d..e" "ha-core repo not found"
  fi

  # SRC-15: QR code PIN auto-injection (frontend)
  if [[ -n "$FE_ROOT" ]]; then
    # SRC-15a: PIN component accepts autoPin property
    grep -q 'autoPin' "${FE_ROOT}/src/panels/greenautarky-setup/ga-setup-pin.ts" 2>/dev/null \
      && _pass "SRC-15a: ga-setup-pin has autoPin property (QR support)" \
      || _fail "SRC-15a: ga-setup-pin missing autoPin — QR auto-inject won't work"

    # SRC-15b: Wizard parses ?pin= URL parameter
    grep -q "getParam.*pin\|URLSearchParams.*pin\|\.get.*pin" "${FE_ROOT}/src/panels/greenautarky-setup/ha-panel-greenautarky-setup.ts" 2>/dev/null \
      && _pass "SRC-15b: wizard parses ?pin= from URL" \
      || _fail "SRC-15b: wizard not parsing ?pin= URL parameter"

    # SRC-15c: Wizard cleans URL after parsing (removes pin from address bar)
    grep -q 'replaceState' "${FE_ROOT}/src/panels/greenautarky-setup/ha-panel-greenautarky-setup.ts" 2>/dev/null \
      && _pass "SRC-15c: wizard cleans PIN from URL (history.replaceState)" \
      || _fail "SRC-15c: wizard not cleaning PIN from URL — security risk"

    # SRC-15d: E2E tests for QR auto-inject exist
    grep -q 'QR auto-inject' "${SCRIPT_DIR}/../../e2e/tests/pin-verification.spec.ts" 2>/dev/null \
      && _pass "SRC-15d: QR auto-inject E2E tests exist" \
      || _fail "SRC-15d: QR auto-inject E2E tests missing"
  else
    _skip "SRC-15a..d" "frontend repo not found"
  fi

  # SRC-09: Global stale reference scan across all functional source
  STALE_COUNT=0
  for dir in "${SRC}/buildroot-external/package" "${SRC}/buildroot-external/rootfs-overlay" "${SRC}/scripts"; do
    [[ -d "$dir" ]] || continue
    hits=$(grep -rlE 'oliverc7|iHost-Open-Source-Project' "$dir" 2>/dev/null | wc -l)
    STALE_COUNT=$((STALE_COUNT + hits))
  done
  if [[ "$STALE_COUNT" -eq 0 ]]; then
    _pass "SRC-09: No stale refs (oliverc7/iHost-Open-Source) in functional source"
  else
    _fail "SRC-09: Found $STALE_COUNT file(s) with stale upstream refs in functional source"
  fi
  # =========================================================================
  # Cross-repo version alignment (fetches stable.json, compares with local)
  # =========================================================================
  echo ""
  echo "--- Cross-repo version alignment ---"

  STABLE_JSON="$(curl -sf 'https://raw.githubusercontent.com/greenautarky/haos-version/main/stable.json' 2>/dev/null || true)"

  if [[ -n "$STABLE_JSON" ]]; then
    STABLE_CORE="$(echo "$STABLE_JSON" | jq -r '.core // "unknown"')"
    STABLE_SUP="$(echo "$STABLE_JSON" | jq -r '.supervisor // "unknown"')"
    STABLE_CORE_IMG="$(echo "$STABLE_JSON" | jq -r '.images.core // "unknown"')"
    STABLE_SUP_IMG="$(echo "$STABLE_JSON" | jq -r '.images.supervisor // "unknown"')"
    STABLE_CORE_TINKER="$(echo "$STABLE_JSON" | jq -r '.homeassistant.tinker // "unknown"')"

    # XVER-01: stable.json core version uses calver (not -ga.N)
    if [[ "$STABLE_CORE" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      _pass "XVER-01: stable.json core is calver: $STABLE_CORE"
    else
      _fail "XVER-01: stable.json core is NOT calver: $STABLE_CORE"
    fi

    # XVER-02: stable.json supervisor version uses calver (not -ga.N)
    if [[ "$STABLE_SUP" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      _pass "XVER-02: stable.json supervisor is calver: $STABLE_SUP"
    else
      _fail "XVER-02: stable.json supervisor is NOT calver: $STABLE_SUP"
    fi

    # XVER-03: stable.json core image is greenautarky
    [[ "$STABLE_CORE_IMG" == *greenautarky* ]] \
      && _pass "XVER-03: stable.json core image is greenautarky" \
      || _fail "XVER-03: stable.json core image is NOT greenautarky: $STABLE_CORE_IMG"

    # XVER-04: stable.json supervisor image is greenautarky
    [[ "$STABLE_SUP_IMG" == *greenautarky* ]] \
      && _pass "XVER-04: stable.json supervisor image is greenautarky" \
      || _fail "XVER-04: stable.json supervisor image is NOT greenautarky: $STABLE_SUP_IMG"

    # XVER-05: stable.json core == tinker-specific core (no machine mismatch)
    [[ "$STABLE_CORE" == "$STABLE_CORE_TINKER" ]] \
      && _pass "XVER-05: stable.json core matches tinker: $STABLE_CORE" \
      || _fail "XVER-05: stable.json core ($STABLE_CORE) != tinker ($STABLE_CORE_TINKER)"

    # XVER-06: updater.json will use version.json core at build time; verify version.json core matches stable.json
    if [[ -f "$VER_JSON" ]]; then
      VJ_CORE="$(jq -r '.core // "unknown"' "$VER_JSON" 2>/dev/null)"
      if [[ "$VJ_CORE" == "$STABLE_CORE" ]]; then
        _pass "XVER-06: version.json core ($VJ_CORE) matches stable.json ($STABLE_CORE) — updater.json will be correct"
      else
        _fail "XVER-06: version.json core ($VJ_CORE) != stable.json core ($STABLE_CORE)"
      fi
    else
      _skip "XVER-06" "version.json not found"
    fi

    # XVER-07: build version.json core matches stable.json core
    if [[ -f "$VER_JSON" ]]; then
      BUILD_CORE="$(jq -r '.core // "unknown"' "$VER_JSON" 2>/dev/null)"
      if [[ "$BUILD_CORE" == "$STABLE_CORE" ]]; then
        _pass "XVER-07: build version.json core ($BUILD_CORE) matches stable.json ($STABLE_CORE)"
      else
        _fail "XVER-07: build version.json core ($BUILD_CORE) != stable.json ($STABLE_CORE)"
      fi
    else
      _skip "XVER-07" "build version.json not present (full build needed)"
    fi

    # XVER-08: No -ga.N pattern anywhere in stable.json (enforce calver)
    if echo "$STABLE_JSON" | grep -qE '"[0-9]{4}\.[0-9]+\.[0-9]+-ga\.[0-9]+"'; then
      _fail "XVER-08: stable.json still contains -ga.N version (must use .N calver)"
    else
      _pass "XVER-08: stable.json has no -ga.N versions (clean calver)"
    fi
  else
    _skip "XVER-01..08" "could not fetch stable.json (offline or network error)"
  fi

else
  _skip "SRC-01..09" "source tree not found (expected /build or parent of output)"
  _skip "XVER-01..08" "source tree not found"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
total=$((pass + fail + skip))
echo "=== Build tests: ${pass} passed, ${fail} failed, ${skip} skipped (${total} total) ==="
echo "{\"suite\":\"build\",\"pass\":${pass},\"fail\":${fail},\"skip\":${skip}}"
echo ""

exit $fail
