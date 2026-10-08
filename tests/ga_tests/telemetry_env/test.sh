#!/bin/sh
# Telemetry env label from the FLEET env (Odoo #1191).
#
# Host-side suite: drives the REAL /usr/libexec/ga-telemetry-env resolver and
# the REAL env builders (ga-fluent-bit-env, ga-telegraf-env) with their device
# paths moved into a temp dir. Nothing inside the scripts is replaced. The seam
# under test is what lands in the env files fluent-bit and telegraf are started
# with: GA_ENV there IS the `env` / `ga_env` label on every Loki stream and the
# `env` tag on every telegraf point.
#
#   TENV-01  GA_FLEET_ENV absent           -> prod, and the journal line says why (ADR-0027 D4)
#   TENV-02  override GA_FLEET_ENV=staging -> staging
#   TENV-03  invalid value                  -> unknown + WARNING (never prod)
#   TENV-04  no config readable at all      -> unknown + WARNING (never prod)
#   TENV-05  bridge fleet_env disagrees     -> WARNING, config value wins
#   TENV-06  resolver == ga-enroll's fleet_env for the same config (absent, staging)
#   TENV-10  fluent-bit env file on a staging device: GA_ENV=staging (+ GA_TELEMETRY_ENV)
#   TENV-11  fluent-bit env file on a prod device: GA_ENV=prod
#   TENV-12  fluent-bit env, resolver missing -> GA_ENV=unknown + WARNING
#   TENV-13  fluent-bit publishes the label to the /share bridge (ga_manager telemetry.env_label)
#   TENV-14  a baked GA_ENV=prod in ga-env.conf does not reach the label any more
#   TENV-20  telegraf env file on a staging device: GA_ENV=staging
#   TENV-21  telegraf env, resolver missing -> GA_ENV=unknown
#   TENV-30  unit fallbacks are GA_ENV=unknown in all three units (never dev, never prod)
#   TENV-31  tier-1 Loki labels and the telegraf tag read GA_ENV (the seam to the label)
#
# Needs sh, jq, coreutils. No device.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Telemetry env label from the fleet env (#1191)"

R="$SCRIPT_DIR/../../.."
TENV="$R/buildroot-external/rootfs-overlay/usr/libexec/ga-telemetry-env"
FBENV="$R/buildroot-external/package/fluent-bit-config/ga-fluent-bit-env"
TGENV="$R/buildroot-external/package/telegraf/ga-telegraf-env"
ENROLL="$R/buildroot-external/rootfs-overlay/usr/libexec/ga-enroll"
PUB="$R/buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish"
BAKED_CONF="$R/buildroot-external/rootfs-overlay/etc/ga-services.conf"

run_test "TENV-00" "resolver, both env builders, ga-enroll, publish helper and baked conf present" \
  "test -x '$TENV' && test -f '$FBENV' && test -f '$TGENV' && test -x '$ENROLL' && test -x '$PUB' && test -f '$BAKED_CONF'"
command -v jq >/dev/null 2>&1 || { echo "jq missing — cannot run"; suite_end; exit 2; }

W="$(mktemp -d 2>/dev/null || echo /tmp/telemetry_env_$$)"
mkdir -p "$W/bin" "$W/share" "$W/stage"
printf 'GA_FLEET_HOST=fleet.greenautarky.com\nGA_FLEET_PORT=8091\nGA_FLEET_ENV=staging\n' > "$W/ovr-staging.conf"
printf 'GA_FLEET_ENV=prd\n' > "$W/ovr-invalid.conf"

tenv() { # tenv <override> <name> [enroll-state]
  GA_TENV_NO_LOGGER=1 GA_TENV_CONF_DEFAULT="${TENV_DEFAULT:-$BAKED_CONF}" \
  GA_TENV_CONF_OVERRIDE="${1:-$W/no-override}" GA_TENV_ENROLL_STATE="${3:-$W/no-state}" \
  sh "$TENV" > "$W/$2.out" 2> "$W/$2.err"
}

tenv "" absent
run_test "TENV-01" "GA_FLEET_ENV absent → prod, and the journal line names ADR-0027 D4" \
  "[ \"\$(cat '$W/absent.out')\" = prod ] && grep -q 'ADR-0027 D4' '$W/absent.err'"

tenv "$W/ovr-staging.conf" staging
run_test "TENV-02" "override GA_FLEET_ENV=staging → staging" \
  "[ \"\$(cat '$W/staging.out')\" = staging ]"

tenv "$W/ovr-invalid.conf" invalid
run_test "TENV-03" "invalid GA_FLEET_ENV → unknown + WARNING (never prod)" \
  "[ \"\$(cat '$W/invalid.out')\" = unknown ] && grep -q 'WARNING' '$W/invalid.err'"

TENV_DEFAULT="$W/no-baked" tenv "" none
run_test "TENV-04" "no config readable → unknown + WARNING (never prod)" \
  "[ \"\$(cat '$W/none.out')\" = unknown ] && grep -q 'WARNING' '$W/none.err'"

printf '{"fleet_env":"prod","ga_env":"prod"}\n' > "$W/state-prod.json"
tenv "$W/ovr-staging.conf" stale "$W/state-prod.json"
run_test "TENV-05" "bridge fleet_env=prod, config staging → WARNING, label staging" \
  "[ \"\$(cat '$W/stale.out')\" = staging ] && grep -q 'stale' '$W/stale.err'"

# --- TENV-06: same answer as ga-enroll, for the same config -----------------
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
prev=""; payload=""
for a in "$@"; do [ "$prev" = "-d" ] && payload="$a"; prev="$a"; done
printf '%s\n' "$payload" >> "${CURL_LOG}"
printf '{"status":"pending","provisional_id":"kibu-test","enroll_count":1}'
STUB
chmod +x "$W/bin/curl"
enroll_env() { # enroll_env <override> <name> -> prints fleet_env ga-enroll sent
  : > "$W/$2.payload"
  CURL_LOG="$W/$2.payload" PATH="$W/bin:$PATH" \
  GA_ENROLL_CONF_DEFAULT="$BAKED_CONF" GA_ENROLL_CONF_OVERRIDE="${1:-$W/no-override}" \
  GA_ENROLL_CREDS_FILE="$W/ghcr-creds.json" GA_ENROLL_STATE_FILE="$W/share/ga-enroll-state.json" \
  GA_ENROLL_NB_ENV="$W/no-nb-env" GA_ENROLL_HA_UUID_STORE="$W/no-uuid" \
  GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$W/stage" \
  GA_ENROLL_SSH_POSTURE="$W/no-posture" GA_ENROLL_SSH_HOST_PUB="$W/no-host-pub" \
  sh "$ENROLL" > "$W/$2.enroll.out" 2>&1
  jq -r .fleet_env "$W/$2.payload" 2>/dev/null | head -1
}
run_test "TENV-06" "resolver and ga-enroll agree: absent → both prod, staging → both staging" \
  "[ \"\$(enroll_env '' e-absent)\" = \"\$(cat '$W/absent.out')\" ] && [ \"\$(enroll_env '$W/ovr-staging.conf' e-staging)\" = \"\$(cat '$W/staging.out')\" ]"

# --- the env builders ---------------------------------------------------------
# Wrapper so the builders call the real resolver with the fixture config.
mk_resolver() { # mk_resolver <override> <path>
  cat > "$2" <<EOF
#!/bin/sh
GA_TENV_NO_LOGGER=1 GA_TENV_CONF_DEFAULT='$BAKED_CONF' GA_TENV_CONF_OVERRIDE='${1:-$W/no-override}' GA_TENV_ENROLL_STATE='$W/no-state' exec sh '$TENV'
EOF
  chmod +x "$2"
}
mk_resolver "$W/ovr-staging.conf" "$W/bin/tenv-staging"
mk_resolver "" "$W/bin/tenv-prod"

fb() { # fb <resolver> <name>
  mkdir -p "$W/$2/fb"
  GA_FLUENT_BIT_DIR="$W/$2/fb" GA_TELEMETRY_ENV_BIN="$1" \
  GA_TELEMETRY_ENV_BRIDGE="$W/share/ga-telemetry-env.json" \
  GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$W/stage" \
  sh "$FBENV" > "$W/$2.fb.out" 2>&1
}
fb "$W/bin/tenv-staging" fbs
run_test "TENV-10" "fluent-bit env on a staging device: GA_ENV=staging and GA_TELEMETRY_ENV=staging" \
  "grep -qx 'GA_ENV=staging' '$W/fbs/fb/env' && grep -qx 'GA_TELEMETRY_ENV=staging' '$W/fbs/fb/env'"
run_test "TENV-13" "the label is published to the /share bridge for ga_manager" \
  "[ \"\$(jq -r .telemetry_env '$W/share/ga-telemetry-env.json')\" = staging ]"

fb "$W/bin/tenv-prod" fbp
run_test "TENV-11" "fluent-bit env on a prod device: GA_ENV=prod" \
  "grep -qx 'GA_ENV=prod' '$W/fbp/fb/env'"

fb "$W/no-such-resolver" fbm
run_test "TENV-12" "fluent-bit env, resolver missing → GA_ENV=unknown + WARNING" \
  "grep -qx 'GA_ENV=unknown' '$W/fbm/fb/env' && grep -q 'WARNING' '$W/fbm.fb.out'"

run_test "TENV-14" "neither env builder reads GA_ENV from ga-env.conf any more" \
  "! grep -qE '^[^#]*ga-env\\.conf' '$FBENV' && ! grep -qE '^[^#]*ga-env\\.conf' '$TGENV'"

tg() { # tg <resolver> <name>
  mkdir -p "$W/$2/tg"
  GA_TELEGRAF_DIR="$W/$2/tg" GA_TELEMETRY_ENV_BIN="$1" sh "$TGENV" > "$W/$2.tg.out" 2>&1
}
tg "$W/bin/tenv-staging" tgs
run_test "TENV-20" "telegraf env on a staging device: GA_ENV=staging" \
  "grep -qx 'GA_ENV=staging' '$W/tgs/tg/env'"
tg "$W/no-such-resolver" tgm
run_test "TENV-21" "telegraf env, resolver missing → GA_ENV=unknown + WARNING" \
  "grep -qx 'GA_ENV=unknown' '$W/tgm/tg/env' && grep -q 'WARNING' '$W/tgm.tg.out'"

# --- static seams -------------------------------------------------------------
U1="$R/buildroot-external/package/fluent-bit-config/fluent-bit.service"
U0="$R/buildroot-ihost/rootfs-overlay/etc/systemd/system/fluent-bit-tier0.service"
U2="$R/buildroot-external/package/telegraf/telegraf.service"
run_test "TENV-30" "unit fallbacks say GA_ENV=unknown in all three units" \
  "grep -q '^Environment=GA_ENV=unknown ' '$U1' && grep -q '^Environment=GA_ENV=unknown ' '$U0' && grep -q '^Environment=GA_ENV=unknown ' '$U2' && ! grep -qE '^Environment=.*GA_ENV=(dev|prod)' '$U1' '$U0' '$U2'"
run_test "TENV-31" "tier-1 Loki labels carry env=\${GA_ENV}; telegraf tags env from \${GA_ENV}" \
  "grep -E '^[[:space:]]*labels' '$R/buildroot-external/package/fluent-bit-config/fluent-bit.conf' | grep -q 'env=\${GA_ENV}' && grep -qE '^[[:space:]]*env = \"\\\$\\{GA_ENV\\}\"' '$R/buildroot-external/package/telegraf/telegraf.conf'"

rm -rf "$W" 2>/dev/null
suite_end
