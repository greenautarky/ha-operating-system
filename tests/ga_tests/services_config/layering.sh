#!/bin/sh
# ga-services.conf layering — the shared loader and the sweep over its consumers.
#
# Host test (no device). Two parts:
#   1. LOADER: drives the LIVE ga-services-conf.sh with a partial override
#      (defaults must survive, overridden keys must win), a full override, no
#      override, no default, and neither file.
#   2. SWEEP: every script in the overlay that reads ga-services.conf must go
#      through ga_load_services_conf — none may `.`-source a conf file itself.
#      This is the discriminator that found the consumers: a hand-rolled
#      `. "$CONF_OVERRIDE"` / `elif . default` is how the next reader reintroduces
#      "override replaces default". The list of consumers is derived from the
#      tree (grep), and the count is asserted > 0 and >= the known floor.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "ga-services.conf layering (shared loader + sweep)"

ROOT="$SCRIPT_DIR/../../.."
LIB="${GA_SERVICES_CONF_LIB:-$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-services-conf.sh}"
EXT="$ROOT/buildroot-external/rootfs-overlay"
IHOST="$ROOT/buildroot-ihost/rootfs-overlay"

run_test "LAY-00" "the shared loader exists" "test -r '$LIB'"

W="$(mktemp -d "${TMPDIR:-/tmp}/svc_layer.XXXXXX")"
trap 'rm -rf "$W"' EXIT
printf 'GA_SERVICES_IP=svc-baked\nGA_OTA_IPS="ota-a ota-b"\nGA_FLEET_PORT=8090\n' > "$W/baked.conf"

# probe CASE-FILE-ARGS... : load in a fresh shell, print "<rc>|<GA_CONF_LOADED-count>|IP|PORT|HOST"
probe() {
  sh -c '. "$1"; shift; unset GA_SERVICES_IP GA_FLEET_PORT GA_FLEET_HOST GA_OTA_IPS
         ga_load_services_conf "$1" "$2"; rc=$?
         printf "%s|%s|%s|%s|%s" "$rc" "${GA_CONF_LOADED:-}" "${GA_SERVICES_IP:-}" "${GA_FLEET_PORT:-}" "${GA_FLEET_HOST:-}"' _ "$LIB" "$1" "$2"
}

printf 'GA_FLEET_HOST=f.example\nGA_FLEET_PORT=8091\n' > "$W/partial.conf"
r="$(probe "$W/baked.conf" "$W/partial.conf")"
run_test "LAY-01" "PARTIAL override: baked GA_SERVICES_IP survives (red on override-replaces-default)" \
  "[ \"\$(echo '$r' | cut -d'|' -f3)\" = svc-baked ]"
run_test "LAY-02" "…the override's keys win over the baked ones (port 8091, host set)" \
  "[ \"\$(echo '$r' | cut -d'|' -f4)\" = 8091 ] && [ \"\$(echo '$r' | cut -d'|' -f5)\" = f.example ]"
run_test "LAY-03" "…and the loader reports both files and rc 0" \
  "echo '$r' | grep -q '^0|.*baked.conf + .*partial.conf|'"

printf 'GA_SERVICES_IP=svc-override\nGA_FLEET_PORT=1\n' > "$W/full.conf"
r="$(probe "$W/baked.conf" "$W/full.conf")"
run_test "LAY-04" "FULL override: every key it sets wins" \
  "[ \"\$(echo '$r' | cut -d'|' -f3)\" = svc-override ] && [ \"\$(echo '$r' | cut -d'|' -f4)\" = 1 ]"

r="$(probe "$W/baked.conf" "$W/none.conf")"
run_test "LAY-05" "NO override: the baked file alone, rc 0" \
  "[ \"\$(echo '$r' | cut -d'|' -f1)\" = 0 ] && [ \"\$(echo '$r' | cut -d'|' -f3)\" = svc-baked ]"
r="$(probe "$W/none.conf" "$W/partial.conf")"
run_test "LAY-06" "NO baked default, override only: loads it, rc 0, no invented IP" \
  "[ \"\$(echo '$r' | cut -d'|' -f1)\" = 0 ] && [ -z \"\$(echo '$r' | cut -d'|' -f3)\" ]"
r="$(probe "$W/none.conf" "$W/none2.conf")"
run_test "LAY-07" "NEITHER file: rc 1 (the caller must complain), nothing loaded" \
  "[ \"\$(echo '$r' | cut -d'|' -f1)\" = 1 ] && [ -z \"\$(echo '$r' | cut -d'|' -f2)\" ]"

# ---- sweep ----
consumers="$(grep -rIl 'ga_load_services_conf' "$EXT" "$IHOST" | grep -v 'ga-services-conf.sh$' | sort)"
n=$(printf '%s\n' "$consumers" | grep -c .)
# Floor: enroll, telemetry-env, resolve-ota, update-hosts, mesh-watchdog.
run_test "LAY-10" "sweep found the consumers ($n; floor 5, fail closed on zero)" "[ $n -ge 5 ]"

# Any script that names the conf paths or a *_CONF_OVERRIDE variable and `.`-sources
# a conf variable directly (outside the loader) is a hand-rolled reader.
bad=""
for f in $(grep -rIlE 'ga-services\.conf' "$EXT/usr" "$IHOST/usr" "$IHOST/etc/systemd" 2>/dev/null | grep -v 'ga-services-conf.sh$'); do
  if grep -nE '^[[:space:]]*(\[ -[fr] [^]]*\] *&& *)?\. +"?\$\{?(CONF_(DEFAULT|OVERRIDE)|OVERRIDE|BAKED)\}?"?' "$f" >/dev/null 2>&1; then
    bad="$bad $f"
  fi
done
run_test "LAY-11" "no script hand-sources the default/override itself (hand-rolled:${bad:- none})" "[ -z '$bad' ]"

# ga-publish-services reads per key without sourcing; it must keep override-then-baked per key.
run_test "LAY-12" "ga-publish-services falls back to the baked value per key" \
  "grep -q 'read_key \"\$OVERRIDE\" GA_SERVICES_IP' '$EXT/usr/libexec/ga-publish-services' && grep -q 'read_key \"\$BAKED\" GA_SERVICES_IP' '$EXT/usr/libexec/ga-publish-services'"

suite_end
