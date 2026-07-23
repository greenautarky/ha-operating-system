#!/bin/sh
# GA host-firewall test suite — runs ON the device.
# Tests ga-firewall-gate: the prepared/default-OFF nftables gate that keeps
# blocked services off the customer LAN while the NetBird mesh + loopback stay
# reachable. See usr/libexec/ga-firewall-gate + ga_manager firewall_reconcile.
#
# Three tiers:
#   A. Control-plane / static  — always safe, run everywhere.
#   B. Ruleset generation      — LOADS + FLUSHES real nft rules on-device to
#      inspect what the gate generates for a given policy. Opt-in via
#      GA_FW_ENFORCE_TEST=1; run on a BENCH device (serial-console recovery),
#      never a remote canary. The test policy only ever blocks ssh + observer —
#      NEVER the mesh / :8099 / :8123 — and always restores default-OFF at the end.
#   C. Reachability permutations — the full LAN-vs-mesh-vs-WiFi matrix. These
#      need an EXTERNAL LAN prober + a mesh peer, so they are documented as
#      skip_test here and driven by the E2E harness, not self-contained.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Host Firewall"

GATE=/usr/libexec/ga-firewall-gate
UNIT=/etc/systemd/system/ga-firewall.service
WANTS=/etc/systemd/system/multi-user.target.wants/ga-firewall.service
SHARE_DIR=/mnt/data/supervisor/share
ENABLE_FLAG="$SHARE_DIR/ga-firewall-enabled"
POLICY_FILE="$SHARE_DIR/ga-firewall-policy.json"
STATUS_FILE="$SHARE_DIR/ga-firewall-status.json"
TABLE="inet ga_firewall"

# =========================================================================
# A. Control-plane / static (safe everywhere)
# =========================================================================
run_test "FW-10" "ga-firewall-gate exists and is executable" \
  "test -x $GATE"

run_test "FW-11" "ga-firewall.service unit present" \
  "test -f $UNIT"

run_test "FW-12" "ga-firewall.service enabled (multi-user wants symlink)" \
  "test -L $WANTS"

run_test "FW-13" "gate script is valid /bin/sh" \
  "sh -n $GATE"

run_test "FW-14" "nft CLI present (BR2_PACKAGE_NFTABLES)" \
  "command -v nft"

# The load-bearing default-OFF invariant: with no enable marker, no GA firewall
# table is loaded → every port stays exposed exactly as before. (We do NOT
# create a marker here — this asserts the shipped default on a normal device.)
run_test "FW-15" "default OFF — no ga_firewall table loaded without a marker" \
  "test -e $ENABLE_FLAG || test -e /mnt/boot/ga-firewall || ! nft list table $TABLE >/dev/null 2>&1"

# =========================================================================
# B. Ruleset generation (opt-in, loads+flushes real rules — BENCH ONLY)
# =========================================================================
if [ "${GA_FW_ENFORCE_TEST:-0}" != "1" ]; then
  skip_test "FW-20" "ruleset generation (load real rules)" "set GA_FW_ENFORCE_TEST=1 on a bench device"
else
  echo ""
  echo "--- B. ruleset generation (BENCH — loading real nft rules) ---"

  # Back up any real state so we restore default-OFF no matter what.
  _had_flag=0; [ -e "$ENABLE_FLAG" ] && _had_flag=1
  _bak="$(mktemp /tmp/ga-fw-policy.bak.XXXXXX)"
  [ -r "$POLICY_FILE" ] && cp "$POLICY_FILE" "$_bak"

  # Test policy: block ONLY ssh (host/input) + observer (container/forward).
  # ga_manager(:8099) + ha_core(:8123) stay exposed = GACI/Companion invariant.
  mkdir -p "$SHARE_DIR"
  cat > "$POLICY_FILE" <<'JSON'
{
  "enabled": true,
  "services": {
    "ha_core": true,
    "ga_manager": true,
    "observer": false,
    "ssh": false,
    "influxdb": true,
    "mqtt": true
  }
}
JSON
  : > "$ENABLE_FLAG"
  "$GATE" >/dev/null 2>&1

  run_test "FW-20" "ruleset loaded (ga_firewall table present)" \
    "nft list table $TABLE"

  run_test "FW-21" "mesh invariant — wt0 accepted in input" \
    "nft list table $TABLE | grep -A20 'chain input' | grep -q 'wt0'"

  run_test "FW-22" "loopback invariant — lo accepted in input" \
    "nft list table $TABLE | grep -q 'iif \"lo\" accept'"

  run_test "FW-23" "mesh invariant — wt0 accepted in forward" \
    "nft list table $TABLE | grep -A20 'chain forward' | grep -q 'wt0'"

  run_test "FW-24" "ssh (:22222) dropped on LAN via input" \
    "nft list table $TABLE | grep -q 'tcp dport 22222 drop'"

  run_test "FW-25" "observer (:4357) dropped on LAN via forward (dnat-matched)" \
    "nft list table $TABLE | grep -Eq 'dnat.*4357|4357.*drop'"

  # GACI invariant: an un-blocked service must NOT get a drop rule.
  run_test "FW-26" "ga_manager (:8099) NOT dropped (stays reachable)" \
    "! nft list table $TABLE | grep -q '8099'"

  run_test "FW-27" "ha_core (:8123) NOT dropped (Companion/local UI stays open)" \
    "! nft list table $TABLE | grep -q '8123'"

  run_test "FW-28" "status JSON reports enabled + blocked list" \
    "grep -q '\"enabled\": true' $STATUS_FILE && grep -q 'ssh' $STATUS_FILE && grep -q 'observer' $STATUS_FILE"

  # Fail-open: a garbled policy must block nothing.
  echo "not json {{{" > "$POLICY_FILE"
  "$GATE" >/dev/null 2>&1
  run_test "FW-29" "malformed policy → fail-open (no drops)" \
    "! nft list table $TABLE 2>/dev/null | grep -q 'drop'"

  # Restore default-OFF: remove marker, re-run gate (flushes table), restore policy.
  rm -f "$ENABLE_FLAG"
  "$GATE" >/dev/null 2>&1
  run_test "FW-30" "disable (marker removed) → table flushed, ports reopen" \
    "! nft list table $TABLE >/dev/null 2>&1"

  if [ "$_had_flag" = 1 ]; then : > "$ENABLE_FLAG"; fi
  if [ -s "$_bak" ]; then cp "$_bak" "$POLICY_FILE"; else rm -f "$POLICY_FILE"; fi
  rm -f "$_bak"
  # Re-run the gate to reconcile back to the device's real desired state.
  "$GATE" >/dev/null 2>&1
fi

# =========================================================================
# C. Reachability permutations (E2E — external prober needed, documented)
# =========================================================================
skip_test "FW-40" "LAN client CANNOT reach :22222/:4357 when blocked"      "E2E: needs a LAN prober host"
skip_test "FW-41" "mesh peer CAN still reach :8099/:8123 when firewall on" "E2E: needs a NetBird peer"
skip_test "FW-42" "WiFi ingress behaves same as wired ingress (both LAN)"  "E2E: needs a WiFi LAN prober"
skip_test "FW-43" "device stays fleet-reachable after enable (no lockout)" "E2E: fleet-manager poll check"

suite_end
