#!/bin/bash
# board_firewall/selftest.sh -- red/green proof of check.sh (Odoo #1591). Reads the LIVE definition:
# the image tree of each board is assembled from the overlay roots its defconfig names
# (BR2_ROOTFS_OVERLAY, via ga_overlay_roots), nft comes from the defconfig package switch.
#   must-pass: ihost and dsgw210 as their defconfigs assemble them.
#   must-flag: the DSGW-210 WITHOUT the GA layer overlay (= no host firewall, the state #1591 feared),
#              no enable link, no board file (eth0 ruleset on a board whose NIC is end0), a gate
#              that opens InfluxDB, a gate that drops the LAN drop rule, no nft.
#   static:    both defconfigs select BR2_PACKAGE_NFTABLES and the GA layer overlay; one gate + one unit
#              exist (no per-board copy); iHost ruleset unchanged by the board file mechanism.
# Zero cases = FAIL. Offline, needs haos/ checked out.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/lib/tree-paths.sh
. "$ROOT/scripts/lib/tree-paths.sh"
# shellcheck source=../../../scripts/lib/journald-effective.sh
. "$ROOT/scripts/lib/journald-effective.sh"
CHECK="$HERE/check.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/fwb-st-XXXXXX")"; trap 'rm -rf "$W"' EXIT
ran=0; bad=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
no()  { ran=$((ran+1)); bad=$((bad+1)); echo "  FAIL  $1"; }

assemble() {  # <board> <dest> [skip-root-substring]
  local b="$1" d="$2" skip="${3:-}" r
  mkdir -p "$d"
  mapfile -t roots < <(GA_REPO_ROOT="$ROOT" ga_overlay_roots "$b") || return 1
  [ "${#roots[@]}" -ge 3 ] || return 1
  for r in "${roots[@]}"; do
    [ -n "$skip" ] && [[ "$r" == *"$skip" ]] && continue
    cp -a "$r/." "$d/"
  done
  mkdir -p "$d/usr/sbin"; : > "$d/usr/sbin/nft"   # the package, not the overlay (static check below)
}
must_pass() { local out; out="$("$CHECK" "$1" "$2" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && ! grep -q '^FAIL' <<<"$out"; then ok "$3"; else no "$3 -- $(grep '^FAIL' <<<"$out" | head -n 3 | tr '\n' '|')"; fi; }
must_flag() { local out; out="$("$CHECK" "$1" "$2" 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && grep -q "^FAIL $3 " <<<"$out"; then ok "$4 (red on $3)"; else no "$4 -- expected FAIL $3, got rc=$rc: $(grep '^FAIL' <<<"$out" | head -n 3 | tr '\n' '|')"; fi; }

for b in $GA_BOARDS; do
  assemble "$b" "$W/$b" || { no "$b: overlay roots of the defconfig could not be assembled (haos/ checked out?)"; continue; }
  must_pass "$b" "$W/$b" "MUST-PASS $b as its defconfig assembles it"
done
[ -d "$W/dsgw210" ] || { echo "cannot continue"; exit 1; }

# must-flag fixtures (dsgw210 unless stated)
assemble dsgw210 "$W/nofw" buildroot-external/rootfs-overlay || echo "(no GA-layer root skipped?)"
rm -f "$W/nofw/usr/libexec/ga-firewall-gate"   # make sure the skip really removed it
if [ ! -e "$W/nofw/etc/systemd/system/ga-firewall.service" ]; then must_flag dsgw210 "$W/nofw" FWB-01 "MUST-FLAG DSGW-210 without the GA-layer overlay (no firewall at all)"
else no "fixture nofw still has the unit (the GA-layer root was not skipped)"; fi

cp -a "$W/dsgw210" "$W/nowants"; rm -f "$W/nowants/etc/systemd/system/multi-user.target.wants/ga-firewall.service"
must_flag dsgw210 "$W/nowants" FWB-02 "MUST-FLAG unit present but not enabled"

cp -a "$W/dsgw210" "$W/noconf"; rm -f "$W/noconf/usr/share/ga-board.conf"
must_flag dsgw210 "$W/noconf" FWB-11 "MUST-FLAG DSGW-210 without its board file (rules would name eth0, not end0)"

cp -a "$W/dsgw210" "$W/influx"; chmod u+w "$W/influx/usr/libexec/ga-firewall-gate"
sed -i "s/^HOST_ALLOW_TCP='22222'/HOST_ALLOW_TCP='22222, 8086'/" "$W/influx/usr/libexec/ga-firewall-gate"
must_flag dsgw210 "$W/influx" FWB-14 "MUST-FLAG a gate that opens InfluxDB 8086 to the LAN"

cp -a "$W/dsgw210" "$W/nodrop"; chmod u+w "$W/nodrop/usr/libexec/ga-firewall-gate"
sed -i '/accept$/!{/iifname { \$LAN_IFACES } drop/d}' "$W/nodrop/usr/libexec/ga-firewall-gate"
cmp -s "$W/nodrop/usr/libexec/ga-firewall-gate" "$W/dsgw210/usr/libexec/ga-firewall-gate" \
  && no "fixture nodrop changed nothing" || must_flag dsgw210 "$W/nodrop" FWB-12 "MUST-FLAG a gate without the LAN drop rule"

cp -a "$W/dsgw210" "$W/nonft"; rm -f "$W/nonft/usr/sbin/nft"
must_flag dsgw210 "$W/nonft" FWB-04 "MUST-FLAG an image without nft"

# the iHost must not pass with the DSGW's NIC names and vice versa (pinned per board, not derived)
must_flag ihost "$W/dsgw210" FWB-11 "MUST-FLAG the DSGW-210 tree judged as an iHost (wrong NIC names)"

# static: defconfigs select nft and the GA layer overlay; one gate + one unit in the tree
for b in $GA_BOARDS; do
  d="$ROOT/$(ga_board_var DEFCONFIG "$b")"
  grep -q '^BR2_PACKAGE_NFTABLES=y' "$d" && ok "$b defconfig selects BR2_PACKAGE_NFTABLES" || no "$b defconfig lacks BR2_PACKAGE_NFTABLES"
  grep '^BR2_ROOTFS_OVERLAY=' "$d" | grep -q 'BR2_EXTERNAL_GA_HAOS_PATH)/rootfs-overlay' && ok "$b defconfig takes the GA-layer overlay" || no "$b defconfig lacks the GA-layer overlay"
done
n="$(git -C "$ROOT" ls-files | grep -cE '(^|/)ga-firewall(-gate|\.service)$')"
[ "$n" = 3 ] && ok "exactly one gate + one unit + one wants link tracked (no per-board copy)" || no "firewall files tracked: $n (expected 3: gate, unit, wants link)"

[ "$ran" -ge 14 ] || { echo "FAIL: only $ran cases ran (floor 14)"; exit 1; }
echo "$ran cases ran, $bad failed"; exit $((bad>0))
