#!/bin/sh
# RAUC slot-visibility suite (Odoo #561).
#
# Two halves:
#   * parser  — pure host-side, runs anywhere with sh + awk + jq. Feeds
#               captured `rauc status --detailed --output-format=shell`
#               fixtures through /usr/libexec/ga-rauc-slots and asserts the
#               published contract. No device needed.
#   * device  — asserts the collector is actually wired on a running device
#               (timer enabled, file present, fresh, agrees with rauc).
#               Skipped off-device.
#
# The property worth protecting: a slot that RAUC never installed into must
# NEVER be reported as a rollback target, even though the bootloader still
# calls it `boot status: good` (verified on a fresh SD flash, 2026-07-28).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "RAUC slots"

# Locate the collector: installed path on device, overlay path in-repo.
COL="/usr/libexec/ga-rauc-slots"
[ -x "$COL" ] || COL="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/ga-rauc-slots"
FIX="$SCRIPT_DIR/fixtures"

run_test "SLOT-20" "collector present + executable" "test -x '$COL'"

if ! command -v jq >/dev/null 2>&1; then
  skip_test "SLOT-21..SLOT-31" "parser contract" "jq not available"
else

WORK="$(mktemp -d 2>/dev/null || echo /tmp/rslots_$$)"

# Run the collector against a fixture, leaving the JSON in $WORK/<name>.json.
parse_fixture() {
  GA_RAUC_SLOTS_TS=1753790000 \
  GA_RAUC_SLOTS_INPUT="$FIX/$1.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/$1.json" \
  "$COL" >/dev/null 2>&1
}

# --- healthy dual-slot device (booted A, previous release still in B) --------
parse_fixture dual-slot-healthy
H="$WORK/dual-slot-healthy.json"

run_test "SLOT-21" "healthy: output is valid JSON carrying ts + no error" \
  "jq -e '.ts == 1753790000 and .error == null' '$H'"

run_test "SLOT-22" "healthy: booted slot A, rollback target B, rollback possible" \
  "jq -e '.booted == \"A\" and .rollback.current == \"A\" and .rollback.target == \"B\" and .rollback.possible == true and .rollback.reason == null' '$H'"

run_test "SLOT-23" "healthy: per-slot installed version read from the slot group" \
  "jq -e '(.slots | map({(.bootname): .installed_version}) | add) == {\"A\":\"16.3.1.9\",\"B\":\"16.3.1.8\"}' '$H'"

# The bootname lives on kernel.N while the OS version is recorded on both
# kernel.N and its rootfs.N child. Grouping parent+children is what makes
# install history readable regardless of which member RAUC wrote it to.
run_test "SLOT-24" "healthy: each slot groups its kernel + rootfs members" \
  "jq -e '(.slots[] | select(.bootname == \"A\") | .members) == [\"kernel.0\",\"rootfs.0\"]' '$H'"

# --- fresh SD flash: THE case this whole feature exists for ------------------
parse_fixture fresh-sd-flash
F="$WORK/fresh-sd-flash.json"

run_test "SLOT-25" "fresh flash: rollback is NOT possible (slot B never installed)" \
  "jq -e '.rollback.possible == false and .rollback.target == \"B\"' '$F'"

run_test "SLOT-26" "fresh flash: reason names the empty slot + the reflash consequence" \
  "jq -e '.rollback.reason | test(\"never received an OTA install\") and test(\"re-flash\")' '$F'"

# Regression guard for the actual trap: boot_status is STILL 'good' on the
# empty slot. If a future refactor gates rollback on boot_status alone, this
# fixture goes green while the device bricks — so assert both halves.
run_test "SLOT-27" "fresh flash: empty slot B still reports boot_status=good (why boot_status is not the gate)" \
  "jq -e '(.slots[] | select(.bootname == \"B\")) | .boot_status == \"good\" and .ever_installed == false and .bootable == false' '$F'"

run_test "SLOT-28" "fresh flash: the BOOTED slot is bootable even with no install record" \
  "jq -e '(.slots[] | select(.bootname == \"A\")) | .ever_installed == false and .bootable == true' '$F'"

# --- slot present but condemned by the bootloader ---------------------------
parse_fixture slot-b-marked-bad
B="$WORK/slot-b-marked-bad.json"

run_test "SLOT-29" "marked-bad: rollback blocked, reason names the bootloader" \
  "jq -e '.rollback.possible == false and (.rollback.reason | test(\"marked bad by the bootloader\"))' '$B'"

# --- booted from B: nothing may hardcode A as the current slot --------------
parse_fixture booted-from-b
R="$WORK/booted-from-b.json"

run_test "SLOT-30" "booted from B: current is B and the rollback target is A" \
  "jq -e '.booted == \"B\" and .rollback.current == \"B\" and .rollback.target == \"A\" and .rollback.possible == true' '$R'"

# --- fail closed ------------------------------------------------------------
: > "$WORK/empty.shell"
GA_RAUC_SLOTS_TS=1753790000 GA_RAUC_SLOTS_INPUT="$WORK/empty.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/empty.json" "$COL" >/dev/null 2>&1
run_test "SLOT-31a" "rauc silent: publishes an error record, never a bootable-looking one" \
  "jq -e '.error != null and .slots == [] and .rollback.possible == false' '$WORK/empty.json'"

printf 'this is not rauc output\nneither is this\n' > "$WORK/garbage.shell"
GA_RAUC_SLOTS_TS=1753790000 GA_RAUC_SLOTS_INPUT="$WORK/garbage.shell" \
  GA_RAUC_SLOTS_OUT="$WORK/garbage.json" "$COL" >/dev/null 2>&1
run_test "SLOT-31b" "unparseable rauc output: error record, rollback not possible" \
  "jq -e '.error != null and .rollback.possible == false' '$WORK/garbage.json'"

rm -rf "$WORK"
fi

# --- static: rauc output is parsed, never executed --------------------------
# /usr/libexec/raucdb-update does `eval "$(rauc status ...)"`. This collector
# deliberately does not: it runs as root and the habit is worth keeping out of
# new code. Cheap static guard so it cannot creep back in.
run_test "SLOT-32" "collector never evals or sources rauc output" \
  "! grep -v '^[[:space:]]*#' '$COL' | grep -Eq '(^|[^[:alnum:]_])(eval|source)[[:space:]]|^[[:space:]]*\\.[[:space:]]'"

# =========================================================================
# Device-side wiring (skipped off-device)
# =========================================================================
if [ ! -d /mnt/data/supervisor/share ]; then
  skip_test "SLOT-40..SLOT-44" "on-device collector wiring" "not running on a GA device"
else
  run_test "SLOT-40" "ga-rauc-slots.timer enabled" \
    "systemctl is-enabled ga-rauc-slots.timer"

  SHARE_JSON="/mnt/data/supervisor/share/ga-rauc-slots.json"
  run_test "SLOT-41" "slot snapshot published to the /share bridge" \
    "test -s '$SHARE_JSON'"

  if [ -s "$SHARE_JSON" ] && command -v jq >/dev/null 2>&1; then
    # The addon treats anything older than 3 missed 10min ticks as stale and
    # degrades to unknown; assert the collector keeps it inside that window.
    run_test "SLOT-42" "snapshot fresher than the addon's 35min staleness window" \
      "[ \$(( \$(date +%s) - \$(jq -r '.ts' '$SHARE_JSON') )) -lt 2100 ]"

    run_test "SLOT-43" "snapshot agrees with live rauc on the booted slot" \
      "[ \"\$(jq -r '.booted' '$SHARE_JSON')\" = \"\$(rauc status --output-format=shell 2>/dev/null | sed -n \"s/^RAUC_SYSTEM_BOOTED_BOOTNAME='\\(.*\\)'\$/\\1/p\")\" ]"

    run_test_show "SLOT-44" "rollback target + verdict on this device" \
      "jq -r '\"target=\" + (.rollback.target // \"none\") + \" possible=\" + (.rollback.possible|tostring) + \" reason=\" + (.rollback.reason // \"-\")' '$SHARE_JSON'"
  else
    skip_test "SLOT-42..SLOT-44" "snapshot content checks" "no snapshot or jq unavailable"
  fi
fi

suite_end
