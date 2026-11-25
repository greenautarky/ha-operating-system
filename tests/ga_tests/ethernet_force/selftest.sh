#!/bin/sh
# Host-side selftest of ETHF-03 in ethernet_force/test.sh: the LIVE suite against a status file,
# a marker path and a stub ga-manage-ethernet. Between the marker's retirement and the next boot
# the status still says source=force-boot: that "pending reboot" state must PASS, and only when
# the marker is gone, the status says boot_marker=absent AND a fresh evaluation is not force-boot.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
F="$W/f"; mkdir -p "$F"
cat > "$W/bin/manage" <<'STUB'
#!/bin/sh
[ -n "$(cat "$FAKE/next")" ] && echo "ethernet_source=$(cat "$FAKE/next")"
exit 0
STUB
chmod +x "$W/bin/manage"
status() {   # status <source> <boot_marker>
  printf '{\n  "schema_version": 2,\n  "enabled": true,\n  "source": "%s",\n  "boot_marker": "%s",\n  "link_state": "unknown",\n  "interface": "eth0"\n}\n' "$1" "$2" > "$W/status.json"
}
run() { ds_run ethernet_force FAKE="$F" GA_ETHF_FORCE_BOOT="$W/marker" GA_ETHF_STATUS="$W/status.json" GA_ETHF_BIN="$W/bin/manage"; }
rm -f "$W/marker"; echo default > "$F/next"

status force-boot absent; run;               ds_expect ETHF-03 PASS "retired, running state still force-boot, next boot default: pending reboot"
grep -q 'pending reboot' "$W/out" && { echo "  ok    the pending state is named in the verdict"; DS_PASS=$((DS_PASS+1)); } || { echo "  FAIL  pending not named"; DS_FAIL=$((DS_FAIL+1)); }
status onboarding absent; run;               ds_expect ETHF-03 PASS "source is not the flash-time override"
status force-boot present; run;              ds_expect ETHF-03 FAIL "status still reports the boot marker as present"
status force-boot absent; echo force-boot > "$F/next"; run
ds_expect ETHF-03 FAIL "a fresh evaluation still says force-boot: the override is still in force"
status force-boot absent; : > "$F/next"; run; ds_expect ETHF-03 FAIL "no fresh evaluation available: cannot call it pending"
status force-boot "";  echo default > "$F/next"; run; ds_expect ETHF-03 FAIL "status without boot_marker: unknown, not pending"
touch "$W/marker"; status force-boot absent; run; ds_expect ETHF-03 FAIL "marker file still on the card"
rm -f "$W/marker"; status "" absent; run;     ds_expect ETHF-03 FAIL "status without a source"
rm -f "$W/status.json"; run;                  ds_expect ETHF-03 SKIP "no status file"
ds_done
