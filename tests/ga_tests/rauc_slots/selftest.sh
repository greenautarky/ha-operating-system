#!/bin/sh
# Host-side selftest of the DEVICE half of rauc_slots/test.sh (SLOT-34, SLOT-41, SLOT-42):
# the live suite against fake /mnt/data/supervisor trees. The data root is apps/data on
# Supervisor 2026.10+ and addons/data on older field releases; both must work, and SLOT-34
# is "not applicable" (SKIP) exactly when a ga_manager data dir exists in either tree.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
SUP="$W/sup"
snap() {   # snap <tree> : a fresh snapshot in <tree>/data/<hash>_ga_manager
  mkdir -p "$SUP/$1/data/99f1cad4_ga_manager"
  printf '{"ts":%s,"booted":"A","rollback":{"possible":true,"target":"B"}}\n' "$(date +%s)" > "$SUP/$1/data/99f1cad4_ga_manager/ga-rauc-slots.json"
}
run() { ds_run rauc_slots GA_SLOT_SUPERVISOR_DIR="$SUP"; }

echo "== must-pass: either data root"
rm -rf "$SUP"; mkdir -p "$SUP"; snap apps;   run
ds_expect SLOT-41 PASS "snapshot under apps/data"
ds_expect SLOT-42 PASS "fresh snapshot read from apps/data"
ds_expect SLOT-34 SKIP "ga_manager installed (apps only): not applicable"
rm -rf "$SUP"; mkdir -p "$SUP"; snap addons; run
ds_expect SLOT-41 PASS "snapshot under addons/data (older field release)"
ds_expect SLOT-42 PASS "fresh snapshot read from addons/data"
ds_expect SLOT-34 SKIP "ga_manager installed (addons only): not applicable"

echo "== must-flag"
rm -rf "$SUP"; mkdir -p "$SUP/apps/data" "$SUP/addons/data"; run
ds_expect SLOT-41 FAIL "both trees exist, no snapshot anywhere"
ds_expect SLOT-34 PASS "no ga_manager dir at all: the negative case is constructible and holds"
rm -rf "$SUP"; mkdir -p "$SUP"; snap apps; echo '{"ts":1,"booted":"A"}' > "$SUP/apps/data/99f1cad4_ga_manager/ga-rauc-slots.json"; run
ds_expect SLOT-42 FAIL "stale snapshot (ts=1)"
rm -rf "$SUP"; mkdir -p "$SUP"; snap apps; : > "$SUP/apps/data/99f1cad4_ga_manager/ga-rauc-slots.json"; run
ds_expect SLOT-41 FAIL "empty snapshot file"
ds_done
