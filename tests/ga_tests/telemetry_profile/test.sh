#!/bin/sh
# Telemetry profile on the device (ADR-0045, Odoo #1227) — runs ON the device.
#
#   TPR-01  ga-telemetry-profile.service is enabled (applies at boot, before the shippers)
#   TPR-02  ga-telemetry-profile.path is active (re-applies on every gm decision)
#   TPR-03  the read-back in ga_manager's data dir is valid and names a known profile
#   TPR-04  the drop-ins match the applied profile (none for normal/minimal,
#           three for lte_saver) AND tier-0's RUNNING process (MainPID cmdline,
#           not the unit's ExecStart) runs the config the profile names
#   TPR-05  the request, when present, is a regular file (never a symlink)
#   TPR-06  the .path starts the runtime unit, which is not ordered before the
#           shippers (a runtime switch from an ordered unit deadlocks, 2026-10-12)
#
# The data-path half (errors reach Loki in every profile) is proven off-device
# by tests/gates/telemetry_profiles with the real fluent-bit.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Telemetry profile (ADR-0045)"

GM_DIR="/mnt/data/supervisor/addons/data/99f1cad4_ga_manager"
RB="$GM_DIR/ga-telemetry-profile.applied.json"
REQ="$GM_DIR/ga-telemetry-profile.json"
DROP="/run/systemd/system"

run_test "TPR-01" "ga-telemetry-profile.service is enabled" \
  "systemctl is-enabled ga-telemetry-profile.service >/dev/null 2>&1"
run_test "TPR-02" "ga-telemetry-profile.path is active" \
  "systemctl is-active ga-telemetry-profile.path >/dev/null 2>&1"

if [ -d "$GM_DIR" ]; then
  run_test "TPR-03" "read-back valid with a known applied profile" \
    "jq -e '.schema == 1 and (.applied | IN(\"normal\",\"minimal\",\"lte_saver\"))' $RB >/dev/null"
  APPLIED="$(jq -r .applied "$RB" 2>/dev/null)"
  n="$(ls $DROP/fluent-bit-tier0.service.d/50-ga-profile.conf $DROP/fluent-bit.service.d/50-ga-profile.conf $DROP/telegraf.service.d/50-ga-profile.conf 2>/dev/null | wc -l)"
  T0PID="$(systemctl show -p MainPID --value fluent-bit-tier0.service 2>/dev/null)"
  T0CMD="$(tr '\000' ' ' < "/proc/${T0PID:-0}/cmdline" 2>/dev/null)"
  case "$APPLIED" in
    lte_saver) run_test "TPR-04" "lte_saver: 3 drop-ins, tier-0 RUNS the rendered config ($n; $T0CMD)" \
                 "[ $n -eq 3 ] && echo '$T0CMD' | grep -q /run/ga-telemetry/lte-saver/tier0.conf" ;;
    *)         run_test "TPR-04" "$APPLIED: no profile drop-in, tier-0 runs its base config ($n; $T0CMD)" \
                 "[ $n -eq 0 ] && [ -n '$T0CMD' ] && ! echo '$T0CMD' | grep -q /run/ga-telemetry/lte-saver/" ;;
  esac
else
  warn_test "TPR-03" "no ga_manager data directory yet — read-back N/A" "true"
fi
if [ -e "$REQ" ] || [ -L "$REQ" ]; then
  run_test "TPR-05" "the request is a regular file" "[ -f $REQ ] && [ ! -L $REQ ]"
else
  warn_test "TPR-05" "no request (ga_manager without telemetry profiles) — base units expected" "true"
fi

run_test "TPR-06" "the .path starts the runtime unit, not ordered before the shippers" \
  "systemctl show -p Triggers --value ga-telemetry-profile.path | grep -qw ga-telemetry-profile-runtime.service && ! systemctl show -p Before --value ga-telemetry-profile-runtime.service | grep -qE 'fluent-bit|telegraf'"

suite_end
