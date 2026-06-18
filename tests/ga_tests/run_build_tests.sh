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

# Phase 7 scaffold — network-details config ships to the rootfs (NOT
# wired into the main fluent-bit.conf yet — that's the activation step
# when concrete LTE dongle backends ship in Phase 3.x).
NETDETAILS_CONF="${TARGET}/etc/fluent-bit/network-details.conf"

# CFG-17: file present
[[ -f "$NETDETAILS_CONF" ]] \
  && _pass "CFG-17: network-details.conf shipped to rootfs (Phase 7 scaffold)" \
  || _fail "CFG-17: network-details.conf missing from rootfs"

# CFG-18: scaffold polls ga_manager's /network/details endpoint
grep -q "network/details" "$NETDETAILS_CONF" 2>/dev/null \
  && _pass "CFG-18: network-details.conf polls /network/details" \
  || _fail "CFG-18: network-details.conf has wrong endpoint"

# CFG-19: scaffold filters out available=false (= no Loki noise pre-Phase-3.x)
grep -q "available true" "$NETDETAILS_CONF" 2>/dev/null \
  && _pass "CFG-19: network-details.conf filters available=true only" \
  || _fail "CFG-19: network-details.conf missing 'available true' filter"

# CFG-20: NOT YET included from main config (= scaffold-only until Phase 7 ships)
if grep -q '@INCLUDE network-details.conf' "${TARGET}/etc/fluent-bit/fluent-bit.conf" 2>/dev/null; then
    _fail "CFG-20: fluent-bit.conf already includes network-details.conf — Phase 7 activation must be explicit"
else
    _pass "CFG-20: fluent-bit.conf does not yet include network-details.conf (= scaffold-only as expected)"
fi

# CFG-13/14: GA DNS entries in ga-services.conf (single source of truth for endpoint IPs)
grep -q 'influx.greenautarky.com' "${TARGET}/etc/ga-services.conf" 2>/dev/null \
  && _pass "CFG-13: ga-services.conf has influx host" \
  || _fail "CFG-13: ga-services.conf missing influx host"

grep -q 'loki.greenautarky.com' "${TARGET}/etc/ga-services.conf" 2>/dev/null \
  && _pass "CFG-14: ga-services.conf has loki host" \
  || _fail "CFG-14: ga-services.conf missing loki host"

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

# CFG-28/29: removed — ga-dns-inject replaced by Supervisor fork DNS handling

# CFG-30: OpenStick auto-connect
[[ -x "${TARGET}/usr/sbin/ga-openstick-autoconnect" ]] \
  && _pass "CFG-30a: ga-openstick-autoconnect script exists and executable" \
  || _fail "CFG-30a: ga-openstick-autoconnect NOT found"

[[ -f "${TARGET}/etc/systemd/system/ga-openstick-autoconnect.service" ]] \
  && _pass "CFG-30b: ga-openstick-autoconnect.service exists" \
  || _fail "CFG-30b: ga-openstick-autoconnect.service NOT found"

[[ -f "${TARGET}/etc/systemd/system/ga-openstick-autoconnect.timer" ]] \
  && _pass "CFG-30c: ga-openstick-autoconnect.timer exists" \
  || _fail "CFG-30c: ga-openstick-autoconnect.timer NOT found"

[[ -L "${TARGET}/etc/systemd/system/timers.target.wants/ga-openstick-autoconnect.timer" ]] \
  && _pass "CFG-30d: ga-openstick-autoconnect.timer enabled" \
  || _fail "CFG-30d: ga-openstick-autoconnect.timer NOT enabled"

echo ""
echo "--- Telemetry consent gate ---"

# TEL-BLD-01: ga-telemetry-gate script exists
[[ -x "${TARGET}/usr/sbin/ga-telemetry-gate" ]] \
  && _pass "TEL-BLD-01: ga-telemetry-gate script exists and executable" \
  || _fail "TEL-BLD-01: ga-telemetry-gate NOT found on rootfs"

# TEL-BLD-02: ga-telemetry-gate supports write mode
grep -q 'write_markers' "${TARGET}/usr/sbin/ga-telemetry-gate" 2>/dev/null \
  && _pass "TEL-BLD-02: ga-telemetry-gate has write_markers function" \
  || _fail "TEL-BLD-02: ga-telemetry-gate missing write_markers"

# TEL-BLD-03: telegraf.service has ConditionPathExists for consent
grep -q 'ConditionPathExists=.*ga-consent-metrics' "${TARGET}/etc/systemd/system/telegraf.service" 2>/dev/null \
  && _pass "TEL-BLD-03: telegraf.service gated by consent marker" \
  || _fail "TEL-BLD-03: telegraf.service NOT gated — will run without consent!"

# TEL-BLD-04: fluent-bit.service has ConditionPathExists for consent
FB_SVC_TEL="${TARGET}/usr/lib/systemd/system/fluent-bit.service"
grep -q 'ConditionPathExists=.*ga-consent-error_logs' "$FB_SVC_TEL" 2>/dev/null \
  && _pass "TEL-BLD-04: fluent-bit.service gated by consent marker" \
  || _fail "TEL-BLD-04: fluent-bit.service NOT gated — will run without consent!"

# TEL-BLD-05: ga-telemetry-consent.service exists
[[ -f "${TARGET}/etc/systemd/system/ga-telemetry-consent.service" ]] \
  && _pass "TEL-BLD-05: ga-telemetry-consent.service exists" \
  || _fail "TEL-BLD-05: ga-telemetry-consent.service NOT found"

# TEL-BLD-06: ga-telemetry-consent.service ordered after supervisor
grep -q 'After=.*hassio-supervisor' "${TARGET}/etc/systemd/system/ga-telemetry-consent.service" 2>/dev/null \
  && _pass "TEL-BLD-06: consent service ordered after supervisor" \
  || _fail "TEL-BLD-06: consent service NOT ordered after supervisor"

# TEL-BLD-07: ga-telemetry-gate checks GA_TELEMETRY_FORCE override
grep -q 'GA_TELEMETRY_FORCE' "${TARGET}/usr/sbin/ga-telemetry-gate" 2>/dev/null \
  && _pass "TEL-BLD-07: ga-telemetry-gate supports FORCE override" \
  || _fail "TEL-BLD-07: ga-telemetry-gate missing FORCE override — dev devices won't work"

# TEL-BLD-08: ga-telemetry-consent.service enabled
[[ -L "${TARGET}/etc/systemd/system/multi-user.target.wants/ga-telemetry-consent.service" ]] \
  && _pass "TEL-BLD-08: ga-telemetry-consent.service enabled" \
  || _fail "TEL-BLD-08: ga-telemetry-consent.service NOT enabled"

echo ""
echo "--- GA services config (centralized endpoint IPs) ---"

# SVC-01: ga-services.conf exists on rootfs
[[ -f "${TARGET}/etc/ga-services.conf" ]] \
  && _pass "SVC-01: ga-services.conf exists on rootfs" \
  || _fail "SVC-01: ga-services.conf NOT found"

# SVC-02: ga-services.conf has GA_SERVICES_IP
grep -q 'GA_SERVICES_IP=' "${TARGET}/etc/ga-services.conf" 2>/dev/null \
  && _pass "SVC-02: ga-services.conf has GA_SERVICES_IP" \
  || _fail "SVC-02: ga-services.conf missing GA_SERVICES_IP"

# SVC-03: ga-services.conf has all three service hostnames
grep -q 'GA_INFLUX_HOST=' "${TARGET}/etc/ga-services.conf" 2>/dev/null \
  && grep -q 'GA_LOKI_HOST=' "${TARGET}/etc/ga-services.conf" 2>/dev/null \
  && grep -q 'GA_OTA_HOST=' "${TARGET}/etc/ga-services.conf" 2>/dev/null \
  && _pass "SVC-03: ga-services.conf has all service hostnames" \
  || _fail "SVC-03: ga-services.conf missing service hostnames"

# SVC-04: ga-update-hosts script exists and executable
[[ -x "${TARGET}/usr/sbin/ga-update-hosts" ]] \
  && _pass "SVC-04: ga-update-hosts script exists and executable" \
  || _fail "SVC-04: ga-update-hosts NOT found"

# SVC-05: ga-update-hosts.service exists
[[ -f "${TARGET}/etc/systemd/system/ga-update-hosts.service" ]] \
  && _pass "SVC-05: ga-update-hosts.service exists" \
  || _fail "SVC-05: ga-update-hosts.service NOT found"

# SVC-06: ga-update-hosts.service enabled
[[ -L "${TARGET}/etc/systemd/system/multi-user.target.wants/ga-update-hosts.service" ]] \
  && _pass "SVC-06: ga-update-hosts.service enabled" \
  || _fail "SVC-06: ga-update-hosts.service NOT enabled"

# SVC-07: ga-update-hosts runs before supervisor
grep -q 'Before=.*hassio-supervisor' "${TARGET}/etc/systemd/system/ga-update-hosts.service" 2>/dev/null \
  && _pass "SVC-07: ga-update-hosts ordered before supervisor" \
  || _fail "SVC-07: ga-update-hosts NOT ordered before supervisor"

# SVC-08: ga-defaults/hosts does NOT contain hardcoded IP
if grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*greenautarky' "${TARGET}/usr/share/ga-defaults/hosts" 2>/dev/null; then
  _fail "SVC-08: ga-defaults/hosts still has hardcoded GA IP — should use ga-services.conf"
else
  _pass "SVC-08: ga-defaults/hosts has no hardcoded GA IPs (managed by ga-update-hosts)"
fi

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

# OVL-02: GA DNS config in safe location (ga-services.conf, not overlaid /etc/hosts)
[[ -f "${TARGET}/etc/ga-services.conf" ]] && grep -q 'GA_SERVICES_IP' "${TARGET}/etc/ga-services.conf" 2>/dev/null \
  && _pass "OVL-02: GA DNS config in /etc/ga-services.conf (safe from overlay)" \
  || _fail "OVL-02: ga-services.conf missing or has no GA_SERVICES_IP"

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

# OVL-06: WiFi power save config NOT in overlaid /etc/ path
if [[ -f "${TARGET}/etc/NetworkManager/conf.d/99-disable-wifi-powersave.conf" ]]; then
  _fail "OVL-06: WiFi powersave config in /etc/ — will be hidden by overlay! Use /usr/share/ga-defaults/"
else
  _pass "OVL-06: WiFi powersave config correctly NOT in overlaid path"
fi

# OVL-06b: WiFi power save config in ga-defaults
[[ -f "${TARGET}/usr/share/ga-defaults/NetworkManager/conf.d/99-disable-wifi-powersave.conf" ]] \
  && _pass "OVL-06b: WiFi powersave config in /usr/share/ga-defaults/" \
  || _fail "OVL-06b: WiFi powersave config missing from /usr/share/ga-defaults/"

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

# ENV-03: Prod build safety checks
if [[ "$GA_ENV_VAL" == "prod" ]]; then
  # VERSION_SUFFIX must be set (not empty) for prod builds
  OS_RELEASE="${TARGET}/etc/os-release"
  [[ -f "$OS_RELEASE" ]] || OS_RELEASE="${TARGET}/usr/lib/os-release"
  PROD_VER="$(grep 'VERSION_ID=' "$OS_RELEASE" 2>/dev/null | cut -d= -f2)"
  # Must have at least 3 segments (e.g. 16.3.1.1, not just 16.3)
  if echo "$PROD_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
    _pass "ENV-03a: Prod version has release suffix ($PROD_VER)"
  else
    _fail "ENV-03a: Prod build has NO release suffix ($PROD_VER) — bump VERSION_SUFFIX before releasing"
  fi
  # PRETTY_NAME must contain GreenAutarky BOS
  if grep -q 'GreenAutarky BOS' "$OS_RELEASE" 2>/dev/null; then
    _pass "ENV-03b: Prod build has GreenAutarky BOS branding"
  else
    _fail "ENV-03b: Prod build missing GreenAutarky BOS branding"
  fi
  # Image filename must be bos_ (not haos_ or gaos_)
  if ls "${OUT}/images/"bos_*.img.xz >/dev/null 2>&1; then
    _pass "ENV-03c: Prod image has bos_ prefix"
  else
    _fail "ENV-03c: Prod image missing bos_ prefix"
  fi
fi

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

# OpenSSL CLI (needed for HMAC-SHA256 PSK derivation on device)
[[ -x "${TARGET}/usr/bin/openssl" ]] \
  && _pass "BIN: openssl binary exists" \
  || _fail "BIN: openssl binary missing (enable BR2_PACKAGE_LIBOPENSSL_BIN=y)"

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
  # V1.2-clean: version.json mixes registries by design — Supervisor is a GA
  # image (greenautarky), Core is stock upstream (ghcr.io/home-assistant/*).
  # A blanket "references greenautarky" grep is meaningless now; assert the
  # two image refs against their correct registries instead (see REG-01/02).
  SUP_IMG="$(jq -r '.images.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
  CORE_IMG="$(jq -r '.images.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  if [[ "$SUP_IMG" == *greenautarky* ]] && [[ "$CORE_IMG" == ghcr.io/home-assistant/* ]]; then
    _pass "BLD: version.json registries correct (supervisor=greenautarky, core=stock)"
  else
    _fail "BLD: version.json registries wrong (supervisor='$SUP_IMG' core='$CORE_IMG')"
  fi

  CORE_TAG="$(jq -r '.core // "unknown"' "$VER_JSON" 2>/dev/null)"
  [[ "$CORE_TAG" =~ ^2025\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    && _pass "BLD: Core image tag is '$CORE_TAG'" \
    || _fail "BLD: Core tag is '$CORE_TAG' (expected HA calver like 2025.11.3 or 2025.11.3.1)"

  # REG: Verify image refs use the correct registry — V1.2-clean retires the
  # Core fork: Supervisor stays a GA image, Core goes stock upstream.
  # Mirrors hassio.mk HASSIO_CONFIGURE_CMDS validation.
  [[ "$SUP_IMG" == *greenautarky* ]] \
    && _pass "REG-01: Supervisor image is greenautarky: $SUP_IMG" \
    || _fail "REG-01: Supervisor image is NOT greenautarky: $SUP_IMG"
  # REG-02 (V1.2-clean): Core fork retired — Core image must be stock upstream
  [[ "$CORE_IMG" == ghcr.io/home-assistant/* ]] \
    && _pass "REG-02: Core image is stock upstream: $CORE_IMG" \
    || _fail "REG-02: Core image is NOT stock ghcr.io/home-assistant/*: $CORE_IMG"

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

  # VER-05 (V1.2-clean): core image is STOCK upstream (Core fork retired —
  # see V1.2-CLEAN-REBUILD T2). Both .image.core and .images.core must point
  # at ghcr.io/home-assistant/*. A `.image.core` key may be absent in a
  # stock stable.json — only assert on refs that are present.
  VER_IMG_CORE="$(jq -r '.image.core // empty' "$VER_JSON" 2>/dev/null)"
  VER_IMGS_CORE="$(jq -r '.images.core // empty' "$VER_JSON" 2>/dev/null)"
  VER05_OK=true
  if [[ -n "$VER_IMGS_CORE" ]]; then
    [[ "$VER_IMGS_CORE" == ghcr.io/home-assistant/* ]] \
      || { _fail "VER-05: images.core is NOT stock ghcr.io/home-assistant/*: $VER_IMGS_CORE"; VER05_OK=false; }
  else
    _fail "VER-05: images.core missing from version.json"; VER05_OK=false
  fi
  if [[ -n "$VER_IMG_CORE" ]] && [[ "$VER_IMG_CORE" != ghcr.io/home-assistant/* ]]; then
    _fail "VER-05: image.core is NOT stock ghcr.io/home-assistant/*: $VER_IMG_CORE"; VER05_OK=false
  fi
  $VER05_OK && _pass "VER-05: core image refs are stock upstream (ghcr.io/home-assistant/*)"

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

  # VER-08 — REMOVED (V1.2-clean T3): the greenautarky/frontend fork is
  # retired, so there is no GA frontend SHA to track against a fork HEAD.
  # Stock Core ships the stock home-assistant-frontend inside its own image;
  # that the Core image contains a built frontend is asserted by BLD-FE-01.

  # VER-09: Supervisor image digest matches GHCR (not stale cache)
  if [[ -d "$IMAGES_DIR" ]] && command -v skopeo >/dev/null 2>&1; then
    SUP_TAR="$(ls "$IMAGES_DIR"/*hassio-supervisor*.tar 2>/dev/null | head -n 1 || true)"
    if [[ -n "$SUP_TAR" ]]; then
      SUP_BUILD_DIGEST="$(basename "$SUP_TAR" .tar | grep -oP 'sha256_\K[a-f0-9]+' || true)"
      SUP_REF="$(jq -r '.images.supervisor // .image.supervisor' "$VER_JSON" 2>/dev/null | sed "s/{arch}/${ARCH:-armv7}/")"
      SUP_TAG="$(jq -r '.supervisor' "$VER_JSON" 2>/dev/null)"
      if [[ -n "$SUP_REF" ]] && [[ -n "$SUP_TAG" ]] && [[ "$SUP_TAG" != "null" ]]; then
        SUP_GHCR_DIGEST="$(skopeo inspect --override-arch arm --override-variant v7 "docker://${SUP_REF}:${SUP_TAG}" 2>/dev/null | jq -r '.Digest' | sed 's/sha256://' || true)"
        if [[ -n "$SUP_BUILD_DIGEST" ]] && [[ -n "$SUP_GHCR_DIGEST" ]]; then
          if [[ "$SUP_BUILD_DIGEST" == "$SUP_GHCR_DIGEST" ]]; then
            _pass "VER-09: Supervisor image digest matches GHCR (fresh)"
          else
            _fail "VER-09: Supervisor STALE — build ${SUP_BUILD_DIGEST:0:12} != GHCR ${SUP_GHCR_DIGEST:0:12}"
          fi
        else
          _skip "VER-09" "could not extract supervisor digests"
        fi
      else
        _skip "VER-09" "could not resolve supervisor image ref"
      fi
    else
      _skip "VER-09" "no supervisor tar found"
    fi
  else
    _skip "VER-09" "skopeo not available or no images dir"
  fi

  # VER-10: All addon image digests match GHCR (not stale cache)
  ADDON_JSON="${BR2EXT_NETBIRD:-/build/buildroot-external}/package/hassio/addon-images.json"
  if [[ -d "$IMAGES_DIR" ]] && [[ -f "$ADDON_JSON" ]] && command -v skopeo >/dev/null 2>&1; then
    VER10_PASS=0; VER10_FAIL=0; VER10_SKIP=0
    for addon_name in $(jq -r '.addons | keys[]' "$ADDON_JSON" 2>/dev/null); do
      addon_image="$(jq -r --arg n "$addon_name" '.addons[$n].image' "$ADDON_JSON" | sed "s/{arch}/${ARCH:-armv7}/")"
      addon_version="$(jq -r --arg n "$addon_name" '.addons[$n].version' "$ADDON_JSON")"
      addon_tar="$(ls "$IMAGES_DIR"/*"$(echo "$addon_name" | tr '/' '_')"*.tar 2>/dev/null | head -n 1 || true)"
      if [[ -z "$addon_tar" ]]; then
        addon_tar="$(ls "$IMAGES_DIR"/*"${addon_version}"*.tar 2>/dev/null | grep -i "$addon_name" | head -n 1 || true)"
      fi
      if [[ -n "$addon_tar" ]]; then
        a_build="$(basename "$addon_tar" .tar | grep -oP 'sha256_\K[a-f0-9]+' || true)"
        a_ghcr="$(skopeo inspect --override-arch arm --override-variant v7 "docker://${addon_image}:${addon_version}" 2>/dev/null | jq -r '.Digest' | sed 's/sha256://' || true)"
        if [[ -n "$a_build" ]] && [[ -n "$a_ghcr" ]]; then
          if [[ "$a_build" == "$a_ghcr" ]]; then
            VER10_PASS=$((VER10_PASS + 1))
          else
            _fail "VER-10: Addon $addon_name STALE — ${a_build:0:12} != GHCR ${a_ghcr:0:12}"
            VER10_FAIL=$((VER10_FAIL + 1))
          fi
        else
          VER10_SKIP=$((VER10_SKIP + 1))
        fi
      else
        VER10_SKIP=$((VER10_SKIP + 1))
      fi
    done
    if [[ "$VER10_FAIL" -eq 0 ]] && [[ "$VER10_PASS" -gt 0 ]]; then
      _pass "VER-10: All ${VER10_PASS} addon digests match GHCR (${VER10_SKIP} skipped)"
    elif [[ "$VER10_FAIL" -eq 0 ]] && [[ "$VER10_PASS" -eq 0 ]]; then
      _skip "VER-10" "no addon digests could be verified"
    fi
  else
    _skip "VER-10" "addon-images.json, skopeo, or images dir not available"
  fi

  # VER-11: Core image io.hass.version label matches version.json tag.
  # V1.2-clean: this stays meaningful for STOCK Core — a wrong/`latest`
  # label still loops the Supervisor. The old ga-frontend-version-file
  # gate is dropped (the GA frontend fork is retired — T3); the check now
  # depends only on the built Core image tar.
  if [[ -d "$IMAGES_DIR" ]]; then
    CORE_TAR_V11="$(ls "$IMAGES_DIR"/*homeassistant*.tar 2>/dev/null | head -n 1 || true)"
    if [[ -n "$CORE_TAR_V11" ]]; then
      CONFIG_PATH_V11=$(tar -xOf "$CORE_TAR_V11" manifest.json 2>/dev/null | jq -r '.[0].Config // empty' || true)
      if [[ -n "$CONFIG_PATH_V11" ]]; then
        LABEL_VERSION=$(tar -xOf "$CORE_TAR_V11" "$CONFIG_PATH_V11" 2>/dev/null | jq -r '.config.Labels."io.hass.version" // "unknown"' || true)
        EXPECTED_VERSION="$(jq -r '.homeassistant."'${MACHINE:-tinker}'" // .core' "$VER_JSON" 2>/dev/null)"
        if [[ "$LABEL_VERSION" == "$EXPECTED_VERSION" ]]; then
          _pass "VER-11: Core io.hass.version label ($LABEL_VERSION) matches version.json"
        elif [[ "$LABEL_VERSION" == "latest" ]]; then
          _fail "VER-11: Core io.hass.version is 'latest' — MUST be a pinned version"
        else
          _fail "VER-11: Core io.hass.version ($LABEL_VERSION) != version.json ($EXPECTED_VERSION)"
        fi
      else
        _skip "VER-11" "could not parse core image manifest"
      fi
    else
      _skip "VER-11" "no core tar found"
    fi
  else
    _skip "VER-11" "core images dir not available (full build needed)"
  fi

  # VER-12 — REMOVED (V1.2-clean T3): "frontend build date < 7 days old"
  # tracked the freshness of the greenautarky/frontend fork's CI build via
  # the ga-frontend-version file. The fork is retired and that file is gone;
  # stock home-assistant-frontend ships pinned inside stock Core, and its
  # version is covered by VER-11's io.hass.version label check.

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

# BLD-FE: V1.2-clean — the greenautarky/frontend fork is RETIRED (T3).
# The GA onboarding wizard no longer rides inside the Core image; it is a
# `greenautarky_onboarding` custom_component. The "vendor it into the
# ga_manager addon image" plan was DROPPED (T4, commit 0d2c65ff3): the
# ga_manager Dockerfile's clone of the private ha-greenautarky-onboarding
# repo had no build credentials and was removed. The component now ships
# inside the OS rootfs-overlay and is placed at runtime by ga-bootstrap.
# So the two checks here are:
#   BLD-FE-01 — stock Core image carries a built STOCK frontend (catches a
#               broken/empty Core image — the only frontend assertion the
#               OS repo can still make about Core).
#   BLD-FE-02 — the greenautarky_onboarding custom_component is present in
#               the OS rootfs-overlay (source-tree check, not an image tar).
echo ""
echo "--- Frontend (V1.2-clean: stock Core + onboarding in OS overlay) ---"

# Helper: collect all layer tars from a docker/OCI archive.
#   1. <hash>/layer.tar       (OCI legacy directory layout)
#   2. blobs/sha256/<hash>    (OCI content-addressable)
#   3. <hash>.tar             (Docker save flat format)
_layer_list() { tar -tf "$1" 2>/dev/null | grep -E 'layer\.tar$|^blobs/|^[a-f0-9]{64}\.tar$' || true; }
# Helper: true if any layer in archive $1 contains a path matching regex $2.
_archive_contains() {
  local arch_tar="$1" rx="$2" layer
  for layer in $(_layer_list "$arch_tar"); do
    if tar -xf "$arch_tar" --to-stdout "$layer" 2>/dev/null | tar -tf - 2>/dev/null | grep -qE "$rx"; then
      return 0
    fi
  done
  return 1
}

# BLD-FE-01: stock Core image contains a built stock frontend.
CORE_TAR="$(ls "${OUT}/build/hassio-1.0.0/images/"*homeassistant* 2>/dev/null | head -1)"
if [[ -n "$CORE_TAR" ]]; then
  # The stock home-assistant-frontend wheel installs into the hass_frontend
  # package; its built SPA shell is index.html under hass_frontend/.
  if _archive_contains "$CORE_TAR" 'hass_frontend/.*index\.html$|hass_frontend/frontend_'; then
    _pass "BLD-FE-01: Core image contains a built stock frontend (hass_frontend)"
  else
    _fail "BLD-FE-01: Core image does NOT contain a built stock frontend (hass_frontend missing)"
  fi
else
  _skip "BLD-FE-01: stock frontend in Core image" "only present after full build"
fi

# BLD-FE-02: greenautarky_onboarding custom_component ships inside the OS
# rootfs-overlay (T4, commit 0d2c65ff3). The OS bakes it into the read-only
# rootfs at /usr/share/ga/custom_components/greenautarky_onboarding/;
# ga-bootstrap stages it to /share at runtime and ga_manager's converge
# worker copies it into /config/custom_components. This is a source-tree
# check (the overlay is part of the OS repo), so it does NOT need a full
# build — but it does need the source tree, which is resolved here because
# the SRC variable is only defined further down in the script.
BLD_FE_SRC=""
if [[ -d "/build/buildroot-external" ]]; then
  BLD_FE_SRC="/build"
elif [[ -d "${OUT}/../buildroot-external" ]]; then
  BLD_FE_SRC="$(cd "${OUT}/.." && pwd)"
elif [[ -d "$(dirname "$0")/../../buildroot-external" ]]; then
  BLD_FE_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
fi
if [[ -n "$BLD_FE_SRC" ]]; then
  GA_ONBOARD_DIR="${BLD_FE_SRC}/buildroot-external/rootfs-overlay/usr/share/ga/custom_components/greenautarky_onboarding"
  if [[ -f "${GA_ONBOARD_DIR}/__init__.py" ]] && [[ -f "${GA_ONBOARD_DIR}/manifest.json" ]]; then
    # Also sanity-check the manifest declares the expected domain so a
    # stray empty/wrong directory cannot pass this test.
    if jq -e '.domain == "greenautarky_onboarding"' "${GA_ONBOARD_DIR}/manifest.json" >/dev/null 2>&1; then
      _pass "BLD-FE-02: greenautarky_onboarding custom_component present in OS rootfs-overlay"
    else
      _fail "BLD-FE-02: greenautarky_onboarding manifest.json present but domain is wrong/missing"
    fi
  else
    _fail "BLD-FE-02: greenautarky_onboarding custom_component MISSING from OS rootfs-overlay (expected __init__.py + manifest.json under ${GA_ONBOARD_DIR})"
  fi
else
  _skip "BLD-FE-02: onboarding component in OS overlay" "source tree (buildroot-external) not found"
fi

# BLD-FB-01..04: ga_frontend_bundle (de-HACS Lovelace cards) also ships inside
# the OS rootfs-overlay (see ga-frontend-bundle + VENDORED.md). Stateless
# integration: converge places it and activates it via the configuration.yaml
# enable-list — a config_flow here would deadlock (it can't self-bootstrap), so
# the manifest MUST NOT set config_flow. The vendored card .js files are baked
# in; assert cards.json and the files agree so an incomplete vendor.py run can't
# silently ship an empty/partial bundle. Reuses $BLD_FE_SRC resolved above.
if [[ -n "$BLD_FE_SRC" ]]; then
  GA_FB_DIR="${BLD_FE_SRC}/buildroot-external/rootfs-overlay/usr/share/ga/custom_components/ga_frontend_bundle"
  GA_FB_MANIFEST="${GA_FB_DIR}/manifest.json"
  if [[ -f "${GA_FB_DIR}/__init__.py" ]] && [[ -f "$GA_FB_MANIFEST" ]]; then
    if jq -e '.domain == "ga_frontend_bundle"' "$GA_FB_MANIFEST" >/dev/null 2>&1; then
      _pass "BLD-FB-01: ga_frontend_bundle custom_component present in OS rootfs-overlay"
    else
      _fail "BLD-FB-01: ga_frontend_bundle manifest.json present but domain wrong/missing"
    fi

    # BLD-FB-02: must be a stateless yaml integration (no config_flow).
    if jq -e '.config_flow == true' "$GA_FB_MANIFEST" >/dev/null 2>&1; then
      _fail "BLD-FB-02: ga_frontend_bundle manifest sets config_flow:true — must be a stateless yaml integration (would deadlock activation)"
    else
      _pass "BLD-FB-02: ga_frontend_bundle is a stateless yaml integration (no config_flow)"
    fi

    # BLD-FB-03/04: cards.json and the vendored files must agree.
    GA_FB_CARDS="${GA_FB_DIR}/community/cards.json"
    if [[ -f "$GA_FB_CARDS" ]]; then
      fb_n="$(jq '.cards | length' "$GA_FB_CARDS" 2>/dev/null || echo 0)"
      fb_missing=0
      while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        [[ -f "${GA_FB_DIR}/community/${rel}" ]] || { fb_missing=$((fb_missing+1)); echo "         missing: community/${rel}"; }
      done < <(jq -r '.cards[] | .id + "/" + .file' "$GA_FB_CARDS" 2>/dev/null)
      if [[ "$fb_n" -gt 0 ]] && [[ "$fb_missing" -eq 0 ]]; then
        _pass "BLD-FB-03: all ${fb_n} ga_frontend_bundle card files present on disk"
      else
        _fail "BLD-FB-03: ga_frontend_bundle has ${fb_missing} missing card file(s) (cards.json lists ${fb_n}) — incomplete vendor?"
      fi

      fb_orphans=0
      for d in "${GA_FB_DIR}/community/"*/; do
        [[ -d "$d" ]] || continue
        id="$(basename "$d")"
        jq -e --arg id "$id" 'any(.cards[]; .id == $id)' "$GA_FB_CARDS" >/dev/null 2>&1 \
          || { fb_orphans=$((fb_orphans+1)); echo "         orphan dir not in cards.json: community/${id}"; }
      done
      [[ "$fb_orphans" -eq 0 ]] \
        && _pass "BLD-FB-04: no orphan ga_frontend_bundle card dirs (cards.json matches disk)" \
        || _fail "BLD-FB-04: ${fb_orphans} orphan card dir(s) not listed in cards.json"
    else
      _fail "BLD-FB-03/04: ga_frontend_bundle community/cards.json MISSING (run scripts/vendor.py)"
    fi
  else
    _fail "BLD-FB-01: ga_frontend_bundle custom_component MISSING from OS rootfs-overlay (expected __init__.py + manifest.json under ${GA_FB_DIR})"
  fi
else
  _skip "BLD-FB-01..04: ga_frontend_bundle in OS overlay" "source tree (buildroot-external) not found"
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

    # BLD-OVERRIDE-01: hassio.mk uses ?= for HASSIO_VERSION_URL so
    # staged-rollout builds can pass an alternate URL via env-var.
    # Reverting to `=` would silently make those builds use main's
    # stable.json, baking the wrong supervisor version into the bundle
    # (caught in build #8 on 2026-05-04).
    # See ga-ihost-docs/RELEASE-STRATEGY.md and INCIDENTS/2026-05-04-*.
    if grep -qE '^HASSIO_VERSION_URL[[:space:]]+\?=' "$HASSIO_MK"; then
      _pass "BLD-OVERRIDE-01: hassio.mk HASSIO_VERSION_URL uses ?= (env-var override compatible)"
    else
      _fail "BLD-OVERRIDE-01: hassio.mk HASSIO_VERSION_URL not conditional (?=) — staged-rollout env-var override breaks"
    fi
  else
    _skip "SRC-01/02 + BLD-OVERRIDE-01" "hassio.mk not found"
  fi

  # BLD-OVERRIDE-02: ga_build.sh threads MAKE_OVERRIDES into make
  # invocations so command-line overrides actually reach the package-level
  # Makefile. Without this, env-var-only overrides get stripped by
  # Buildroot's recursive make + sub-makes (build #8 on 2026-05-04 hit
  # exactly this — env-var was set but build pulled main's stable.json).
  GA_BUILD_SH="${SRC}/scripts/ga_build.sh"
  if [[ -f "$GA_BUILD_SH" ]]; then
    if grep -q 'declare -a MAKE_OVERRIDES' "$GA_BUILD_SH" \
       && grep -q '"\${MAKE_OVERRIDES\[@\]}"' "$GA_BUILD_SH"; then
      _pass "BLD-OVERRIDE-02: ga_build.sh threads MAKE_OVERRIDES into make invocations"
    else
      _fail "BLD-OVERRIDE-02: ga_build.sh missing MAKE_OVERRIDES — staged-rollout env-var override won't propagate"
    fi
  else
    _skip "BLD-OVERRIDE-02" "ga_build.sh not found"
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

  # SRC-10 — REMOVED (V1.2-clean T3): SRC-10a..f checked the greenautarky/
  # frontend fork's build pipeline (greenautarky-setup.html.template,
  # entrypoint TS, bundle.cjs, entry-html.js, the Lit panel, build_frontend
  # verification). That fork is retired — the OS ships the stock
  # home-assistant-frontend inside stock Core, and the GA setup wizard now
  # lives as the greenautarky_onboarding custom_component built in the
  # ha-greenautarky-onboarding repo. None of those source files exist in or
  # near the OS repo any more, so there is nothing here for a build-time OS
  # test to assert. The wizard build is covered by the ha-greenautarky-
  # onboarding repo's own CI; that the component reaches the device is
  # covered by BLD-FE-02 (vendored into the OS rootfs-overlay — T4).

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

      # BLD-VER-CONSISTENCY: HA_VERSION env in build-ga-core.yml matches the
      # Core version selected at OS build time (from version.json fetched via
      # stable.json on whichever release branch the build was pointed at).
      # Catches a desync between the two sources of truth — e.g. someone
      # bumps stable.json on release/v1.X-rebuild but forgets to bump
      # HA_VERSION in build-ga-core.yml. The released image would then carry
      # the wrong io.hass.version label, supervisor would loop.
      if [[ -f "$VER_JSON" ]]; then
        # Two-step extract: find the HA_VERSION line, then pull the version
        # number out of it (greedy regex on a one-liner eats the leading "20").
        HA_VER_ENV=$(grep -E '^[[:space:]]*HA_VERSION:' "$CORE_WF" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?')
        VER_TINKER=$(jq -r '.homeassistant.tinker // "unknown"' "$VER_JSON" 2>/dev/null)
        if [[ -z "$HA_VER_ENV" ]]; then
          _skip "BLD-VER-CONSISTENCY" "could not parse HA_VERSION env from build-ga-core.yml"
        elif [[ "$HA_VER_ENV" = "$VER_TINKER" ]]; then
          _pass "BLD-VER-CONSISTENCY: HA_VERSION ($HA_VER_ENV) in ha-core/build-ga-core.yml matches version.json (homeassistant.tinker=$VER_TINKER)"
        else
          _fail "BLD-VER-CONSISTENCY: HA_VERSION ($HA_VER_ENV) in ha-core/build-ga-core.yml does NOT match version.json (homeassistant.tinker=$VER_TINKER) — bump one to match the other"
        fi
      else
        _skip "BLD-VER-CONSISTENCY" "version.json not yet available (build hasn't reached hassio.mk CONFIGURE_CMDS)"
      fi

      # BLD-RELEASE-MANIFEST: extends BLD-VER-CONSISTENCY by adding the
      # release manifest in greenautarky/releases as a third source of
      # truth. The cut-release.sh flow promises that, for the v1.X bundle
      # the operator is cutting toward:
      #   manifest.versions.core       == HA_VERSION (build-ga-core.yml)
      #                                == version.json.homeassistant.tinker
      #   manifest.versions.supervisor == version.json.supervisor
      #   manifest.versions.os         endswith buildroot-external/meta
      #                                          VERSION_SUFFIX
      # We pick the manifest by ``versions.core == HA_VER_ENV`` — that's
      # what the operator just bumped, regardless of the OS / supervisor
      # state. Falls back to the newest in-development manifest if no
      # core-match exists (e.g. someone bumped HA_VERSION but didn't run
      # cut-release.sh yet — that itself is the kind of drift this test
      # exists to catch).
      RELEASES_DIR=""
      for r_dir in "${SRC}/../releases" "/home/user/git/releases"; do
        [[ -d "$r_dir/releases" ]] && RELEASES_DIR="$r_dir" && break
      done
      if [[ -z "$RELEASES_DIR" ]]; then
        _skip "BLD-RELEASE-MANIFEST" "greenautarky/releases checkout not found"
      elif [[ ! -f "$VER_JSON" ]]; then
        _skip "BLD-RELEASE-MANIFEST" "version.json not yet available"
      elif [[ -z "$HA_VER_ENV" ]]; then
        _skip "BLD-RELEASE-MANIFEST" "could not parse HA_VERSION env (BLD-VER-CONSISTENCY already failed)"
      elif ! command -v python3 >/dev/null 2>&1; then
        _skip "BLD-RELEASE-MANIFEST" "python3 not available for YAML parsing"
      else
        VER_SUP_BUILT="$(jq -r '.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
        META_SUFFIX="$(grep -oE 'VERSION_SUFFIX="[^"]*"' "${SRC}/buildroot-external/meta" 2>/dev/null | cut -d'"' -f2)"
        # Inline python keeps the test self-contained (no extra deps);
        # PyYAML is already required by tools in greenautarky/releases.
        MATCH_OUT="$(python3 - "$RELEASES_DIR/releases" "$HA_VER_ENV" <<'PY' 2>/dev/null
import os, sys, glob
try:
    import yaml
except ImportError:
    print("NOYAML"); sys.exit(0)
root, target_core = sys.argv[1], sys.argv[2]
candidates = []
for p in sorted(glob.glob(os.path.join(root, "v*", "manifest.yaml"))):
    try:
        m = yaml.safe_load(open(p))
    except Exception:
        continue
    if isinstance(m, dict):
        candidates.append((p, m))
if not candidates:
    print("NOMANIFESTS"); sys.exit(0)
exact = [(p, m) for p, m in candidates
         if (m.get("versions") or {}).get("core") == target_core]
chosen = exact[0] if exact else None
if not chosen:
    in_dev = [(p, m) for p, m in candidates if m.get("status") == "in-development"]
    chosen = in_dev[-1] if in_dev else candidates[-1]
p, m = chosen
v = m.get("versions") or {}
print("PATH=" + p)
print("BUNDLE=" + str(m.get("bundle") or "?"))
print("STATUS=" + str(m.get("status") or "?"))
print("OS=" + str(v.get("os") or "?"))
print("CORE=" + str(v.get("core") or "?"))
print("SUP=" + str(v.get("supervisor") or "?"))
print("MATCH_BY_CORE=" + ("yes" if exact else "no"))
PY
)"
        if [[ "$MATCH_OUT" = "NOYAML" ]]; then
          _skip "BLD-RELEASE-MANIFEST" "PyYAML not installed (pip install pyyaml)"
        elif [[ "$MATCH_OUT" = "NOMANIFESTS" ]]; then
          _skip "BLD-RELEASE-MANIFEST" "no manifest.yaml under $RELEASES_DIR/releases/"
        elif [[ -z "$MATCH_OUT" ]]; then
          _skip "BLD-RELEASE-MANIFEST" "manifest selection helper produced no output"
        else
          MAN_PATH=$(echo   "$MATCH_OUT" | grep '^PATH='          | cut -d= -f2-)
          MAN_BUNDLE=$(echo "$MATCH_OUT" | grep '^BUNDLE='        | cut -d= -f2-)
          MAN_STATUS=$(echo "$MATCH_OUT" | grep '^STATUS='        | cut -d= -f2-)
          MAN_OS=$(echo     "$MATCH_OUT" | grep '^OS='            | cut -d= -f2-)
          MAN_CORE=$(echo   "$MATCH_OUT" | grep '^CORE='          | cut -d= -f2-)
          MAN_SUP=$(echo    "$MATCH_OUT" | grep '^SUP='           | cut -d= -f2-)
          MATCHED=$(echo    "$MATCH_OUT" | grep '^MATCH_BY_CORE=' | cut -d= -f2-)
          mismatches=()
          if [[ "$MATCHED" != "yes" ]]; then
            mismatches+=("no manifest with versions.core=$HA_VER_ENV — using newest in-development ($MAN_BUNDLE) as fallback; run cut-release.sh to land the bump")
          fi
          [[ "$MAN_CORE" = "$HA_VER_ENV"    ]] || mismatches+=("core: manifest=$MAN_CORE != build-ga-core.yml HA_VERSION=$HA_VER_ENV")
          [[ "$MAN_CORE" = "$VER_TINKER"    ]] || mismatches+=("core: manifest=$MAN_CORE != version.json.homeassistant.tinker=$VER_TINKER")
          [[ "$MAN_SUP"  = "$VER_SUP_BUILT" ]] || mismatches+=("supervisor: manifest=$MAN_SUP != version.json.supervisor=$VER_SUP_BUILT")
          if [[ -n "$META_SUFFIX" ]]; then
            # Manifest OS string ends with the buildroot suffix, e.g.
            # "16.3.1.2" endswith "1.2".
            case "$MAN_OS" in
              *".$META_SUFFIX") : ;;
              *) mismatches+=("os: manifest=$MAN_OS does not end with buildroot VERSION_SUFFIX=$META_SUFFIX") ;;
            esac
          fi
          if [[ ${#mismatches[@]} -eq 0 ]]; then
            _pass "BLD-RELEASE-MANIFEST: $MAN_BUNDLE ($MAN_STATUS) agrees with version.json + build-ga-core.yml + buildroot meta (os=$MAN_OS, core=$MAN_CORE, sup=$MAN_SUP)"
          else
            _fail "BLD-RELEASE-MANIFEST: $MAN_BUNDLE ($MAN_STATUS) at $MAN_PATH disagrees with build sources: $(printf '%s; ' "${mismatches[@]}")re-run cut-release.sh after bumping all sides in lock-step"
          fi
        fi
      fi
    else
      _skip "SRC-11 + BLD-VER-CONSISTENCY + BLD-RELEASE-MANIFEST" "build-ga-core.yml not found"
    fi
  else
    _skip "SRC-11 + BLD-VER-CONSISTENCY + BLD-RELEASE-MANIFEST" "ha-core repo not found"
  fi

  # SRC-12 — REMOVED (V1.2-clean T3): SRC-12a..g asserted the GA app-flow
  # redirect wired into the greenautarky/frontend fork's authorize.ts and the
  # greenautarky-setup Lit panel (ga_bypass, ga_auth_redirect, the admin
  # escape hatches). The frontend fork is retired — authorize.ts is stock
  # again and the wizard panel moved to the greenautarky_onboarding
  # custom_component (ha-greenautarky-onboarding repo). The OS build cannot
  # assert against a fork that no longer exists; the redirect/escape-hatch
  # behaviour is now the onboarding component repo's own test surface.

  # SRC-13 — REMOVED (V1.2-clean T3): SRC-13a..c asserted that the
  # greenautarky/frontend fork's version was CI-managed (pyproject.toml
  # 0.0.0.dev0 placeholder + the GA Core fork's build-ga-core.yml injection
  # step + the Core fork's frontend pin files). With the frontend fork
  # retired and Core gone stock, there is no GA-managed frontend version:
  # stock Core pins stock home-assistant-frontend itself. Frontend version
  # correctness is now covered by VER-11 (Core io.hass.version label).

  # Locate the frontend repo checkout (legacy — frontend fork is retired by
  # V1.2-clean T3, so this is normally absent). Kept defined for the
  # still-present SRC-14/15/16 frontend checks below, which _skip cleanly
  # when no checkout is found. These remaining frontend checks are out of
  # this rewrite's scope (T2/T3 named families only).
  FE_ROOT=""
  for fe_dir in "${SRC}/../homeassistant_frontend" "/home/user/git/homeassistant_frontend"; do
    [[ -d "$fe_dir/src" ]] && FE_ROOT="$fe_dir" && break
  done

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

    # BLD-ADMIN-01: Core has GAAdminBypassView (the /admin endpoint)
    GA_HTTP="${CORE_ROOT}/homeassistant/components/greenautarky_onboarding/http.py"
    grep -q 'class GAAdminBypassView' "$GA_HTTP" 2>/dev/null \
      && _pass "BLD-ADMIN-01: GAAdminBypassView class exists in core" \
      || _fail "BLD-ADMIN-01: GAAdminBypassView missing — /admin endpoint not implemented"

    # BLD-ADMIN-02: /admin URL is bound to the bypass view
    grep -A 30 'class GAAdminBypassView' "$GA_HTTP" 2>/dev/null \
      | grep -qE '^\s*url\s*=\s*"/admin"' \
      && _pass "BLD-ADMIN-02: GAAdminBypassView is bound to /admin" \
      || _fail "BLD-ADMIN-02: GAAdminBypassView is NOT bound to /admin"

    # BLD-ADMIN-03: redirect_uri uses /config (not /lovelace) — avoids GA panel auto-default
    grep -A 30 'class GAAdminBypassView' "$GA_HTTP" 2>/dev/null \
      | grep -qE 'redirect_uri.*\{origin\}/config' \
      && _pass "BLD-ADMIN-03: GAAdminBypassView uses /config (not /lovelace) so admin lands in HA Settings" \
      || _fail "BLD-ADMIN-03: GAAdminBypassView redirect_uri does not point to /config — admin lands back on GA panel"

    # BLD-ADMIN-04: GAAdminBypassView is registered in __init__.py (otherwise the URL is dead)
    GA_INIT="${CORE_ROOT}/homeassistant/components/greenautarky_onboarding/__init__.py"
    grep -q 'GAAdminBypassView' "$GA_INIT" 2>/dev/null \
      && _pass "BLD-ADMIN-04: GAAdminBypassView is registered in greenautarky_onboarding/__init__.py" \
      || _fail "BLD-ADMIN-04: GAAdminBypassView is NOT registered — /admin will return 404"
  else
    _skip "SRC-14d..e + BLD-ADMIN-01..04" "ha-core repo not found"
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
    # SCRIPT_DIR was never defined — fall back to this script's own dir so
    # the check is robust under `set -u` (pre-existing latent bug).
    grep -q 'QR auto-inject' "${SCRIPT_DIR:-$(dirname "$0")}/../../e2e/tests/pin-verification.spec.ts" 2>/dev/null \
      && _pass "SRC-15d: QR auto-inject E2E tests exist" \
      || _fail "SRC-15d: QR auto-inject E2E tests missing"
  else
    _skip "SRC-15a..d" "frontend repo not found"
  fi

  # SRC-16: Ethernet consent integration (frontend + core)
  if [[ -n "$FE_ROOT" ]]; then
    [[ -f "${FE_ROOT}/src/panels/greenautarky-setup/ga-setup-ethernet.ts" ]] \
      && _pass "SRC-16a: ga-setup-ethernet.ts component exists" \
      || _fail "SRC-16a: ga-setup-ethernet.ts missing"

    grep -q '"ethernet"' "${FE_ROOT}/src/panels/greenautarky-setup/ha-panel-greenautarky-setup.ts" 2>/dev/null \
      && _pass "SRC-16b: wizard STEPS includes ethernet" \
      || _fail "SRC-16b: wizard STEPS missing ethernet step"

    grep -q 'setEthernetPreference' "${FE_ROOT}/src/data/greenautarky_setup.ts" 2>/dev/null \
      && _pass "SRC-16c: setEthernetPreference API function exists" \
      || _fail "SRC-16c: setEthernetPreference missing from API client"
  else
    _skip "SRC-16a..c" "frontend repo not found"
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
  # GAOS — V1.2-clean OS bake (replaces the retired fork model)
  # Asserts the V1.2-clean OS bakes the GA addon container images into the
  # local Docker store (addon-images.json) and that ga-bootstrap.service
  # registers the public greenautarky/vibe_addons addon repository and
  # installs the ga_manager addon FROM it (a repo-linked addon, NOT a
  # `local_*` addon — so a self-provisioned device's install path is
  # identical to a normal "add the repo, install the addon" flow).
  # See ga-ihost-docs/V1.2-CLEAN-REBUILD.md T4. These check the source
  # overlay tree, so they run without a full build.
  # =========================================================================
  echo ""
  echo "--- GAOS: V1.2-clean OS bake (vibe_addons repo + image bake + bootstrap) ---"

  ADDON_IMAGES_JSON="${SRC}/buildroot-external/package/hassio/addon-images.json"
  # ga-bootstrap migrated to a Tier-2 OCI component (PR #33). sync-components.sh
  # extracts the script into usr/sbin/ and the systemd unit into etc/systemd/system/.
  # ga-bootstrap-disk is NOT a Tier-2 component (pre-Supervisor, bound to the OS
  # image lifecycle) — it stays at the rootfs-baked path under usr/lib/systemd/system/.
  GA_BOOTSTRAP="${SRC}/buildroot-external/rootfs-overlay/usr/sbin/ga-bootstrap"
  OVL_USRLIB_SYSTEMD="${SRC}/buildroot-external/rootfs-overlay/usr/lib/systemd/system"
  OVL_ETC_SYSTEMD="${SRC}/buildroot-external/rootfs-overlay/etc/systemd/system"
  # Resolve which dir holds each unit — ga-bootstrap (Tier-2) lives in etc/,
  # ga-bootstrap-disk (rootfs-baked) lives in usr/lib/. A single helper that
  # finds either keeps the test future-proof if a unit moves later.
  _find_unit() {
    local svc="$1"
    if [[ -f "${OVL_ETC_SYSTEMD}/${svc}" ]]; then
      printf '%s' "${OVL_ETC_SYSTEMD}/${svc}"
    elif [[ -f "${OVL_USRLIB_SYSTEMD}/${svc}" ]]; then
      printf '%s' "${OVL_USRLIB_SYSTEMD}/${svc}"
    fi
  }

  # GAOS-01: addon-images.json includes a ga_manager entry (so the addon
  # container image is baked into the data partition's docker store and the
  # repo-linked addon installs offline on first boot).
  if [[ -f "$ADDON_IMAGES_JSON" ]]; then
    GAOS_MGR_IMG="$(jq -r '.addons.ga_manager.image // empty' "$ADDON_IMAGES_JSON" 2>/dev/null)"
    if [[ -n "$GAOS_MGR_IMG" ]]; then
      _pass "GAOS-01: addon-images.json has a ga_manager entry ($GAOS_MGR_IMG)"
    else
      _fail "GAOS-01: addon-images.json has NO ga_manager entry — addon won't be baked offline"
    fi
  else
    _skip "GAOS-01" "addon-images.json not found at $ADDON_IMAGES_JSON"
  fi

  # GAOS-02: ga-bootstrap registers the public vibe_addons addon repository
  # (a repo-linked addon flow — NOT obsolete `local_*` addons). The vendored
  # local-addons overlay tree must be GONE.
  if [[ -f "$GA_BOOTSTRAP" ]]; then
    grep -qE 'github\.com/greenautarky/vibe_addons' "$GA_BOOTSTRAP" 2>/dev/null \
      && _pass "GAOS-02: ga-bootstrap registers the greenautarky/vibe_addons addon repo" \
      || _fail "GAOS-02: ga-bootstrap does NOT reference the vibe_addons addon repo"
    grep -qE '\bha\b.*store add|store add' "$GA_BOOTSTRAP" 2>/dev/null \
      && _pass "GAOS-02b: ga-bootstrap uses 'ha store add' to register the repo" \
      || _fail "GAOS-02b: ga-bootstrap does NOT 'ha store add' the repo"
  else
    _fail "GAOS-02: ga-bootstrap script missing ($GA_BOOTSTRAP)"
  fi
  if [[ -d "${SRC}/buildroot-external/rootfs-overlay/usr/share/ga/local-addons" ]]; then
    _fail "GAOS-02c: obsolete vendored local-addons overlay tree still present — must be removed"
  else
    _pass "GAOS-02c: obsolete vendored local-addons overlay tree removed"
  fi

  # GAOS-03: ga-bootstrap resolves the repo-prefixed addon slug DYNAMICALLY
  # (the Supervisor assigns a git-repo addon `<repo_id>_ga_manager`, a hash
  # prefix — never `local_`). The script must NOT hardcode a `local_ga_manager`
  # install slug.
  if [[ -f "$GA_BOOTSTRAP" ]]; then
    # Ignore comment lines — a header comment may mention `local_ga_manager`
    # to explain the contrast; what matters is no code hardcodes it.
    if grep -vE '^[[:space:]]*#' "$GA_BOOTSTRAP" 2>/dev/null \
        | grep -qE 'local_ga_manager'; then
      _fail "GAOS-03: ga-bootstrap still hardcodes a 'local_ga_manager' slug in code — must resolve dynamically"
    else
      _pass "GAOS-03: ga-bootstrap does not hardcode a 'local_ga_manager' slug in code"
    fi
    # Either the slug is resolved dynamically (= old rootfs ga-bootstrap
    # pattern: `resolve_ga_manager_slug` / `ha store addons` lookup) OR
    # it's a pinned constant + env-overridable (= Tier-2 v1.1.0+ pattern:
    # `GA_MANAGER_SLUG="${GA_MANAGER_SLUG:-99f1cad4_ga_manager}"`).
    # Both are valid — the constant works because vibe_addons' repo-id
    # hash is fleet-stable (= `99f1cad4_`) and the env override makes
    # field-overrides + tests trivial. Failing means we have NEITHER
    # discipline, i.e. a real `local_*` or unresolved slug.
    if grep -qE 'resolve_ga_manager_slug|store addons' "$GA_BOOTSTRAP" 2>/dev/null; then
      _pass "GAOS-03b: ga-bootstrap resolves the repo-prefixed slug from the store listing"
    elif grep -qE '^\s*GA_MANAGER_SLUG="\$\{GA_MANAGER_SLUG:-[a-f0-9]+_[a-z_]+\}"' "$GA_BOOTSTRAP" 2>/dev/null; then
      _pass "GAOS-03b: ga-bootstrap uses a pinned-constant slug with env override (Tier-2 pattern)"
    else
      _fail "GAOS-03b: ga-bootstrap does NOT resolve the slug dynamically AND has no pinned-constant pattern — verify the install path"
    fi
  else
    _skip "GAOS-03" "ga-bootstrap script not found"
  fi

  # GAOS-04: every addon image baked into addon-images.json carries a real
  # image ref (no empty/`latest` tag); the ga_manager image is on the
  # greenautarky GHCR namespace — matching the vibe_addons config.yaml.
  if [[ -f "$ADDON_IMAGES_JSON" ]]; then
    GAOS_BAD=0
    while IFS= read -r _img; do
      [[ -z "$_img" || "$_img" == "null" ]] && GAOS_BAD=$((GAOS_BAD + 1))
      [[ "$_img" == *":latest" ]] && GAOS_BAD=$((GAOS_BAD + 1))
    done < <(jq -r '.addons | to_entries[] | .value.image' "$ADDON_IMAGES_JSON" 2>/dev/null)
    if [[ "$GAOS_BAD" -eq 0 ]]; then
      _pass "GAOS-04: all addon-images.json image refs are concrete (no empty/:latest)"
    else
      _fail "GAOS-04: addon-images.json has $GAOS_BAD bad image ref(s) (empty or :latest)"
    fi
    GAOS_MGR_IMG="$(jq -r '.addons.ga_manager.image // empty' "$ADDON_IMAGES_JSON" 2>/dev/null)"
    if [[ "$GAOS_MGR_IMG" == ghcr.io/greenautarky/ga_manager-* ]]; then
      _pass "GAOS-04b: ga_manager baked image matches the vibe_addons config.yaml image: ($GAOS_MGR_IMG)"
    else
      _fail "GAOS-04b: ga_manager baked image ($GAOS_MGR_IMG) != ghcr.io/greenautarky/ga_manager-{arch}"
    fi
  else
    _skip "GAOS-04" "addon-images.json not found"
  fi

  # GAOS-05: ga-bootstrap.service + ga-bootstrap-disk.service exist in the
  # overlay. ga-bootstrap registers the vibe_addons repo and installs/runs
  # the ga_manager addon from it every boot; ga-bootstrap-disk does the
  # early eMMC erase + OS marker.
  for _svc in ga-bootstrap.service ga-bootstrap-disk.service; do
    _svc_path="$(_find_unit "${_svc}")"
    [[ -n "${_svc_path}" ]] \
      && _pass "GAOS-05: ${_svc} unit present in overlay (${_svc_path#${SRC}/})" \
      || _fail "GAOS-05: ${_svc} NOT present in overlay (neither ${OVL_ETC_SYSTEMD} nor ${OVL_USRLIB_SYSTEMD})"
  done

  # GAOS-06: both bootstrap services are ENABLED via .wants/ symlinks.
  # ga-bootstrap → multi-user.target.wants, ga-bootstrap-disk → sysinit.
  if [[ -L "${OVL_ETC_SYSTEMD}/multi-user.target.wants/ga-bootstrap.service" ]]; then
    _pass "GAOS-06: ga-bootstrap.service enabled (multi-user.target.wants symlink)"
  else
    _fail "GAOS-06: ga-bootstrap.service NOT enabled — no multi-user.target.wants symlink"
  fi
  if [[ -L "${OVL_ETC_SYSTEMD}/sysinit.target.wants/ga-bootstrap-disk.service" ]]; then
    _pass "GAOS-06: ga-bootstrap-disk.service enabled (sysinit.target.wants symlink)"
  else
    _fail "GAOS-06: ga-bootstrap-disk.service NOT enabled — no sysinit.target.wants symlink"
  fi

  # GAOS-07: ga-bootstrap.service is ordered after the Supervisor — it
  # registers the vibe_addons repo and installs the ga_manager addon
  # through the Supervisor API. The unit name is `hassio-supervisor`
  # (the HAOS convention), not `hassos-supervisor`. Accept both spellings
  # for backward-compat with the old rootfs-baked unit, which used the
  # `hassos-` typo in some checkouts.
  _bootstrap_svc_path="$(_find_unit ga-bootstrap.service)"
  if [[ -n "${_bootstrap_svc_path}" ]]; then
    grep -qE '(After|Requires)=.*(hassio|hassos)-supervisor' "${_bootstrap_svc_path}" 2>/dev/null \
      && _pass "GAOS-07: ga-bootstrap.service ordered after hassio-supervisor (${_bootstrap_svc_path#${SRC}/})" \
      || _fail "GAOS-07: ga-bootstrap.service NOT ordered after hassio-supervisor — addon install will race the Supervisor"
  else
    _skip "GAOS-07" "ga-bootstrap.service not found in overlay"
  fi

  # BLD-SUP-DNS: Supervisor fork has GA DNS entries in dns.py
  SUP_ROOT=""
  for sup_dir in "${SRC}/../supervisor" "/home/user/git/supervisor"; do
    [[ -d "$sup_dir/supervisor" ]] && SUP_ROOT="$sup_dir" && break
  done
  if [[ -n "$SUP_ROOT" ]]; then
    DNS_PY="${SUP_ROOT}/supervisor/plugins/dns.py"
    if [[ -f "$DNS_PY" ]]; then
      grep -q 'ota.greenautarky.com' "$DNS_PY" 2>/dev/null \
        && _pass "BLD-SUP-DNS-a: dns.py has ota.greenautarky.com" \
        || _fail "BLD-SUP-DNS-a: dns.py missing ota.greenautarky.com — Supervisor won't inject GA DNS"

      grep -q 'influx.greenautarky.com' "$DNS_PY" 2>/dev/null \
        && _pass "BLD-SUP-DNS-b: dns.py has influx.greenautarky.com" \
        || _fail "BLD-SUP-DNS-b: dns.py missing influx.greenautarky.com"

      grep -q 'loki.greenautarky.com' "$DNS_PY" 2>/dev/null \
        && _pass "BLD-SUP-DNS-c: dns.py has loki.greenautarky.com" \
        || _fail "BLD-SUP-DNS-c: dns.py missing loki.greenautarky.com"

      # SVC-09: Supervisor dns.py reads ga-services.conf (not hardcoded IP)
      grep -q '_load_ga_services_ip' "$DNS_PY" 2>/dev/null \
        && _pass "SVC-09: dns.py uses _load_ga_services_ip (centralized config)" \
        || _fail "SVC-09: dns.py does NOT use _load_ga_services_ip — IP may be hardcoded"

      # SVC-09b: Supervisor dns.py uses dynamic OTA picker (consistent with host)
      grep -q '_load_ga_ota_ip' "$DNS_PY" 2>/dev/null \
        && _pass "SVC-09b: dns.py uses _load_ga_ota_ip (dynamic ota failover)" \
        || _fail "SVC-09b: dns.py does NOT use _load_ga_ota_ip — ota may diverge from host /etc/hosts"

      # SVC-09c: Supervisor dns.py hardcoded fallback matches current GA_SERVICES_IP
      EXPECTED_IP=$(grep '^GA_SERVICES_IP=' "$BASE_DIR/buildroot-external/rootfs-overlay/etc/ga-services.conf" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'" | tr -d ' ')
      if [ -n "$EXPECTED_IP" ]; then
        if grep -q "_GA_HARDCODED_FALLBACK_IP = \"$EXPECTED_IP\"" "$DNS_PY" 2>/dev/null; then
          _pass "SVC-09c: dns.py hardcoded fallback ($EXPECTED_IP) matches ga-services.conf"
        else
          _fail "SVC-09c: dns.py hardcoded fallback does NOT match ga-services.conf ($EXPECTED_IP)"
        fi
      else
        _skip "SVC-09c" "could not parse GA_SERVICES_IP from ga-services.conf"
      fi
    else
      _skip "BLD-SUP-DNS-a..c" "dns.py not found in supervisor fork"
    fi
  else
    _skip "BLD-SUP-DNS-a..c" "supervisor repo not found"
  fi

  # =========================================================================
  # Integration: ga-services.conf ↔ service configs ↔ dns.py consistency
  # =========================================================================
  echo ""
  echo "--- Integration: endpoint hostname consistency ---"

  SVC_CONF="${SRC}/buildroot-external/rootfs-overlay/etc/ga-services.conf"
  TEL_CONF="${SRC}/buildroot-external/package/telegraf/telegraf.conf"
  TEL_DEBUG="${SRC}/buildroot-external/package/telegraf/telegraf-debug.conf"
  FB_CONF="${SRC}/buildroot-external/package/fluent-bit-config/fluent-bit.conf"
  FB_DEBUG="${SRC}/buildroot-external/package/fluent-bit-config/fluent-bit-debug.conf"

  if [[ -f "$SVC_CONF" ]]; then
    # Load hostnames from ga-services.conf
    _INFLUX_HOST=$(grep 'GA_INFLUX_HOST=' "$SVC_CONF" | head -1 | cut -d= -f2)
    _LOKI_HOST=$(grep 'GA_LOKI_HOST=' "$SVC_CONF" | head -1 | cut -d= -f2)
    _OTA_HOST=$(grep 'GA_OTA_HOST=' "$SVC_CONF" | head -1 | cut -d= -f2)

    # INT-01: telegraf.conf uses the same influx hostname as ga-services.conf
    if [[ -f "$TEL_CONF" ]] && grep -q "$_INFLUX_HOST" "$TEL_CONF" 2>/dev/null; then
      _pass "INT-01: telegraf.conf influx host matches ga-services.conf ($_INFLUX_HOST)"
    else
      _fail "INT-01: telegraf.conf influx host does NOT match ga-services.conf ($_INFLUX_HOST)"
    fi

    # INT-02: telegraf-debug.conf uses the same influx hostname
    if [[ -f "$TEL_DEBUG" ]] && grep -q "$_INFLUX_HOST" "$TEL_DEBUG" 2>/dev/null; then
      _pass "INT-02: telegraf-debug.conf influx host matches ga-services.conf"
    elif [[ ! -f "$TEL_DEBUG" ]]; then
      _skip "INT-02" "telegraf-debug.conf not found"
    else
      _fail "INT-02: telegraf-debug.conf influx host mismatch"
    fi

    # INT-03: fluent-bit.conf uses the same loki hostname as ga-services.conf
    if [[ -f "$FB_CONF" ]] && grep -q "$_LOKI_HOST" "$FB_CONF" 2>/dev/null; then
      _pass "INT-03: fluent-bit.conf loki host matches ga-services.conf ($_LOKI_HOST)"
    else
      _fail "INT-03: fluent-bit.conf loki host does NOT match ga-services.conf ($_LOKI_HOST)"
    fi

    # INT-04: fluent-bit-debug.conf uses the same loki hostname
    if [[ -f "$FB_DEBUG" ]] && grep -q "$_LOKI_HOST" "$FB_DEBUG" 2>/dev/null; then
      _pass "INT-04: fluent-bit-debug.conf loki host matches ga-services.conf"
    elif [[ ! -f "$FB_DEBUG" ]]; then
      _skip "INT-04" "fluent-bit-debug.conf not found"
    else
      _fail "INT-04: fluent-bit-debug.conf loki host mismatch"
    fi

    # INT-05: Supervisor dns.py has all three hostnames from ga-services.conf
    if [[ -n "$SUP_ROOT" && -f "${SUP_ROOT}/supervisor/plugins/dns.py" ]]; then
      _dns_ok=true
      for _host in "$_INFLUX_HOST" "$_LOKI_HOST" "$_OTA_HOST"; do
        grep -q "$_host" "${SUP_ROOT}/supervisor/plugins/dns.py" 2>/dev/null || _dns_ok=false
      done
      if $_dns_ok; then
        _pass "INT-05: dns.py has all 3 hostnames from ga-services.conf"
      else
        _fail "INT-05: dns.py missing hostnames from ga-services.conf — containers won't resolve GA services"
      fi
    else
      _skip "INT-05" "supervisor dns.py not available"
    fi

    # INT-06: ga-update-hosts script references all hostnames from ga-services.conf
    _UH="${SRC}/buildroot-ihost/rootfs-overlay/usr/sbin/ga-update-hosts"
    if [[ -f "$_UH" ]]; then
      _uh_ok=true
      for _var in "GA_INFLUX_HOST" "GA_LOKI_HOST" "GA_OTA_HOST"; do
        grep -q "$_var" "$_UH" 2>/dev/null || _uh_ok=false
      done
      if $_uh_ok; then
        _pass "INT-06: ga-update-hosts uses all hostname vars from ga-services.conf"
      else
        _fail "INT-06: ga-update-hosts missing hostname vars — /etc/hosts will be incomplete"
      fi
    else
      _skip "INT-06" "ga-update-hosts not found"
    fi

    # INT-07: No hardcoded ga-tools IP in telegraf/fluent-bit configs
    _SVC_IP=$(grep 'GA_SERVICES_IP=' "$SVC_CONF" | head -1 | cut -d= -f2)
    _hardcoded=false
    for _cfg in "$TEL_CONF" "$TEL_DEBUG" "$FB_CONF" "$FB_DEBUG"; do
      [[ -f "$_cfg" ]] && grep -qE "^[^#]*$_SVC_IP" "$_cfg" 2>/dev/null && _hardcoded=true
    done
    if ! $_hardcoded; then
      _pass "INT-07: No hardcoded ga-tools IP in service configs (using hostnames)"
    else
      _fail "INT-07: Found hardcoded IP $_SVC_IP in service config — should use hostname"
    fi

    # INT-08: ga-services.conf IP is valid IPv4
    if echo "$_SVC_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
      _pass "INT-08: GA_SERVICES_IP is valid IPv4 ($_SVC_IP)"
    else
      _fail "INT-08: GA_SERVICES_IP is NOT valid IPv4 ($_SVC_IP)"
    fi

  else
    _skip "INT-01..08" "ga-services.conf not found at $SVC_CONF"
  fi

  # =========================================================================
  # Cross-repo version alignment (fetches stable.json, compares with local)
  # =========================================================================
  echo ""
  echo "--- Cross-repo version alignment ---"

  # V1.2-clean WIP: fetch the version source from the release/v1.2-rebuild
  # branch's stable.json (stock Core image + version, GA supervisor). This
  # is the SAME branch the OS build itself reads — see hassio.mk
  # HASSIO_VERSION_URL. Revert to main/ when release/v1.2-rebuild is merged
  # at the V1.2 promote (mirror the hassio.mk comment when you do).
  STABLE_JSON="$(curl -sf 'https://raw.githubusercontent.com/greenautarky/haos-version/release/v1.2-rebuild/stable.json' 2>/dev/null || true)"

  if [[ -n "$STABLE_JSON" ]]; then
    STABLE_CORE="$(echo "$STABLE_JSON" | jq -r '.core // "unknown"')"
    STABLE_SUP="$(echo "$STABLE_JSON" | jq -r '.supervisor // "unknown"')"
    STABLE_CORE_IMG="$(echo "$STABLE_JSON" | jq -r '.images.core // "unknown"')"
    STABLE_SUP_IMG="$(echo "$STABLE_JSON" | jq -r '.images.supervisor // "unknown"')"
    STABLE_CORE_TINKER="$(echo "$STABLE_JSON" | jq -r '.homeassistant.tinker // "unknown"')"

    # XVER-01 (V1.2-clean): stable.json core is a STOCK 3-part HA calver
    # (YYYY.MM.PATCH). The retired fork used a 4-part `.N` GA suffix; clean
    # V1.2 ships stock Core, so the version must be exactly 3 parts.
    if [[ "$STABLE_CORE" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]]; then
      _pass "XVER-01: stable.json core is a stock 3-part calver: $STABLE_CORE"
    else
      _fail "XVER-01: stable.json core is NOT a stock 3-part calver: $STABLE_CORE (V1.2-clean Core must be plain YYYY.MM.PATCH — no .N / -ga.N suffix)"
    fi

    # XVER-02 (V1.2-clean): stable.json supervisor is a GA-fork calver. The
    # Supervisor stays a GA fork (permanent armv7 fork), so it keeps the
    # 4-part `.N` GA build counter — currently 2025.11.5.2.
    if [[ "$STABLE_SUP" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      _pass "XVER-02: stable.json supervisor is a GA-fork calver: $STABLE_SUP"
    else
      _fail "XVER-02: stable.json supervisor is NOT a 4-part GA-fork calver: $STABLE_SUP (expected YYYY.MM.PATCH.N)"
    fi

    # XVER-03 (V1.2-clean): Core fork retired — stable.json core image must
    # be STOCK upstream (ghcr.io/home-assistant/*), NOT greenautarky.
    [[ "$STABLE_CORE_IMG" == ghcr.io/home-assistant/* ]] \
      && _pass "XVER-03: stable.json core image is stock upstream: $STABLE_CORE_IMG" \
      || _fail "XVER-03: stable.json core image is NOT stock ghcr.io/home-assistant/*: $STABLE_CORE_IMG"

    # XVER-04: stable.json supervisor image is greenautarky (GA fork stays)
    [[ "$STABLE_SUP_IMG" == *greenautarky* ]] \
      && _pass "XVER-04: stable.json supervisor image is greenautarky: $STABLE_SUP_IMG" \
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
      _skip "XVER-06" "version.json not found (full build needed)"
    fi

    # XVER-07: build version.json supervisor matches stable.json supervisor.
    # (XVER-06 already covers core; this catches a Supervisor desync — the
    # OS reads version.json from the same branch this stable.json is on.)
    if [[ -f "$VER_JSON" ]]; then
      BUILD_SUP="$(jq -r '.supervisor // "unknown"' "$VER_JSON" 2>/dev/null)"
      if [[ "$BUILD_SUP" == "$STABLE_SUP" ]]; then
        _pass "XVER-07: build version.json supervisor ($BUILD_SUP) matches stable.json ($STABLE_SUP)"
      else
        _fail "XVER-07: build version.json supervisor ($BUILD_SUP) != stable.json ($STABLE_SUP)"
      fi
    else
      _skip "XVER-07" "build version.json not present (full build needed)"
    fi

    # XVER-08: No -ga.N pattern anywhere in stable.json (enforce calver).
    # AwesomeVersion treats a SemVer -ga.N suffix differently — it must
    # never appear; the GA build counter is the 4-part `.N` instead.
    if echo "$STABLE_JSON" | grep -qE '"[0-9]{4}\.[0-9]+\.[0-9]+-ga\.[0-9]+"'; then
      _fail "XVER-08: stable.json still contains a -ga.N version (must use .N calver)"
    else
      _pass "XVER-08: stable.json has no -ga.N versions (clean calver)"
    fi
  else
    _skip "XVER-01..08" "could not fetch stable.json from release/v1.2-rebuild (offline or network error)"
  fi

else
  _skip "SRC-01..09" "source tree not found (expected /build or parent of output)"
  _skip "XVER-01..08" "source tree not found"
fi

# =========================================================================
# SSH-01..05: operator SSH key baked into image + seeded on first boot
# =========================================================================
# Why: HAOS dropbear has `ConditionFileNotEmpty=/root/.ssh/authorized_keys`.
# /root/.ssh is bind-mounted from /mnt/overlay/root/.ssh (sdc7 overlay
# partition), which is EMPTY on a freshly-flashed device. Without an
# authorized_keys seed the bind mount shadows the rootfs default → dropbear
# never starts → port 22222 closed → device unreachable except via serial.
# Discovered live on KIB-SON-31 on 2026-05-27 — root cause of "device is up
# but SSH doesn't work after fresh flash".
#
# Source of truth: buildroot-external/rootfs-overlay/usr/share/ga-ssh/authorized_keys
# Seeded to:       /mnt/overlay/root/.ssh/authorized_keys (by hassos-overlay)
# Bind-mounted to: /root/.ssh/authorized_keys (by root-.ssh.mount)

GA_SSH_AK="${TARGET}/usr/share/ga-ssh/authorized_keys"
HASSOS_OVERLAY_SH="${TARGET}/usr/libexec/hassos-overlay"

# SSH-01: baked authorized_keys file present on rootfs.
if [[ -f "$GA_SSH_AK" ]]; then
  _pass "SSH-01: /usr/share/ga-ssh/authorized_keys baked on rootfs"
else
  _fail "SSH-01: /usr/share/ga-ssh/authorized_keys missing (fresh-flash devices will have NO SSH access)"
fi

# SSH-02: file is non-empty and contains at least one valid OpenSSH pubkey.
# Lines starting with # or blank are ignored (the file uses # for comments).
if [[ -f "$GA_SSH_AK" ]]; then
  PUBKEY_COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-) ' "$GA_SSH_AK" 2>/dev/null || echo 0)
  if [[ "${PUBKEY_COUNT}" -ge 1 ]]; then
    _pass "SSH-02: ${PUBKEY_COUNT} valid OpenSSH pubkey(s) in authorized_keys"
  else
    _fail "SSH-02: no valid OpenSSH pubkey lines found in $GA_SSH_AK"
  fi
fi

# SSH-03: file world-readable + root-owned (it gets copied to a 0600 file
# at runtime; the source itself only needs to be readable by the script).
if [[ -f "$GA_SSH_AK" ]]; then
  PERMS=$(stat -c '%a' "$GA_SSH_AK" 2>/dev/null)
  # 644 (or 444 read-only) is fine; anything more permissive is fine for a public key
  # but we want to flag if it's writable by group/world (security hygiene).
  case "$PERMS" in
    644|640|444|440|600|400) _pass "SSH-03: authorized_keys perms $PERMS (safe)" ;;
    *)                       _fail "SSH-03: authorized_keys perms $PERMS (unexpected — check umask)" ;;
  esac
fi

# SSH-04: hassos-overlay copies the file into /mnt/overlay/root/.ssh on first boot.
# Guarded by `[ ! -f ... ]` (idempotent — preserves operator edits).
if [[ -f "$HASSOS_OVERLAY_SH" ]]; then
  if grep -q '/usr/share/ga-ssh/authorized_keys' "$HASSOS_OVERLAY_SH" 2>/dev/null \
     && grep -q '/mnt/overlay/root/.ssh/authorized_keys' "$HASSOS_OVERLAY_SH" 2>/dev/null; then
    _pass "SSH-04: hassos-overlay seeds /mnt/overlay/root/.ssh/authorized_keys"
  else
    _fail "SSH-04: hassos-overlay missing the SSH-key seed block"
  fi
  # SSH-04b: the copy is guarded (idempotent) — never clobbers operator additions.
  if grep -B1 '/mnt/overlay/root/.ssh/authorized_keys' "$HASSOS_OVERLAY_SH" 2>/dev/null \
       | grep -q '!\s*-f' ; then
    _pass "SSH-04b: hassos-overlay seed is guarded (never overwrites existing)"
  else
    _fail "SSH-04b: hassos-overlay seed missing the [ ! -f ] guard (will overwrite operator edits on every boot)"
  fi
else
  _fail "SSH-04: hassos-overlay script missing at $HASSOS_OVERLAY_SH"
fi

# SSH-05: dropbear unit unchanged invariant — ConditionFileNotEmpty must
# still require /root/.ssh/authorized_keys. If someone weakens this we
# risk shipping an SSH-listening device with no key authorization.
DROPBEAR_UNIT="${TARGET}/usr/lib/systemd/system/dropbear.service.d/hassos.conf"
if [[ -f "$DROPBEAR_UNIT" ]]; then
  grep -qE 'ConditionFileNotEmpty=/root/\.ssh/authorized_keys' "$DROPBEAR_UNIT" \
    && _pass "SSH-05: dropbear unit still gates on authorized_keys (no orphan-listener risk)" \
    || _fail "SSH-05: dropbear ConditionFileNotEmpty=/root/.ssh/authorized_keys removed — SSH could listen with no keys!"
fi

# =========================================================================
# BS-RETRY-01..02: ga-bootstrap exponential-backoff retry for `ha store add`
# =========================================================================
# Commit 9b6c28198. First-boot `ha store add` is racy because the
# Supervisor's git clone can fail post-API-success ("invalid HEAD",
# exit 128) within the first 1-2 minutes. Retry sequence: 0 / 10 / 30 / 60 /
# 120 / 240 = ~8 min budget. Regression-guard so a later edit doesn't
# silently drop the retry.

if [[ -f "$GA_BOOTSTRAP" ]]; then
  # BS-RETRY-01: exponential-backoff retry sequence is present. Accept
  # EITHER the literal `for pre_sleep in 0 10 30 60 120 240` (= old
  # rootfs ga-bootstrap pattern) OR the v1.2.0+ Tier-2 pattern of
  # `BACKOFF_SEQUENCE="${BACKOFF_SEQUENCE:-0 10 30 60 120 240}"` with
  # the loop using `$BACKOFF_SEQUENCE`. The env-overridable form is
  # the preferred shape — it keeps the production budget identical AND
  # lets tests run in seconds by overriding the env var.
  if grep -qE 'for[[:space:]]+pre_sleep[[:space:]]+in[[:space:]]+0[[:space:]]+10[[:space:]]+30[[:space:]]+60[[:space:]]+120[[:space:]]+240' "$GA_BOOTSTRAP"; then
    _pass "BS-RETRY-01: ga-bootstrap has literal exponential-backoff retry (0 10 30 60 120 240)"
  elif grep -qE 'BACKOFF_SEQUENCE=.*0[[:space:]]+10[[:space:]]+30[[:space:]]+60[[:space:]]+120[[:space:]]+240' "$GA_BOOTSTRAP" \
       && grep -qE 'for[[:space:]]+pre_sleep[[:space:]]+in[[:space:]]+\$BACKOFF_SEQUENCE' "$GA_BOOTSTRAP"; then
    _pass "BS-RETRY-01: ga-bootstrap has env-overridable exponential-backoff retry (BACKOFF_SEQUENCE default 0 10 30 60 120 240)"
  else
    _fail "BS-RETRY-01: ga-bootstrap exponential-backoff sequence missing/changed (neither literal nor BACKOFF_SEQUENCE env-var pattern)"
  fi
  # BS-RETRY-02: success requires BOTH 'ha store add' OK AND the repo
  # actually appearing in the store. The Supervisor clones asynchronously
  # so a 0 exit-code is not trust-worthy on its own (memory note in the
  # script's comment + commit body).
  if grep -qE 'addon_repo_present' "$GA_BOOTSTRAP" \
     && grep -qE 'ha[[:space:]]+store[[:space:]]+add' "$GA_BOOTSTRAP"; then
    _pass "BS-RETRY-02: ga-bootstrap verifies addon_repo_present after ha store add"
  else
    _fail "BS-RETRY-02: ga-bootstrap missing addon_repo_present verification"
  fi
fi

# =========================================================================
# BS-JQ-01: ga-bootstrap addon_installed tests version VALUE, not key
# =========================================================================
# Commit feba8fa12. Old code `grep -q '"version"'` matched the JSON key
# (always present, value can be null on uninstalled addons) → addon_installed
# always returned true → ga_manager appeared "installed" pre-install and the
# install step was skipped. Fixed to jq with `.data.version // .version //
# empty`. Regression-guard so we don't slide back into the trap.

if [[ -f "$GA_BOOTSTRAP" ]]; then
  # The fix uses a `jq -r` extracting `.data.version // .version // empty`
  # (with a -e exit check) inside addon_installed. Match the pattern flexibly.
  if grep -qE 'addon_installed' "$GA_BOOTSTRAP"; then
    if grep -qE '\.data\.version[[:space:]]*//[[:space:]]*\.version' "$GA_BOOTSTRAP" \
       || grep -qE 'jq[[:space:]]+-[er]+[^|]+\.data\.version' "$GA_BOOTSTRAP"; then
      _pass "BS-JQ-01: ga-bootstrap addon_installed checks version VALUE via jq (.data.version // .version)"
    else
      _fail "BS-JQ-01: ga-bootstrap addon_installed missing the version-value jq pattern (regression to key-only check?)"
    fi
    # BS-JQ-02: must NOT be the buggy `grep -q '\"version\"'` pattern alone
    # for addon_installed determination.
    if grep -B2 'addon_installed' "$GA_BOOTSTRAP" 2>/dev/null | grep -qE "grep -q '\"version\"'" ; then
      _fail "BS-JQ-02: ga-bootstrap addon_installed still uses old grep -q '\"version\"' (matches the KEY, not the value)"
    else
      _pass "BS-JQ-02: ga-bootstrap addon_installed does not use the broken grep -q '\"version\"' pattern"
    fi
  fi
fi

# =========================================================================
# NB-INT-01: NetBird binary on rootfs embeds expected version
# =========================================================================
# Commit 11038a1ef. Build-side `verify_build_integrity` used to pipe netbird
# through `strings` before grep — strings can skip non-loadable ELF sections
# and silently miss the Go `-X version.version=` constant, causing a false
# FAIL that aborts the build. Fixed to `grep -qaF` (raw whole-file). This
# test additionally asserts the version IS embedded in the rootfs binary,
# so a regression to the broken pattern OR a missing version-injection
# surfaces here too.

NB_BIN="${TARGET}/usr/bin/netbird"
if [[ -x "$NB_BIN" ]]; then
  # Pull the expected NETBIRD_TAG from scripts/ga_build.sh and let bash
  # do parameter-expansion. ga_build.sh's line is the defensive form
  # `NETBIRD_TAG="${NETBIRD_TAG:-v0.66.2}"`, so awk-and-strip-quotes leaves
  # the literal `${...}` text in the buffer and grep then never matches.
  # Sourcing the line into a subshell gives us the real value regardless
  # of which of {literal, defensive-default, quoted, unquoted} form is used.
  NB_EXPECTED=""
  if [[ -n "${SRC:-}" && -f "${SRC}/scripts/ga_build.sh" ]]; then
    NB_EXPECTED=$(
      unset NETBIRD_TAG
      # shellcheck source=/dev/null
      eval "$(grep -E '^NETBIRD_TAG=' "${SRC}/scripts/ga_build.sh" | head -1)" 2>/dev/null
      printf '%s' "${NETBIRD_TAG#v}"
    )
  fi
  if [[ -n "$NB_EXPECTED" ]]; then
    if grep -qaF "$NB_EXPECTED" "$NB_BIN" 2>/dev/null; then
      _pass "NB-INT-01: NetBird rootfs binary embeds version $NB_EXPECTED (via grep -qaF, not strings)"
    else
      _fail "NB-INT-01: NetBird rootfs binary does NOT embed expected version $NB_EXPECTED"
    fi
  else
    _skip "NB-INT-01" "could not determine NETBIRD_TAG from scripts/ga_build.sh"
  fi
else
  _skip "NB-INT-01" "NetBird binary not present on rootfs (build incomplete?)"
fi

# NB-INT-02: scripts/ga_build.sh must NOT regress to `strings | grep` for
# the version check (the gotcha that caused the false-FAIL in commit 11038a1).
if [[ -n "${SRC:-}" && -f "${SRC}/scripts/ga_build.sh" ]]; then
  # Look in the verify_build_integrity function area for the BAD pattern.
  if grep -qE 'strings[[:space:]]+"\$nb"[[:space:]]*\|[[:space:]]*grep' "${SRC}/scripts/ga_build.sh"; then
    _fail "NB-INT-02: scripts/ga_build.sh regressed to 'strings | grep' for NetBird version (silently misses sections — re-fix per 11038a1ef)"
  else
    _pass "NB-INT-02: scripts/ga_build.sh uses grep -a directly for NetBird version (no strings-pipe regression)"
  fi
fi

# =========================================================================
# NB-REG-01..05: NetBird auto-register on first boot
# =========================================================================
# Source-of-truth + machinery for the OS-baked NetBird registration.
# Replaces ga-flasher-py stage 40 for the fleet-default registration path.
NB_REG_SCRIPT="${TARGET}/usr/libexec/ga-netbird-register"
NB_REG_UNIT="${TARGET}/usr/lib/systemd/system/ga-netbird-register.service"
NB_REG_KEY="${TARGET}/usr/share/ga-netbird/setup-key"

if [[ -x "$NB_REG_SCRIPT" ]]; then
  _pass "NB-REG-01: ga-netbird-register script present + executable"
else
  _fail "NB-REG-01: ga-netbird-register script missing or not executable at $NB_REG_SCRIPT"
fi

if [[ -f "$NB_REG_UNIT" ]]; then
  grep -q '^ConditionPathExists=/usr/share/ga-netbird/setup-key' "$NB_REG_UNIT" \
    && _pass "NB-REG-02: ga-netbird-register.service has ConditionPathExists guard (skips when no key baked)" \
    || _fail "NB-REG-02: ga-netbird-register.service missing ConditionPathExists guard"
  grep -qE '^Restart=on-failure' "$NB_REG_UNIT" \
    && _pass "NB-REG-03: ga-netbird-register.service has Restart=on-failure (handles slow-network first boot)" \
    || _fail "NB-REG-03: ga-netbird-register.service missing Restart=on-failure"
else
  _fail "NB-REG-02..03: ga-netbird-register.service unit not present at $NB_REG_UNIT"
fi

if [[ -L "${TARGET}/etc/systemd/system/multi-user.target.wants/ga-netbird-register.service" ]]; then
  _pass "NB-REG-04: ga-netbird-register.service enabled (multi-user.target.wants symlink)"
else
  _fail "NB-REG-04: ga-netbird-register.service NOT enabled (no multi-user.target.wants symlink)"
fi

# NB-REG-05: setup key file is present iff secret was provided at build.
# Build tolerates missing key (warn-only); on a build WITH the key, the
# file must exist + be 0600 + non-empty.
if [[ -f "$NB_REG_KEY" ]]; then
  PERMS=$(stat -c '%a' "$NB_REG_KEY" 2>/dev/null)
  SIZE=$(stat -c '%s' "$NB_REG_KEY" 2>/dev/null)
  if [[ "$PERMS" == "600" && "$SIZE" -gt 5 ]]; then
    _pass "NB-REG-05: setup-key file baked (mode 600, $SIZE bytes)"
  else
    _fail "NB-REG-05: setup-key baked but wrong perms ($PERMS) or empty ($SIZE bytes)"
  fi
else
  _skip "NB-REG-05" "no setup-key baked (secret missing at build time — fresh-flash devices won't auto-register)"
fi

# =========================================================================
# HA-INIT-01..06: ga-ha-init first-boot HA configuration
# =========================================================================
# DNS off / watchdog on / weather Met.no Berlin / timezone Europe/Berlin /
# write GA_ENV / set updater.json auto_update=false. Replaces fleet-wide
# parts of ga-flasher-py stage 69 + all of stage 92.
HA_INIT_SCRIPT="${TARGET}/usr/libexec/ga-ha-init"
HA_INIT_UNIT="${TARGET}/usr/lib/systemd/system/ga-ha-init.service"

if [[ -x "$HA_INIT_SCRIPT" ]]; then
  _pass "HA-INIT-01: ga-ha-init script present + executable"
else
  _fail "HA-INIT-01: ga-ha-init script missing or not executable at $HA_INIT_SCRIPT"
fi

# HA-INIT-02: script handles the fleet-wide settings it OWNS. Watchdog and
# weather/location were removed 2026-05-28 (watchdog → ga_manager converge
# step 8 since ga-ha-init runs before addons install; weather dropped — needs
# the owner account that doesn't exist at boot+85s). ga-ha-init now owns: DNS,
# timezone, auto_update.
if [[ -f "$HA_INIT_SCRIPT" ]]; then
  for needle in 'ha dns options' 'fallback=false' 'Europe/Berlin' 'auto_update'; do
    if grep -qF "$needle" "$HA_INIT_SCRIPT"; then
      _pass "HA-INIT-02: ga-ha-init touches '$needle'"
    else
      _fail "HA-INIT-02: ga-ha-init missing handling of '$needle'"
    fi
  done
fi

# HA-INIT-02b: timezone DUAL-CALL — script MUST call both the Supervisor
# API AND timedatectl. Either alone is insufficient:
#   - API alone: Supervisor accepts but doesn't propagate to systemd-timedated
#     for several minutes on fresh boot (info-API fields read null in that
#     window). Host stays UTC.
#   - timedatectl alone: Supervisor periodically re-syncs host tz from its
#     own in-memory state. If Supervisor's intent != Berlin, ~90s later
#     Supervisor reverts host to Luxembourg/UTC.
# Caught live KIB-SON-31 Build #5 reflash 2026-05-27.
if [[ -f "$HA_INIT_SCRIPT" ]]; then
  # Strip comments first so we only check executable code.
  HA_INIT_CODE=$(grep -vE '^[[:space:]]*#' "$HA_INIT_SCRIPT")
  if grep -qE 'supervisor options.*--timezone' <<<"$HA_INIT_CODE"; then
    _pass "HA-INIT-02b: tz uses 'ha supervisor options --timezone' (Supervisor intent)"
  else
    _fail "HA-INIT-02b: tz missing Supervisor API call — Supervisor would revert any timedatectl set"
  fi
  if grep -qE 'timedatectl set-timezone' <<<"$HA_INIT_CODE"; then
    _pass "HA-INIT-02b: tz uses 'timedatectl set-timezone' (host immediate)"
  else
    _fail "HA-INIT-02b: tz missing timedatectl call — host tz would stay UTC for several minutes"
  fi
fi

# HA-INIT-03: idempotency marker logic.
if [[ -f "$HA_INIT_SCRIPT" ]]; then
  grep -q 'ga-ha-init-applied' "$HA_INIT_SCRIPT" \
    && _pass "HA-INIT-03: ga-ha-init marker-guarded (idempotent across reboots)" \
    || _fail "HA-INIT-03: ga-ha-init missing marker guard — would re-run on every boot"
fi

# HA-INIT-04: unit ordering — after hassos-supervisor (we hit its API).
if [[ -f "$HA_INIT_UNIT" ]]; then
  grep -q 'After=hassos-supervisor.service' "$HA_INIT_UNIT" \
    && _pass "HA-INIT-04: ga-ha-init.service ordered After=hassos-supervisor.service" \
    || _fail "HA-INIT-04: ga-ha-init.service missing After=hassos-supervisor.service ordering"
fi

# HA-INIT-05: Restart=on-failure (handles slow first boot).
if [[ -f "$HA_INIT_UNIT" ]]; then
  grep -qE '^Restart=on-failure' "$HA_INIT_UNIT" \
    && _pass "HA-INIT-05: ga-ha-init.service has Restart=on-failure" \
    || _fail "HA-INIT-05: ga-ha-init.service missing Restart=on-failure"
fi

# HA-INIT-06: enabled at boot.
if [[ -L "${TARGET}/etc/systemd/system/multi-user.target.wants/ga-ha-init.service" ]]; then
  _pass "HA-INIT-06: ga-ha-init.service enabled (multi-user.target.wants symlink)"
else
  _fail "HA-INIT-06: ga-ha-init.service NOT enabled"
fi

# HA-INIT-07..09: late tz re-apply timer (beats Supervisor host.control
# revert at boot+~120s). ga-ha-init can't fork a sleeper — it's Type=oneshot
# KillMode=control-group, so a child dies when the main script exits.
# A dedicated timer in its own cgroup is the fix.
TZ_REAPPLY_SCRIPT="${TARGET}/usr/libexec/ga-ha-init-tz-reapply"
TZ_REAPPLY_SVC="${TARGET}/usr/lib/systemd/system/ga-ha-init-tz-reapply.service"
TZ_REAPPLY_TIMER="${TARGET}/usr/lib/systemd/system/ga-ha-init-tz-reapply.timer"

if [[ -x "$TZ_REAPPLY_SCRIPT" ]]; then
  _pass "HA-INIT-07: ga-ha-init-tz-reapply script present + executable"
else
  _fail "HA-INIT-07: ga-ha-init-tz-reapply script missing or not executable"
fi

# HA-INIT-08: timer fires AFTER Supervisor's host-sync (boot+~120s). We need
# OnBootSec strictly greater than that; assert >= 180s to be safe.
if [[ -f "$TZ_REAPPLY_TIMER" ]]; then
  ob=$(grep -oE 'OnBootSec=[0-9]+' "$TZ_REAPPLY_TIMER" | grep -oE '[0-9]+' | head -1)
  if [[ -n "$ob" && "$ob" -ge 180 ]]; then
    _pass "HA-INIT-08: tz-reapply timer OnBootSec=${ob}s (>=180s, past Supervisor host-sync)"
  else
    _fail "HA-INIT-08: tz-reapply timer OnBootSec=${ob:-unset} too early — Supervisor reverts at ~120s"
  fi
else
  _fail "HA-INIT-08: ga-ha-init-tz-reapply.timer unit missing"
fi

# HA-INIT-09: timer enabled at boot (timers.target.wants symlink) + service present.
if [[ -L "${TARGET}/etc/systemd/system/timers.target.wants/ga-ha-init-tz-reapply.timer" \
      && -f "$TZ_REAPPLY_SVC" ]]; then
  _pass "HA-INIT-09: tz-reapply timer enabled (timers.target.wants symlink) + service present"
else
  _fail "HA-INIT-09: tz-reapply timer NOT enabled or service unit missing"
fi

# =========================================================================
# EMMC-ERASE-01..05: eMMC first-boot wipe (= ga-flasher-py stage 35).
# Owned by ga-bootstrap-disk (NOT a separate ga-emmc-erase unit — that was
# deleted 2026-05-28 as a redundant duplicate; ga-bootstrap-disk does the
# wipe ~1s earlier with 3 guards vs the duplicate's 1). GAOS-05/06 cover the
# unit's existence+enablement; these tests cover the erase LOGIC, which had
# no build-test before (closing the WP-B gap).
# =========================================================================
EMMC_SCRIPT="${TARGET}/usr/libexec/ga-bootstrap-disk"

if [[ -x "$EMMC_SCRIPT" ]]; then
  _pass "EMMC-ERASE-01: ga-bootstrap-disk script present + executable"
else
  _fail "EMMC-ERASE-01: ga-bootstrap-disk script missing or not executable"
fi

# EMMC-ERASE-02: all THREE fail-closed guards present (the whole safety model).
#   A: iHost device-tree compatible   B: mmcblk0boot0 (proves eMMC, not SD)
#   C: root must be on mmcblk2 (SD) — never wipe the running system.
if [[ -f "$EMMC_SCRIPT" ]]; then
  _g=0
  grep -q 'itead,sonoff-ihost' "$EMMC_SCRIPT" && _g=$((_g+1))
  grep -q 'mmcblk0boot0' "$EMMC_SCRIPT" && _g=$((_g+1))
  grep -q 'mmcblk2' "$EMMC_SCRIPT" && _g=$((_g+1))
  if [[ "$_g" -eq 3 ]]; then
    _pass "EMMC-ERASE-02: ga-bootstrap-disk has all 3 erase guards (iHost + boot0 + root-on-SD)"
  else
    _fail "EMMC-ERASE-02: ga-bootstrap-disk missing erase guard(s) (found ${_g}/3) — could brick a device!"
  fi
fi

# EMMC-ERASE-03: idempotency marker (one wipe per device, ever).
if [[ -f "$EMMC_SCRIPT" ]]; then
  grep -q '.ga_emmc_erased' "$EMMC_SCRIPT" \
    && _pass "EMMC-ERASE-03: ga-bootstrap-disk marker-guarded (.ga_emmc_erased, one-shot)" \
    || _fail "EMMC-ERASE-03: ga-bootstrap-disk missing marker — would re-erase every boot"
fi

# EMMC-ERASE-04: wipe method — blkdiscard (fast TRIM) with a dd zero-fill fallback.
if [[ -f "$EMMC_SCRIPT" ]]; then
  if grep -q 'blkdiscard' "$EMMC_SCRIPT" && grep -qE 'dd if=/dev/zero' "$EMMC_SCRIPT"; then
    _pass "EMMC-ERASE-04: ga-bootstrap-disk wipes via blkdiscard + dd zero-fill fallback"
  else
    _fail "EMMC-ERASE-04: ga-bootstrap-disk missing blkdiscard or dd zero-fill fallback"
  fi
fi

# EMMC-ERASE-05: runs early, before Supervisor (sysinit.target.wants).
if [[ -L "${TARGET}/etc/systemd/system/sysinit.target.wants/ga-bootstrap-disk.service" ]]; then
  _pass "EMMC-ERASE-05: ga-bootstrap-disk.service enabled early (sysinit.target.wants symlink)"
else
  _fail "EMMC-ERASE-05: ga-bootstrap-disk.service NOT enabled in sysinit.target.wants"
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
