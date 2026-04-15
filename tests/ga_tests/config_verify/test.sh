#!/bin/sh
# Config deployment verification - runs ON the device
# Verifies critical configs were correctly deployed to rootfs with expected content.
# Catches stale configs from failed builds or incomplete RAUC OTA updates.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Config Verify"

# --- Telegraf config ---
run_test "CFG-01" "telegraf.conf exists on rootfs" \
  "test -f /etc/telegraf/telegraf.conf"

run_test "CFG-02" "telegraf.conf has device_label tag" \
  "grep -q 'device_label' /etc/telegraf/telegraf.conf"

run_test "CFG-03" "telegraf.conf has uuid tag" \
  "grep -q 'uuid.*DEVICE_UUID' /etc/telegraf/telegraf.conf"

# --- Telegraf service ---
run_test "CFG-04" "telegraf.service has DEVICE_LABEL ExecStartPre" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'ga-device-label'"

run_test "CFG-05" "telegraf.service has DEVICE_UUID ExecStartPre" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'core.uuid'"

run_test "CFG-06" "telegraf.service has DEVICE_LABEL safe default" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'Environment=.*DEVICE_LABEL=unknown'"

# --- Fluent-Bit config ---
run_test "CFG-07" "fluent-bit.conf exists on rootfs" \
  "test -f /etc/fluent-bit/fluent-bit.conf"

run_test "CFG-08" "fluent-bit.conf has device_label in filter" \
  "grep -q 'device_label' /etc/fluent-bit/fluent-bit.conf"

run_test "CFG-09" "fluent-bit.conf has device_label in Loki labels" \
  "grep 'labels.*job=ihost' /etc/fluent-bit/fluent-bit.conf | grep -q 'device_label'"

# --- Fluent-Bit service ---
run_test "CFG-10" "fluent-bit.service has DEVICE_LABEL ExecStartPre" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q 'ga-device-label'"

run_test "CFG-11" "fluent-bit.service has DEVICE_LABEL safe default" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q 'Environment=.*DEVICE_LABEL=unknown'"

# --- DNS & service ordering ---
run_test "CFG-13" "/etc/hosts has greenautarky fallback entry" \
  "grep -q 'influx.greenautarky.com' /etc/hosts"

run_test "CFG-14" "/etc/hosts has loki fallback entry" \
  "grep -q 'loki.greenautarky.com' /etc/hosts"

run_test "CFG-15" "telegraf.service ordered after netbird" \
  "systemctl cat telegraf 2>/dev/null | grep -q 'After=.*netbird.service'"

run_test "CFG-16" "fluent-bit.service ordered after netbird" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q 'After=.*netbird.service'"

run_test "CFG-17" "influx.greenautarky.com resolves (hosts or DNS)" \
  "grep -q 'influx.greenautarky.com' /etc/hosts || nslookup influx.greenautarky.com >/dev/null 2>&1"

run_test "CFG-18" "loki.greenautarky.com resolves (hosts or DNS)" \
  "grep -q 'loki.greenautarky.com' /etc/hosts || nslookup loki.greenautarky.com >/dev/null 2>&1"

# --- Fluent-Bit parsers & storage ---
run_test "CFG-19" "parsers.conf exists on rootfs" \
  "test -f /etc/fluent-bit/parsers.conf"

run_test "CFG-20" "parsers.conf has homeassistant parser" \
  "grep -q 'Name.*homeassistant' /etc/fluent-bit/parsers.conf"

run_test "CFG-21" "fluent-bit.conf tail inputs use homeassistant parser" \
  "grep -A2 'Tag.*ihost.hass' /etc/fluent-bit/fluent-bit.conf | grep -q 'Parser.*homeassistant'"

run_test "CFG-22" "fluent-bit.conf storage buffer >= 300M" \
  "grep 'storage.total_limit_size' /etc/fluent-bit/fluent-bit.conf | grep -v '^#' | grep -qE '[3-9][0-9]{2}M|[0-9]{4,}M'"

# --- Device label file ---
if [ -f /mnt/data/ga-device-label ]; then
  run_test_show "CFG-12" "ga-device-label file has valid content" \
    "cat /mnt/data/ga-device-label"
else
  # No label file — verify fallback works (env should show "unknown")
  run_test "CFG-12" "ga-device-label fallback (no label file, env=unknown)" \
    "grep -q 'DEVICE_LABEL=unknown' /mnt/data/telegraf/env 2>/dev/null"
fi

# CFG-31: WiFi power save disabled (can be in main conf or conf.d/)
run_test "CFG-31" "WiFi power save disabled via NM config" \
  "grep -rq 'wifi.powersave.*=.*2' /etc/NetworkManager/ 2>/dev/null"

# --- HA reverse proxy config (trusted proxies + external URL) ---
# These are set by ga-flasher stage 69 step 3c during provisioning.
# On non-provisioned devices (fresh flash, no flasher run), these will fail — that's expected.

HA_CFG="/mnt/data/supervisor/homeassistant/configuration.yaml"
if [ -f "$HA_CFG" ]; then
  run_test "CFG-32" "HA use_x_forwarded_for enabled" \
    "grep -q 'use_x_forwarded_for.*true' $HA_CFG"

  # Read expected IP from ga-services.conf
  GA_IP=$(grep '^GA_SERVICES_IP=' /mnt/data/ga-services.conf 2>/dev/null \
       || grep '^GA_SERVICES_IP=' /etc/ga-services.conf 2>/dev/null)
  GA_IP="${GA_IP#GA_SERVICES_IP=}"

  run_test "CFG-33" "HA trusted_proxies has 127.0.0.1 (Tailscale Funnel)" \
    "grep -A10 'trusted_proxies' $HA_CFG | grep -q '127.0.0.1'"

  if [ -n "$GA_IP" ]; then
    run_test "CFG-34" "HA trusted_proxies has GA_SERVICES_IP ($GA_IP)" \
      "grep -A10 'trusted_proxies' $HA_CFG | grep -q '$GA_IP'"
  else
    skip_test "CFG-34" "HA trusted_proxies has GA_SERVICES_IP (no ga-services.conf)"
  fi

  run_test "CFG-35" "HA external_url set to ki-butler domain" \
    "grep -q 'ki-butler.greenautarky.com' $HA_CFG"
else
  skip_test "CFG-32" "HA use_x_forwarded_for enabled (no configuration.yaml)"
  skip_test "CFG-33" "HA trusted_proxies has 127.0.0.1 (no configuration.yaml)"
  skip_test "CFG-34" "HA trusted_proxies has GA_SERVICES_IP (no configuration.yaml)"
  skip_test "CFG-35" "HA external_url set to ki-butler domain (no configuration.yaml)"
fi

suite_end
