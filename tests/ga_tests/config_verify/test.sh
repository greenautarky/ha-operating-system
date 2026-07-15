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

# --- Fluent-Bit per-device Loki identity wiring (ADR-0003 Step 3) ---
# The OUTPUT must take endpoint + auth + tenant from the env, and the unit must
# provide anonymous-compatible defaults + the addon-data sidecar read, so a
# device WITHOUT a delivered cred behaves exactly like the pre-Step-3 build.
run_test "CFG-36" "fluent-bit.conf Loki OUTPUT http_user from env" \
  "grep -q 'http_user.*LOKI_USER' /etc/fluent-bit/fluent-bit.conf"

run_test "CFG-37" "fluent-bit.conf Loki OUTPUT tenant_id from env" \
  "grep -q 'tenant_id.*LOKI_TENANT' /etc/fluent-bit/fluent-bit.conf"

run_test "CFG-38" "fluent-bit.conf Loki OUTPUT host/port from env" \
  "grep -q 'Host.*LOKI_HOST' /etc/fluent-bit/fluent-bit.conf && grep -q 'Port.*LOKI_PORT' /etc/fluent-bit/fluent-bit.conf"

run_test "CFG-39" "fluent-bit.service has anonymous-safe LOKI defaults" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q 'Environment=.*LOKI_USER=anonymous'"

run_test "CFG-40" "fluent-bit.service reads loki cred sidecar via addon-data glob" \
  "systemctl cat fluent-bit 2>/dev/null | grep -q '_ga_manager/ga-fleet-loki.yaml'"

# If a cred was delivered, the built env must carry the parsed values (a device
# without the sidecar legitimately runs on defaults — skip, don't fail).
if ls /mnt/data/supervisor/addons/data/*_ga_manager/ga-fleet-loki.yaml >/dev/null 2>&1; then
  run_test "CFG-41" "fluent-bit env has per-device LOKI_USER (cred delivered)" \
    "grep -q '^LOKI_USER=dev_' /mnt/data/fluent-bit/env"
else
  skip_test "CFG-41" "fluent-bit env has per-device LOKI_USER (no loki sidecar delivered)"
fi

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

# --- ga-enroll bridge carries ga_release (Odoo #513 release-verify gate) ---
run_test "CFG-47" "ga-enroll writes ga_release into the enroll-state bridge" \
  "grep -q 'ga_release:\$rel' /usr/libexec/ga-enroll"

# --- systemd ${braced} trap, fleet-wide (CFG-48) ------------------------------
# systemd expands PLAIN ${VAR} in Exec* lines ITSELF, before /bin/sh sees them.
# It does NOT touch shell-default forms (${VAR:-x}) — which is exactly why this
# hid for weeks: DEVICE_LABEL=${LABEL:-unknown} worked while INFLUX_USER=${U}
# silently became empty and 401'd every write (2026-07-13), same class as the
# empty LOKI_* that took tier-0 down fleet-wide (2026-07-10).
# Rule: no plain ${VAR} in any Exec* line of any GA unit — build the env in a
# script under /usr/libexec instead.
run_test "CFG-48" "no plain \${VAR} in Exec* lines of any GA unit (systemd eats them)" \
  '! grep -hE "^Exec[A-Za-z]*=" /etc/systemd/system/*.service /usr/lib/systemd/system/ga-*.service 2>/dev/null \
     | grep -E "\$\{[A-Za-z_][A-Za-z0-9_]*\}"'

run_test "CFG-49" "telegraf builds its env via /usr/libexec/ga-telegraf-env" \
  "test -x /usr/libexec/ga-telegraf-env && systemctl cat telegraf 2>/dev/null | grep -q 'ExecStartPre=/usr/libexec/ga-telegraf-env'"

if [ -f /mnt/data/supervisor/share/ga-fleet-influx.yaml ]; then
  run_test "CFG-50" "telegraf env has a NON-EMPTY per-device INFLUX_USER (cred delivered)" \
    "grep -qE '^INFLUX_USER=dev_KIB-SON-[0-9]+' /mnt/data/telegraf/env"
else
  skip_test "CFG-50" "telegraf env per-device INFLUX_USER (no influx cred delivered yet)"
fi

run_test "CFG-51" "ga-enroll writes ga_env into the enroll-state bridge (addon-visible env source)" \
  "grep -q 'ga_env:\$env' /usr/libexec/ga-enroll"

# --- DEVICE_LABEL single-source-of-truth fallback (CFG-52) --------------------
# Both host env-builders read the legacy /mnt/data/ga-device-label (flasher
# stage 72b) and must fall back to the canonical ga-identity.json device_id when
# it is absent — else a device with an identity blob but no label file ships
# device_label=unknown forever (7 prod devices, 2026-07-15). Keeps logs+metrics
# on the same label. See #528.
run_test "CFG-52" "fluent-bit + telegraf env-builders fall back to ga-identity.json for DEVICE_LABEL" \
  "grep -q 'ga-identity.json' /usr/libexec/ga-fluent-bit-env && grep -q 'ga-identity.json' /usr/libexec/ga-telegraf-env"

suite_end
