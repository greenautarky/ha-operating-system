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

# --- Odoo #1647: the uplink must not be reachable (default-deny on every non-trusted interface)
GATEF=usr/libexec/ga-firewall-gate
cp -a "$W/dsgw210" "$W/nocatch"; chmod u+w "$W/nocatch/$GATEF"
sed -i '/Default deny for every other interface/,+1d' "$W/nocatch/$GATEF"   # the old denylist-only model
cmp -s "$W/nocatch/$GATEF" "$W/dsgw210/$GATEF" && no "fixture nocatch changed nothing" \
  || must_flag dsgw210 "$W/nocatch" FWB-16 "MUST-FLAG an uplink interface not covered (no default drop: usb0/ppp0 reach the add-on ports)"

cp -a "$W/dsgw210" "$W/ppplan"; chmod u+w "$W/ppplan/usr/share/ga-board.conf"
sed -i 's/GA_LAN_IFACES:=end0 wlan0/GA_LAN_IFACES:=end0 wlan0 ppp0/' "$W/ppplan/usr/share/ga-board.conf"
grep -q 'wlan0 ppp0}' "$W/ppplan/usr/share/ga-board.conf" && must_flag dsgw210 "$W/ppplan" FWB-16 "MUST-FLAG an add-on/ssh port reachable via ppp0 (modem listed as LAN)" \
  || no "fixture ppplan did not change the board file"

cp -a "$W/dsgw210" "$W/nobridge"; chmod u+w "$W/nobridge/$GATEF"
sed -i '/iifname ."veth/d' "$W/nobridge/$GATEF"
cmp -s "$W/nobridge/$GATEF" "$W/dsgw210/$GATEF" && no "fixture nobridge changed nothing" \
  || must_flag dsgw210 "$W/nobridge" FWB-17 "MUST-FLAG a gate that would drop container (veth) traffic under the default drop"

cp -a "$W/dsgw210" "$W/noest"; chmod u+w "$W/noest/$GATEF"
sed -i '/echo "    ct state established,related accept"/d' "$W/noest/$GATEF"
cmp -s "$W/noest/$GATEF" "$W/dsgw210/$GATEF" && no "fixture noest changed nothing" \
  || must_flag dsgw210 "$W/noest" FWB-18 "MUST-FLAG a gate that drops replies to the device's own connections"

# the iHost must not pass with the DSGW's NIC names and vice versa (pinned per board, not derived)
must_flag ihost "$W/dsgw210" FWB-11 "MUST-FLAG the DSGW-210 tree judged as an iHost (wrong NIC names)"

# --- failure injection (rule 53; Odoo #1445): the path that only runs on the event it reports.
# The LIVE gate of each board's tree is run with an nft that rejects `-f`. Paths are rewritten on a COPY
# (the gate hardcodes /mnt/data, /mnt/boot, /usr/libexec); the rewrite itself is asserted.
# inject <gate-file> <tag> -> sets FI_RC FI_STATUS FI_LOG after running it with a failing nft
inject() {
  local g="$1" t="$2" d="$W/fi-$2"
  mkdir -p "$d/bin" "$d/share" "$d/boot"
  sed -e "s#^SHARE_DIR=.*#SHARE_DIR=$d/share#" -e "s#^OFF_MARKER=.*#OFF_MARKER=$d/boot/ga-firewall-off#" \
      -e "s#/usr/libexec/ga-share-publish#$d/bin/ga-share-publish#" "$g" > "$d/gate"
  grep -q "^SHARE_DIR=$d/share" "$d/gate" && grep -q "$d/bin/ga-share-publish" "$d/gate" && grep -q "^OFF_MARKER=$d/boot" "$d/gate" \
    || { FI_RC=rewrite; return 1; }
  printf '#!/bin/sh\ncat > "$1"\n' > "$d/bin/ga-share-publish"   # same contract as the real helper: path, mode, stdin
  printf '#!/bin/sh\necho "$@" >> "%s/logger.out"\n' "$d" > "$d/bin/logger"
  printf '#!/bin/sh\ncase "$1" in -f) echo "Error: injected load failure" >&2; exit 1 ;; list) exit 1 ;; *) exit 0 ;; esac\n' > "$d/bin/nft"
  chmod +x "$d/bin/"*
  env PATH="$d/bin:$PATH" GA_BOARD_CONF="$d/none" sh "$d/gate" >"$d/out" 2>&1; FI_RC=$?
  FI_STATUS=""; [ -r "$d/share/ga-firewall-status.json" ] && FI_STATUS="$(tr -d '\n' < "$d/share/ga-firewall-status.json")"
  FI_LOG=""; [ -r "$d/logger.out" ] && FI_LOG="$(cat "$d/logger.out")"
  return 0
}
fi_assert() {  # <gate-file> <tag> <label> -> ok/no for each of the three loud-failure properties
  inject "$1" "$2" || { no "$3: failure-injection path rewrite did not apply (gate text changed?)"; return; }
  [ "$FI_RC" = 0 ] && ok "$3: load failure -> gate exits 0 (fail-open by design, never wedges boot)" || no "$3: load failure -> exit $FI_RC"
  grep -q '"ruleset_loaded": false' <<<"$FI_STATUS" && grep -q '"source": "load-failed"' <<<"$FI_STATUS" && grep -q '"enabled": false' <<<"$FI_STATUS" \
    && ok "$3: load failure -> status JSON ruleset_loaded=false / source=load-failed / enabled=false" || no "$3: load failure -> status JSON wrong: $FI_STATUS"
  grep -q 'daemon.err' <<<"$FI_LOG" && grep -q 'UNFILTERED' <<<"$FI_LOG" \
    && ok "$3: load failure -> journal line at daemon.err naming UNFILTERED" || no "$3: load failure -> no err-level log line"
}
for b in $GA_BOARDS; do fi_assert "$W/$b/usr/libexec/ga-firewall-gate" "$b" "$b"; done
# green twin: an nft that accepts the load must report ruleset_loaded=true (a check that can go green)
d="$W/fi-ihost"; printf '#!/bin/sh\ncase "$1" in -f) exit 0 ;; list) exit 1 ;; *) exit 0 ;; esac\n' > "$d/bin/nft"; rm -f "$d/share/ga-firewall-status.json"
env PATH="$d/bin:$PATH" GA_BOARD_CONF="$d/none" sh "$d/gate" >/dev/null 2>&1
grep -q '"ruleset_loaded": true' "$d/share/ga-firewall-status.json" 2>/dev/null && grep -q '"source": "default"' "$d/share/ga-firewall-status.json" \
  && ok "load success: status JSON ruleset_loaded=true / source=default" || no "load success: status JSON wrong"
# must-flag: the SAME assertions, run against a gate whose loud-failure path is removed, must go red
cp "$W/ihost/usr/libexec/ga-firewall-gate" "$W/quiet-gate"
sed -i -e 's/^log_err() {.*$/log_err() { :; }/' -e 's/write_status false load-failed false/:/' "$W/quiet-gate"
cmp -s "$W/quiet-gate" "$W/ihost/usr/libexec/ga-firewall-gate" && no "fixture quiet-gate changed nothing" || {
  inject "$W/quiet-gate" quiet
  if [ "$FI_RC" = 0 ] && ! grep -q 'load-failed' <<<"$FI_STATUS" && ! grep -q 'UNFILTERED' <<<"$FI_LOG"; then
    ok "MUST-FLAG a gate with the loud-failure path removed (no load-failed status, no err line) -> assertions above would be red"
  else no "quiet-gate not detected: rc=$FI_RC status=$FI_STATUS"; fi; }

# static: defconfigs select nft and the GA layer overlay; one gate + one unit in the tree
for b in $GA_BOARDS; do
  d="$ROOT/$(ga_board_var DEFCONFIG "$b")"
  grep -q '^BR2_PACKAGE_NFTABLES=y' "$d" && ok "$b defconfig selects BR2_PACKAGE_NFTABLES" || no "$b defconfig lacks BR2_PACKAGE_NFTABLES"
  grep '^BR2_ROOTFS_OVERLAY=' "$d" | grep -q 'BR2_EXTERNAL_GA_HAOS_PATH)/rootfs-overlay' && ok "$b defconfig takes the GA-layer overlay" || no "$b defconfig lacks the GA-layer overlay"
done
n="$(git -C "$ROOT" ls-files | grep -cE '(^|/)ga-firewall(-gate|\.service)$')"
[ "$n" = 3 ] && ok "exactly one gate + one unit + one wants link tracked (no per-board copy)" || no "firewall files tracked: $n (expected 3: gate, unit, wants link)"

[ "$ran" -ge 25 ] || { echo "FAIL: only $ran cases ran (floor 25)"; exit 1; }
echo "$ran cases ran, $bad failed"; exit $((bad>0))
