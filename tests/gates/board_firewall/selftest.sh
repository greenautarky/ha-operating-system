#!/bin/bash
# board_firewall/selftest.sh -- red/green proof of check.sh (Odoo #1591, #1647), 1.5 line (iHost only).
# Reads the LIVE definition: the image tree is assembled from the iHost overlay (buildroot-ihost/rootfs-overlay,
# which carries the unit, the wants link and the gate); nft comes from the defconfig package switch.
#   must-pass: the iHost overlay as it is.
#   must-flag: no enable link, no unit, a gate that opens InfluxDB, a gate without the LAN drop rule, no nft,
#              no default drop (uplink open), the modem listed as a LAN interface, no container-bridge accept
#              (would drop veth traffic under the default drop), no ct established accept (own replies dropped).
#   failure injection (rule 53, the path that only runs on the event it reports): the LIVE gate run with an nft that
#              rejects `-f` must exit 0, publish ruleset_loaded=false / source=load-failed, log at err priority.
#   static:    the built defconfig selects BR2_PACKAGE_NFTABLES; exactly one gate + one unit + one wants link tracked.
# Zero cases = FAIL. Offline.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../../.." && pwd)"
CHECK="$HERE/check.sh"
OVL="$ROOT/buildroot-ihost/rootfs-overlay"
W="$(mktemp -d "${TMPDIR:-/tmp}/fwb-st-XXXXXX")"; trap 'rm -rf "$W"' EXIT
ran=0; bad=0
ok()  { ran=$((ran+1)); echo "  ok    $1"; }
no()  { ran=$((ran+1)); bad=$((bad+1)); echo "  FAIL  $1"; }

mkdir -p "$W/ihost"; cp -a "$OVL/." "$W/ihost/"
mkdir -p "$W/ihost/usr/sbin"; : > "$W/ihost/usr/sbin/nft"   # the package, not the overlay (static check below)

must_pass() { local out rc; out="$("$CHECK" "$1" "$2" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && ! grep -q '^FAIL' <<<"$out"; then ok "$3 ($(grep -c '^PASS' <<<"$out") checks)"; else no "$3 -- $(grep '^FAIL' <<<"$out" | head -n 3 | tr '\n' '|')"; fi; }
must_flag() { local out rc; out="$("$CHECK" "$1" "$2" 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && grep -q "^FAIL $3 " <<<"$out"; then ok "$4 (red on $3)"; else no "$4 -- expected FAIL $3, got rc=$rc: $(grep '^FAIL' <<<"$out" | head -n 3 | tr '\n' '|')"; fi; }
mutant() {  # <name> <sed-expr> <file under tree> ; copies the good tree, applies sed, refuses a no-op mutation
  cp -a "$W/ihost" "$W/$1"; chmod -R u+w "$W/$1"
  sed -i "$2" "$W/$1/$3"
  if cmp -s "$W/$1/$3" "$W/ihost/$3"; then no "fixture $1 changed nothing"; return 1; fi
}
GATEF=usr/libexec/ga-firewall-gate

must_pass ihost "$W/ihost" "MUST-PASS the iHost overlay as it is"

cp -a "$W/ihost" "$W/nowants"; rm -f "$W/nowants/etc/systemd/system/multi-user.target.wants/ga-firewall.service"
must_flag ihost "$W/nowants" FWB-02 "MUST-FLAG unit present but not enabled"

cp -a "$W/ihost" "$W/nounit"; rm -f "$W/nounit/etc/systemd/system/ga-firewall.service"
must_flag ihost "$W/nounit" FWB-01 "MUST-FLAG no unit in the image"

mutant influx "s/^HOST_ALLOW_TCP='22222'/HOST_ALLOW_TCP='22222, 8086'/" $GATEF \
  && must_flag ihost "$W/influx" FWB-14 "MUST-FLAG a gate that opens InfluxDB 8086 to the LAN"

mutant nodrop '/accept$/!{/iifname { \$LAN_IFACES } drop/d}' $GATEF \
  && must_flag ihost "$W/nodrop" FWB-12 "MUST-FLAG a gate without the LAN drop rule"

cp -a "$W/ihost" "$W/nonft"; rm -f "$W/nonft/usr/sbin/nft"
must_flag ihost "$W/nonft" FWB-04 "MUST-FLAG an image without nft"

# --- Odoo #1647: the uplink must not be reachable (default-deny on every non-trusted interface)
mutant nocatch '/Default deny for every other interface/,+1d' $GATEF \
  && must_flag ihost "$W/nocatch" FWB-16 "MUST-FLAG an uplink interface not covered (no default drop: usb0/ppp0 reach the add-on ports)"

mutant ppplan "s/GA_LAN_IFACES:-eth0 wlan0/GA_LAN_IFACES:-eth0 wlan0 ppp0/" $GATEF \
  && must_flag ihost "$W/ppplan" FWB-16 "MUST-FLAG an add-on/ssh port reachable via ppp0 (modem listed as LAN)"

mutant nobridge '/iifname ."veth/d' $GATEF \
  && must_flag ihost "$W/nobridge" FWB-17 "MUST-FLAG a gate that would drop container (veth) traffic under the default drop"

mutant noest '/echo "    ct state established,related accept"/d' $GATEF \
  && must_flag ihost "$W/noest" FWB-18 "MUST-FLAG a gate that drops replies to the device's own connections"

mutant nomesh 's/iifname { \\"wt0\\", \\"tailscale0\\" } accept/iifname { \\"tailscale0\\" } accept/' $GATEF \
  && must_flag ihost "$W/nomesh" FWB-13 "MUST-FLAG a gate that no longer accepts the NetBird mesh (wt0): lockout"

# --- failure injection: the LIVE gate with an nft that rejects the load. Paths are rewritten on a COPY
# (the gate hardcodes /mnt/data, /mnt/boot, /usr/libexec); the rewrite itself is asserted.
G="$W/gate-copy"; mkdir -p "$W/fi/bin" "$W/fi/share" "$W/fi/boot"
sed -e "s#^SHARE_DIR=.*#SHARE_DIR=$W/fi/share#" -e "s#^OFF_MARKER=.*#OFF_MARKER=$W/fi/boot/ga-firewall-off#" \
    -e "s#/usr/libexec/ga-share-publish#$W/fi/bin/ga-share-publish#" "$OVL/$GATEF" > "$G"
if grep -q "^SHARE_DIR=$W/fi/share" "$G" && grep -q "$W/fi/bin/ga-share-publish" "$G" && grep -q "^OFF_MARKER=$W/fi/boot" "$G"; then
  ok "failure-injection copy of the LIVE gate has its three paths rewritten"
else no "failure-injection path rewrite did not apply (gate text changed?)"; fi
printf '#!/bin/sh\ncat > "$1"\n' > "$W/fi/bin/ga-share-publish"   # same contract as the real helper: path, mode, stdin
printf '#!/bin/sh\necho "$@" >> "%s/logger.out"\n' "$W/fi" > "$W/fi/bin/logger"
printf '#!/bin/sh\ncase "$1" in -f) echo "Error: injected load failure" >&2; exit 1 ;; list) exit 1 ;; *) exit 0 ;; esac\n' > "$W/fi/bin/nft"
chmod +x "$W/fi/bin/"*
env PATH="$W/fi/bin:$PATH" GA_BOARD_CONF="$W/none" sh "$G" >"$W/fi/out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "load failure: gate exits 0 (fail-open by design, never wedges boot)" || no "load failure: gate exit $rc"
S="$W/fi/share/ga-firewall-status.json"
grep -q '"ruleset_loaded": false' "$S" 2>/dev/null && grep -q '"source": "load-failed"' "$S" && grep -q '"enabled": false' "$S" \
  && ok "load failure: status JSON says ruleset_loaded=false / source=load-failed / enabled=false (what ga_manager's firewall healthcheck reads)" \
  || no "load failure: status JSON wrong: $(cat "$S" 2>/dev/null | tr -d '\n')"
grep -q 'daemon.err' "$W/fi/logger.out" 2>/dev/null && grep -q 'UNFILTERED' "$W/fi/logger.out" \
  && ok "load failure: journal line at daemon.err priority naming UNFILTERED" || no "load failure: no err-level log line"
# and the green twin: an nft that accepts the load must report ruleset_loaded=true (a check that can go green, too)
printf '#!/bin/sh\ncase "$1" in -f) exit 0 ;; list) exit 1 ;; *) exit 0 ;; esac\n' > "$W/fi/bin/nft"
rm -f "$S"; env PATH="$W/fi/bin:$PATH" GA_BOARD_CONF="$W/none" sh "$G" >/dev/null 2>&1
grep -q '"ruleset_loaded": true' "$S" 2>/dev/null && grep -q '"source": "default"' "$S" \
  && ok "load success: status JSON says ruleset_loaded=true / source=default" || no "load success: status JSON wrong: $(cat "$S" 2>/dev/null | tr -d '\n')"

# --- static: the defconfig the bake uses selects nft; one gate + one unit + one wants link in the tree
d="$ROOT/buildroot-ihost/configs/ga_ihost_full_defconfig"
grep -q '^BR2_PACKAGE_NFTABLES=y' "$d" && ok "ga_ihost_full_defconfig selects BR2_PACKAGE_NFTABLES" || no "ga_ihost_full_defconfig lacks BR2_PACKAGE_NFTABLES"
n="$(git -C "$ROOT" ls-files | grep -cE '(^|/)ga-firewall(-gate|\.service)$')"
[ "$n" = 3 ] && ok "exactly one gate + one unit + one wants link tracked" || no "firewall files tracked: $n (expected 3: gate, unit, wants link)"

[ "$ran" -ge 16 ] || { echo "FAIL: only $ran cases ran (floor 16)"; exit 1; }
echo "$ran cases ran, $bad failed"; exit $((bad>0))
