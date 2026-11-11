#!/bin/sh
# GA host-firewall test suite — runs ON the device.
# Tests ga-firewall-gate: the DEFAULT-ON nftables gate that exposes only SSH
# and the Home Assistant UI on the customer LAN, keeping everything else on the
# NetBird mesh / Tailscale. See usr/libexec/ga-firewall-gate.
#
# Three tiers:
#   A. Control-plane / static  — always safe, run everywhere.
#   B. Ruleset generation      — LOADS + FLUSHES real nft rules on-device to
#      inspect what the gate generates for a given policy. Opt-in via
#      GA_FW_ENFORCE_TEST=1; run on a BENCH device (serial-console recovery),
#      never a remote canary. The mesh accepts are asserted before anything
#      else, and the gate is re-run at the end to restore the real state.
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

# BEGIN fw_chain (read out of this file by tests/gates/fw_forward_dnat/selftest.sh -- keep the markers)
# Print ONE chain of the live table, from its "chain <name> {" line to the chain's own closing
# brace (a tab-indented "}" -- nft list indents chains by one tab and prints the table brace at
# column 0). The old sed range (chain line to first closing brace) ended at the FIRST "}" -- the one closing the
# set in `iifname { "wt0", "tailscale0" } accept` -- so FW-25..29b could never pass (Odoo #1610).
fw_chain() {
  nft list table $TABLE | awk -v want="chain $1 {" '
    index($0, want) { p = 1 }
    p { print }
    p && /^\t}[[:space:]]*$/ { exit }'
}
# END fw_chain

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

# The load-bearing invariant, now inverted: the firewall is the shipped
# posture. Absent state is the SAFE state — a device that missed a provisioning
# step must come up filtered, not open. Only the explicit off-marker disables it.
run_test "FW-15" "default ON — ga_firewall table loaded unless the off-marker exists" \
  "test -e /mnt/boot/ga-firewall-off || nft list table $TABLE >/dev/null 2>&1"

run_test "FW-16" "off-marker is the only documented escape hatch" \
  "grep -q 'ga-firewall-off' $GATE"

# =========================================================================
# B. Ruleset generation (opt-in, loads+flushes real rules — BENCH ONLY)
# =========================================================================
if [ "${GA_FW_ENFORCE_TEST:-0}" != "1" ]; then
  skip_test "FW-20" "ruleset generation (load real rules)" "set GA_FW_ENFORCE_TEST=1 on a bench device"
else
  echo ""
  echo "--- B. ruleset generation (BENCH — loading real nft rules) ---"

  # The gate takes no policy input any more: the allowlist is the shipped
  # posture. Just run it and inspect what it produced.
  "$GATE" >/dev/null 2>&1

  run_test "FW-20" "ruleset loaded (ga_firewall table present)" \
    "nft list table $TABLE"

  # --- invariants: these must hold or a device becomes unreachable --------
  run_test "FW-21" "mesh invariant — wt0 accepted in input" \
    "fw_chain input | grep -q 'wt0'"

  run_test "FW-22" "loopback invariant — lo accepted in input" \
    "nft list table $TABLE | grep -q 'iif \"lo\" accept'"

  run_test "FW-23" "mesh invariant — wt0 accepted in forward" \
    "fw_chain forward | grep -q 'wt0'"

  # An inet table that drops ICMPv6 discovery kills IPv6 outright: no address
  # resolution, and no router advertisement means no default route. This is the
  # failure that looks fine on v4 and takes a day to find.
  run_test "FW-24" "IPv6 stays usable — ND/RA accepted" \
    "nft list table $TABLE | grep -q 'nd-router-advert'"

  # --- the allowlist itself ----------------------------------------------
  run_test "FW-25" "SSH (:22222) reachable from the LAN (host/input)" \
    "fw_chain input | grep -Eq '22222.*accept'"

  # In the input chain, not just forward: HA Core listens on the HOST
  # (host networking), so its UI port hits `input`. Published container ports
  # are DNAT'd and take the forward chain instead (matched by original port).
  run_test "FW-26" "HA UI (:8123) reachable from the LAN (input chain)" \
    "fw_chain input | grep -Eq '8123.*accept'"

  # :80 is the current HA Core default UI port (older frozen Core used :8123).
  # Added to the allowlist 2026-08-21; both must be reachable.
  run_test "FW-26b" "HA UI (:80) reachable from the LAN (input chain)" \
    "fw_chain input | grep -Eq 'dport.*(\\b80\\b).*accept|,\\s*80[,\\s]'"

  # --- default-deny -------------------------------------------------------
  run_test "FW-27" "LAN ingress otherwise dropped (input)" \
    "fw_chain input | grep -Eq 'eth0.*drop|drop.*eth0'"

  run_test "FW-28" "LAN ingress to container ports otherwise dropped (forward)" \
    "fw_chain forward | grep -Eq 'dnat.*drop'"

  # Odoo #1610: published container ports are DNAT'd in PREROUTING, so forward sees the container-side
  # port. The accept must match the ORIGINAL port; matching the post-DNAT `dport 80` also matches published container ports that map to :80.
  run_test "FW-28b" "forward accepts DNAT'd LAN traffic by ORIGINAL port (80/8123)" \
    "fw_chain forward | grep -Eq 'ct status dnat .*ct original proto-dst \\{ *80, 8123 *\\} accept'"

  run_test "FW-28c" "forward never matches the post-DNAT port (no 'dnat ... tcp dport' accept)" \
    "! fw_chain forward | grep -E 'ct status dnat' | grep -E 'tcp dport' | grep -q accept"

  # Container bridges must never be filtered here — a rule naming hassio or
  # docker0 would break add-on traffic in a way that looks like a broken add-on.
  run_test "FW-29" "container bridges never dropped (accept-only rules for hassio/docker0/veth)" \
    "! nft list table $TABLE | grep -E 'hassio|docker0|veth' | grep -q drop"

  # Odoo #1647: the table ends in a default drop, so uplinks (ppp0/wwan0/usb0) and unknown NICs get nothing.
  run_test "FW-29b" "default-deny: input chain ends in a bare drop (uplinks closed)" \
    "fw_chain input | grep -E '^[[:space:]]*(counter )?drop' | tail -n1 | grep -Eq '^[[:space:]]*(counter )?drop[[:space:]]*\$'"

  run_test "FW-30" "status JSON reports the allowlist mode" \
    "grep -q '\"enabled\": true' $STATUS_FILE && grep -q 'allowlist' $STATUS_FILE"

  # --- escape hatch -------------------------------------------------------
  _off=/mnt/boot/ga-firewall-off
  _had_off=0; [ -e "$_off" ] && _had_off=1
  : > "$_off" 2>/dev/null && {
    "$GATE" >/dev/null 2>&1
    run_test "FW-31" "off-marker → table flushed, ports reopen" \
      "! nft list table $TABLE >/dev/null 2>&1"
    [ "$_had_off" = 1 ] || rm -f "$_off"
  }

  # Reconcile back to the device's real desired state.
  "$GATE" >/dev/null 2>&1
fi

# =========================================================================
# C. Reachability permutations (E2E — external prober needed, documented)
# =========================================================================
skip_test "FW-40" "LAN client CANNOT reach :22222 or a published container port when blocked"      "E2E: needs a LAN prober host"
skip_test "FW-41" "mesh peer CAN still reach :8099/:8123 when firewall on" "E2E: needs a NetBird peer"
skip_test "FW-42" "WiFi ingress behaves same as wired ingress (both LAN)"  "E2E: needs a WiFi LAN prober"
skip_test "FW-43" "device stays fleet-reachable after enable (no lockout)" "E2E: fleet-manager poll check"

suite_end
