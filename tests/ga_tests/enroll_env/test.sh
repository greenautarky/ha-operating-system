#!/bin/sh
# ga-enroll — the device declares its fleet environment (ADR-0027 D4).
#
# Host-side suite: drives the REAL /usr/libexec/ga-enroll script with every
# device path moved into a temp dir (GA_ENROLL_* hooks) and a stub `curl` on
# PATH that records the payload it was asked to POST and answers like the
# fleet-manager. Nothing is mocked INSIDE the script — the seam under test is
# the payload the device sends and the state file it publishes.
#
#   ENV-FE-01  absent GA_FLEET_ENV → payload says fleet_env=prod   (absent means production)
#   ENV-FE-02  override GA_FLEET_ENV=staging → fleet_env=staging   (the runbook's seed)
#   ENV-FE-03  the bridge state file carries fleet_env too
#   ENV-FE-04  a value that is neither prod nor staging → exit 1, NO request made
#   ENV-FE-05  …and the error names the override file
#   ENV-FE-06  the baked default file does not set GA_FLEET_ENV (absent = prod, by construction)
#
# Needs sh, jq, coreutils. No device.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "ga-enroll fleet_env (ADR-0027)"

ENROLL="/usr/libexec/ga-enroll"
[ -x "$ENROLL" ] || ENROLL="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/ga-enroll"
BAKED_CONF="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/etc/ga-services.conf"
PUB="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/ga-share-publish"

run_test "ENV-FE-00" "script + baked conf + publish helper present" \
  "test -x '$ENROLL' && test -f '$BAKED_CONF' && test -x '$PUB'"
command -v jq >/dev/null 2>&1 || { echo "jq missing — cannot run"; suite_end; exit 2; }

W="$(mktemp -d 2>/dev/null || echo /tmp/enroll_env_$$)"
mkdir -p "$W/bin" "$W/share" "$W/stage"

# stub curl: record the payload, answer like the fleet-manager
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
# record the -d payload (last arg after -d) and the URL
prev=""; payload=""; url=""
for a in "$@"; do
  [ "$prev" = "-d" ] && payload="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
printf '%s\n' "$payload" >> "${CURL_LOG}"
printf '%s\n' "$url" >> "${CURL_LOG}.url"
printf '{"status":"pending","provisional_id":"kibu-test","enroll_count":1,"registries":{"ghcr.io":{"username":"u","password":"p"}}}'
STUB
chmod +x "$W/bin/curl"

# a baked conf: the real one, so the default really is "absent"
run_enroll() {   # run_enroll <override-file-or-empty> <logname>
  _ovr="$1"; _log="$W/$2.log"; : > "$_log"; : > "$_log.url"
  CURL_LOG="$_log" PATH="$W/bin:$PATH" \
  GA_ENROLL_CONF_DEFAULT="$BAKED_CONF" GA_ENROLL_CONF_OVERRIDE="${_ovr:-$W/no-such-override}" \
  GA_ENROLL_CREDS_FILE="$W/ghcr-creds.json" GA_ENROLL_STATE_FILE="$W/share/ga-enroll-state.json" \
  GA_ENROLL_NB_ENV="$W/no-nb-env" GA_ENROLL_HA_UUID_STORE="$W/no-uuid" \
  GA_SHARE_PUBLISH="$PUB" GA_SHARE_STAGE_DIR="$W/stage" \
  sh "$ENROLL" > "$W/$2.out" 2>&1
  echo $? > "$W/$2.rc"
}

# --- ENV-FE-01: absent → prod ---------------------------------------------------
run_enroll "" absent
run_test "ENV-FE-01" "absent GA_FLEET_ENV → payload fleet_env=prod (absent means production)" \
  "[ \"\$(cat '$W/absent.rc')\" = 0 ] && [ \"\$(jq -r .fleet_env '$W/absent.log')\" = prod ]"

# --- ENV-FE-02: override staging -------------------------------------------------
printf 'GA_FLEET_HOST=fleet.greenautarky.com\nGA_FLEET_PORT=8091\nGA_FLEET_ENV=staging\n' > "$W/override-staging.conf"
run_enroll "$W/override-staging.conf" staging
run_test "ENV-FE-02" "override GA_FLEET_ENV=staging → payload fleet_env=staging, URL on :8091" \
  "[ \"\$(cat '$W/staging.rc')\" = 0 ] && [ \"\$(jq -r .fleet_env '$W/staging.log')\" = staging ] && grep -q ':8091/api/enroll' '$W/staging.log.url'"

# --- ENV-FE-03: bridge carries it ----------------------------------------------
run_test "ENV-FE-03" "bridge state file carries fleet_env=staging next to ga_env" \
  "[ \"\$(jq -r .fleet_env '$W/share/ga-enroll-state.json')\" = staging ] && jq -e 'has(\"ga_env\")' '$W/share/ga-enroll-state.json' >/dev/null"

# --- ENV-FE-04/05: garbage is refused before any request ------------------------
printf 'GA_FLEET_HOST=fleet.greenautarky.com\nGA_FLEET_PORT=8091\nGA_FLEET_ENV=production\n' > "$W/override-bad.conf"
run_enroll "$W/override-bad.conf" bad
run_test "ENV-FE-04" "GA_FLEET_ENV=production (typo) → exit 1 and NO request made" \
  "[ \"\$(cat '$W/bad.rc')\" = 1 ] && [ ! -s '$W/bad.log' ]"
run_test "ENV-FE-05" "…and the error names the value and the override file" \
  "grep -q \"GA_FLEET_ENV='production'\" '$W/bad.out' && grep -q 'override-bad.conf' '$W/bad.out'"

# --- ENV-FE-06: the baked file does not set it -----------------------------------
run_test "ENV-FE-06" "baked ga-services.conf does not set GA_FLEET_ENV (absent = prod by construction)" \
  "! grep -qE '^[[:space:]]*GA_FLEET_ENV=' '$BAKED_CONF'"

rm -rf "$W" 2>/dev/null
suite_end
