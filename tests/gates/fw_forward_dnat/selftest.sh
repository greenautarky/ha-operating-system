#!/bin/bash
# fw_forward_dnat/selftest.sh -- red/green proof for the host-firewall forward rule + the on-device suite (Odoo #1610).
# Two defects, one cause class: a check that cannot pass / a rule that cannot discriminate.
#  1. forward accepted `ct status dnat tcp dport { 80, 8123 }`: after Docker's PREROUTING DNAT every :80 container
#     looks like dport 80, so a published port mapping to :80 (observer :4357) was open from the LAN. Must match the
#     ORIGINAL port. Walked per packet below (pinned verdicts, not read from the gate).
#  2. tests/ga_tests/firewall/test.sh extracted chains with sed '/chain input/,/}/p', which stops at the first set
#     brace, so FW-25/26/26b/27/28/29b could never pass on real nft output. The LIVE test.sh is RUN here against
#     recorded real `nft list` output (must-pass) and broken rulesets (must-fail), with a PATH shim for nft.
# Reads the LIVE gate and the LIVE test.sh. Zero checks = FAIL. Offline.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="${FWD_GATE:-$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-firewall-gate}"   # overridable for the red proof
SUITE="${FWD_SUITE:-$ROOT/tests/ga_tests/firewall/test.sh}"
NEW="$HERE/must-pass/recorded-new-forward-original-port.nft"
OLD="$HERE/must-fail/recorded-old-forward-dnat-dport.nft"
W="$(mktemp -d "${TMPDIR:-/tmp}/fwd-st-XXXXXX")"; trap 'rm -rf "$W"' EXIT
ran=0; bad=0
ok() { ran=$((ran+1)); echo "  ok    $1"; }
no() { ran=$((ran+1)); bad=$((bad+1)); echo "  FAIL  $1"; }
[ -r "$GATE" ] && [ -r "$SUITE" ] && [ -r "$NEW" ] && [ -r "$OLD" ] || { echo "FAIL: gate/suite/fixtures missing"; exit 1; }

# nft shim: `nft list table X` prints the fixture named in $NFT_FIXTURE
mkdir -p "$W/bin"
cat > "$W/bin/nft" <<'S'
#!/bin/sh
case "$1" in list) cat "$NFT_FIXTURE" ;; *) exit 1 ;; esac
S
chmod +x "$W/bin/nft"

# run the LIVE suite section B against a fixture; echo "<ID> PASS|FAIL" lines
suite() {
  NFT_FIXTURE="$1" GA_FW_ENFORCE_TEST=1 PATH="$W/bin:$PATH" sh "$SUITE" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | awk '$1=="PASS"||$1=="FAIL"{id=$2; sub(":","",id); print id, $1}'
}
verdict_of() { grep -E "^$2 " <<<"$1" | head -n1 | cut -d' ' -f2; }
expect() {  # <results> <id> <PASS|FAIL> <label>
  local v; v="$(verdict_of "$1" "$2")"
  if [ "$v" = "$3" ]; then ok "$4 ($2 $3)"; else no "$4 ($2 expected $3, got '${v:-absent}')"; fi
}

# ---- 0. the live suite still defines the helper and the ids we test (extraction must not silently find nothing)
grep -q '^# BEGIN fw_chain' "$SUITE" && grep -q '^# END fw_chain' "$SUITE" && ok "suite defines fw_chain (markers found)" || no "fw_chain markers missing in test.sh"
! grep -n "sed -n '/chain " "$SUITE" >/dev/null && ok "suite has no first-brace sed chain extraction left" || no "suite still uses sed '/chain X/,/}/p'"

# ---- 1. MUST-PASS fixture, recorded real nft output, new rule: every firewall assertion that reads the ruleset is green
R_NEW="$(suite "$NEW")"
[ "$(wc -l <<<"$R_NEW")" -ge 15 ] && ok "suite produced results for the fixture ($(wc -l <<<"$R_NEW") lines)" || no "suite produced too few results: $R_NEW"
for id in FW-21 FW-22 FW-23 FW-24 FW-25 FW-26 FW-26b FW-27 FW-28 FW-28b FW-28c FW-29 FW-29b; do
  expect "$R_NEW" "$id" PASS "MUST-PASS recorded real ruleset, new rule"
done

# ---- 1b. the same recorded ruleset with the OLD rule: parser-bound checks still pass (they could not before), 28b/28c go RED
R_OLD="$(suite "$OLD")"
for id in FW-25 FW-26 FW-26b FW-27 FW-29b; do expect "$R_OLD" "$id" PASS "recorded real ruleset (old rule): input-chain check reaches past the set brace"; done
expect "$R_OLD" FW-28b FAIL "MUST-FLAG forward accept by post-DNAT dport"
expect "$R_OLD" FW-28c FAIL "MUST-FLAG forward 'dnat ... tcp dport' accept"

# ---- 1c. MUST-FAIL fixtures: the input checks are not vacuous
R=$(suite "$HERE/must-fail/input-lost-22222-accept.nft");      expect "$R" FW-25 FAIL "MUST-FLAG input chain without the 22222 accept"
R=$(suite "$HERE/must-fail/input-no-final-default-drop.nft");  expect "$R" FW-29b FAIL "MUST-FLAG input chain without the final bare drop"

# ---- 1d. red proof of the bug itself: the OLD sed expression on the recorded real output stops at the set brace
if sed -n '/chain input/,/}/p' "$NEW" | grep -q '22222'; then no "old sed expression unexpectedly reaches 22222 (fixture does not exercise the bug)"
else ok "OLD sed '/chain input/,/}/p' never reaches the 22222 accept on real output (bug reproduced)"; fi

# ---- 2. per-packet walk of the forward chain: LAN (wlan0) -> DNAT'd container; ORIG port, post-DNAT port
chain() { awk '/^\tchain forward/{p=1} p{print} p&&/^\t}/{exit}' "$1"; }
walk() { chain "$1" > "$W/chain"; python3 -I "$HERE/walk_forward.py" "$W/chain" "$2" "$3" "$4"; }
check() { local got; got="$(walk "$1" "$2" "$3" "$4")"; if [ "$got" = "$5" ]; then ok "$6: $2 orig:$3 -> :$4 = $5"; else no "$6: $2 orig:$3 -> :$4 expected $5 got '$got'"; fi; }
check "$NEW" wlan0 4357 80  drop   "NEW rule, observer DNAT 4357->80 is NOT accepted"
check "$NEW" eth0  4357 80  drop   "NEW rule, observer DNAT 4357->80 is NOT accepted"
check "$NEW" wlan0 8086 8086 drop  "NEW rule, influx DNAT dropped"
check "$NEW" wlan0 80   80  accept "NEW rule, original :80 (HA UI) accepted"
check "$NEW" wlan0 8123 8123 accept "NEW rule, original :8123 accepted"
check "$NEW" ppp0  4357 80  drop   "NEW rule, other-uplink DNAT dropped (final dnat drop)"
check "$OLD" wlan0 4357 80  accept "OLD rule (red proof): 4357->80 accepted = the measured exposure"

# ---- 3. the LIVE gate renders the rule (no copy): rule text == the recorded new rule, and nothing matches the post-DNAT port
mkdir -p "$W/g"
cat > "$W/g/nft" <<'S'
#!/bin/sh
[ "$1" = "-f" ] && { cp "$2" "$NFT_CAPTURE"; exit 0; }
exit 1
S
chmod +x "$W/g/nft"
CONF="$ROOT/buildroot-external/rootfs-overlay/usr/share/ga-board.conf"; [ -r "$CONF" ] || CONF="$W/none"
env -u GA_LAN_IFACES PATH="$W/g:$PATH" NFT_CAPTURE="$W/rules" GA_BOARD_CONF="$CONF" sh "$GATE" >/dev/null 2>&1
if [ -s "$W/rules" ]; then
  want="$(grep 'ct original proto-dst' "$NEW" | sed 's/^[[:space:]]*//')"
  got="$(grep 'ct original proto-dst' "$W/rules" | sed 's/^[[:space:]]*//')"
  [ -n "$want" ] && [ "$got" = "$want" ] && ok "gate renders exactly the recorded rule: $got" || no "gate rule '$got' != recorded '$want'"
  ! grep 'ct status dnat' "$W/rules" | grep -q 'tcp dport' && ok "gate renders no 'ct status dnat ... tcp dport' rule" || no "gate still renders a post-DNAT dport rule"
  if unshare -rn true 2>/dev/null; then
    unshare -rn sh -c 'nft -c -f "$1"' sh "$W/rules" 2>/dev/null && ok "nft -c accepts the gate's rendered ruleset (real nft)" || no "nft -c rejects the gate's rendered ruleset"
  else echo "  note  user namespaces unavailable: real-nft syntax check of the rendered ruleset NOT run here"; fi
else no "the gate rendered no ruleset"; fi

echo "ran=$ran bad=$bad"
[ "$ran" -gt 0 ] && [ "$bad" = 0 ]
