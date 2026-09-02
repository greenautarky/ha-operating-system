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
# CFG-04/05 assert the WIRING, not the spelling. The label and uuid lookups used
# to sit inline in the unit; they were deliberately moved into ga-telegraf-env
# because systemd expands a plain ${VAR} in Exec* lines itself, which silently
# emptied INFLUX_USER/INFLUX_PASSWORD and 401'd every write. Grepping the unit
# for 'ga-device-label' therefore tested the pre-refactor form and failed on a
# correct device — a test red for the wrong reason, which is how a suite gets
# ignored. Assert instead that the unit calls the helper AND the helper resolves
# both values, which is the property that has to hold either way.
run_test "CFG-04" "telegraf.service runs the env helper that resolves DEVICE_LABEL" \
  "systemctl cat telegraf 2>/dev/null | grep -qE 'ExecStartPre=.*ga-telegraf-env' && grep -q 'device_id\\|ga-device-label' /usr/libexec/ga-telegraf-env"

run_test "CFG-05" "telegraf env helper resolves DEVICE_UUID from core.uuid" \
  "grep -q 'core.uuid' /usr/libexec/ga-telegraf-env"

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
# Same refactor, same correction as CFG-04.
run_test "CFG-10" "fluent-bit.service runs the env helper that resolves DEVICE_LABEL" \
  "systemctl cat fluent-bit 2>/dev/null | grep -qE 'ExecStartPre=.*ga-fluent-bit-env' && grep -q 'device_id\\|ga-device-label' /usr/libexec/ga-fluent-bit-env"

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

# The sidecar is read by the env-builder the unit runs in ExecStartPre
# (ga-fluent-bit-env CRED_GLOB), not named in the unit file itself — the old
# assertion grepped the wrong file and was red on a correct device.
run_test "CFG-40" "fluent-bit env-builder reads the loki cred sidecar via the addon-data glob" \
  "systemctl cat fluent-bit-tier0 2>/dev/null | grep -q 'ExecStartPre=/usr/libexec/ga-fluent-bit-env' && grep -q '_ga_manager/ga-fleet-loki.yaml' /usr/libexec/ga-fluent-bit-env"

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
  # No label file. This is the NORMAL case on a self-provisioned device: the
  # flasher stage that wrote /mnt/data/ga-device-label was retired, so the
  # env-builder must derive the label from ga-identity.json instead.
  #
  # "unknown" is therefore the FAILURE state, not the pass state. Asserting
  # DEVICE_LABEL=unknown here (as this branch used to) went RED on a healthy
  # device and GREEN on a broken one — it masked exactly the regression where a
  # shipper starts before the identity lands and nothing bounces it (measured
  # K31 rc18, 2026-09-02). Subject is fluent-bit's env: tier-0 is the always-on
  # shipper, whereas telegraf is tier-2 opt-in and may not exist at all.
  if ls /mnt/data/supervisor/addons/data/*_ga_manager/ga-identity.json >/dev/null 2>&1; then
    run_test_show "CFG-12" "DEVICE_LABEL derived from identity (no label file)" \
      "grep -q '^DEVICE_LABEL=KIB-SON-' /mnt/data/fluent-bit/env"
  else
    skip_test "CFG-12" "no label file and no identity on disk yet — nothing to derive from"
  fi
fi

# CFG-31: WiFi power save disabled (can be in main conf or conf.d/)
run_test "CFG-31" "WiFi power save disabled via NM config" \
  "grep -rq 'wifi.powersave.*=.*2' /etc/NetworkManager/ 2>/dev/null"

# --- HA reverse proxy config (trusted proxies + external URL) ---
# These are set by ga-flasher stage 69 step 3c during provisioning.
# On non-provisioned devices (fresh flash, no flasher run), these will fail — that's expected.

HA_CFG="/mnt/data/supervisor/homeassistant/configuration.yaml"
# converge writes its managed HA entries into ga_packages/*.yaml (pulled in by
# `packages: !include_dir_named ga_packages`), not into configuration.yaml
# itself. Assert on what Core loads: the main file plus the packages dir.
HA_CFG_ALL="$HA_CFG /mnt/data/supervisor/homeassistant/ga_packages/*.yaml"
if [ -f "$HA_CFG" ]; then
  run_test "CFG-32" "HA use_x_forwarded_for enabled (configuration.yaml or ga_packages/)" \
    "cat $HA_CFG_ALL 2>/dev/null | grep -q 'use_x_forwarded_for.*true'"

  # Read expected IP from ga-services.conf
  GA_IP=$(grep '^GA_SERVICES_IP=' /mnt/data/ga-services.conf 2>/dev/null \
       || grep '^GA_SERVICES_IP=' /etc/ga-services.conf 2>/dev/null)
  GA_IP="${GA_IP#GA_SERVICES_IP=}"

  run_test "CFG-33" "HA trusted_proxies has 127.0.0.1 (Tailscale Funnel)" \
    "cat $HA_CFG_ALL 2>/dev/null | grep -A10 'trusted_proxies' | grep -q '127.0.0.1'"

  if [ -n "$GA_IP" ]; then
    run_test "CFG-34" "HA trusted_proxies has GA_SERVICES_IP ($GA_IP)" \
      "cat $HA_CFG_ALL 2>/dev/null | grep -A10 'trusted_proxies' | grep -q '$GA_IP'"
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


# Tier-1 (error logs) and tier-2 (metrics) shippers are consent-gated by design:
# telegraf has ConditionPathExists=/mnt/data/.ga-consent-metrics, fluent-bit
# (tier-1) has ConditionPathExists=/mnt/data/.ga-consent-error_logs. Without the
# marker the unit is inactive on purpose and its env file does not exist. Tests
# that assert on them must SKIP with the reason, not FAIL — on a fresh device
# without consent they were 12 structural reds (2026-09-02, K31 rc19).
_consent_metrics()    { [ -f /mnt/data/.ga-consent-metrics ]; }
_consent_error_logs() { [ -f /mnt/data/.ga-consent-error_logs ]; }
if [ -f /mnt/data/supervisor/share/ga-fleet-influx.yaml ] && ! _consent_metrics; then
  skip_test "CFG-50" "telegraf env per-device INFLUX_USER (tier-2 metrics consent not given — env does not exist)"
elif [ -f /mnt/data/supervisor/share/ga-fleet-influx.yaml ]; then
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
