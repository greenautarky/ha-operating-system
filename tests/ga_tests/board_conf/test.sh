#!/bin/bash
# board_conf — the per-board values of the shared GA scripts (WP4b).
#
# The firewall, the Ethernet policy, the connectivity recorder and the USB
# authorization are shipped to every board from the GA layer. What differs per
# board is DATA: interface names (/usr/share/ga-board.conf) and, for USB, port
# paths (/usr/share/ga-usb-port-allowlist). This suite runs the REAL scripts
# against the REAL board files and asserts the outcome:
#
#   * a board without the files (the iHost) gets exactly the old behaviour
#     (golden: the ruleset the firewall rendered before the change);
#   * the DSGW-210's files give end0/wlan0, end0, "end0 wlan0 ppp0", and an
#     internal-port allowlist that does NOT open an external port to an adapter
#     with a known ID (the case a VID:PID rule cannot handle);
#   * each assertion is also run on a mutated input and must flip (red proof).
#
# Host-side: sh + coreutils; commands that reach the system are stubs.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GA="$ROOT/buildroot-external/rootfs-overlay"
DSGW="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay"
BOARD_CONF="$DSGW/usr/share/ga-board.conf"
PORTS="$DSGW/usr/share/ga-usb-port-allowlist"
W="$(mktemp -d -t board-conf-XXXXXX)"
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }
ok()   { if eval "$2"; then PASS "$1"; else FAIL "$1" "$3"; fi; }

echo ""; echo "=== board_conf: per-board values of the shared scripts ==="

# The inputs must exist: a suite that runs over nothing proves nothing.
for f in "$GA/usr/libexec/ga-firewall-gate" "$GA/usr/sbin/ga-manage-ethernet" \
         "$GA/usr/sbin/ga-connectivity-recorder" "$GA/usr/libexec/ga-usb-authorize" \
         "$BOARD_CONF" "$PORTS"; do
  [ -r "$f" ] || { echo "FATAL: input missing: $f"; exit 1; }
done

# --- stubs -------------------------------------------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/nft" <<'EOF'
#!/bin/sh
# nft list table ... -> absent (exit 1); nft -f FILE -> keep the ruleset.
[ "$1" = "-f" ] && cp "$2" "$NFT_CAPTURE"
[ "$1" = "-f" ] && exit 0
exit 1
EOF
cat > "$W/bin/nmcli" <<'EOF'
#!/bin/sh
echo "$*" >> "$NMCLI_LOG"
case "$*" in
  "-t -f NAME,DEVICE connection show") printf 'wired-lan:eth0\nwired-end:end0\n' ;;
esac
exit 0
EOF
cat > "$W/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$W/bin/"*

# --- 1. firewall ---------------------------------------------------------------
render_fw() {  # <conf path or ''>  -> ruleset on stdout
  rm -f "$W/rules"
  env -u GA_LAN_IFACES PATH="$W/bin:$PATH" NFT_CAPTURE="$W/rules" \
      GA_BOARD_CONF="${1:-$W/none.conf}" \
      sh "$GA/usr/libexec/ga-firewall-gate" >/dev/null 2>&1
  cat "$W/rules" 2>/dev/null
}
GOLDEN_IIF='iifname { "eth0", "wlan0" } tcp dport { 22222, 80, 8123 } accept'
r="$(render_fw '')"
ok "BC-01 no board file: the ruleset is the iHost one (golden line)" \
   'printf "%s\n" "$r" | grep -qxF "    $GOLDEN_IIF"' "default ruleset changed"
r="$(render_fw "$BOARD_CONF")"
ok "BC-02 DSGW board file: LAN is end0 and wlan0, in the accept and the drop rule" \
   'printf "%s\n" "$r" | grep -qxF "    iifname { \"end0\", \"wlan0\" } tcp dport { 22222, 80, 8123 } accept" && printf "%s\n" "$r" | grep -qxF "    iifname { \"end0\", \"wlan0\" } drop"' "rules: $(printf '%s' "$r" | grep iifname | head -3 | tr '\n' ';')"
ok "BC-03 DSGW ruleset never names eth0" '! printf "%s\n" "$r" | grep -q eth0' "eth0 present"
ok "BC-04 DSGW ruleset keeps the invariant: loopback and mesh accepted first" \
   'printf "%s\n" "$r" | grep -qF "iifname { \"wt0\", \"tailscale0\" } accept"' "mesh accept missing"
# red proof: a board file naming another interface must change the ruleset
printf ': "${GA_LAN_IFACES:=lan9}"\n' > "$W/mut.conf"
r2="$(render_fw "$W/mut.conf")"
ok "BC-05 (red proof) a different board value flips the ruleset" \
   'printf "%s\n" "$r2" | grep -qF "iifname { \"lan9\" } drop"' "board value not used"

# --- 2. Ethernet policy --------------------------------------------------------
eth_conn() {  # <conf or ''> -> the NM connection `disable` takes down
  : > "$W/nm.log"
  env -u GA_ETH_IFACE PATH="$W/bin:$PATH" NMCLI_LOG="$W/nm.log" \
      GA_BOARD_CONF="${1:-$W/none.conf}" GA_SHARE_DIR="$W/nosuch" GA_ENV_FILE="$W/env" \
      sh "$GA/usr/sbin/ga-manage-ethernet" disable >/dev/null 2>&1
  sed -n 's/^connection down //p' "$W/nm.log" | head -1
}
ok "BC-10 no board file: the Ethernet policy acts on eth0's profile" \
   '[ "$(eth_conn "")" = wired-lan ]' "got: $(eth_conn '')"
ok "BC-11 DSGW board file: the Ethernet policy acts on end0's profile" \
   '[ "$(eth_conn "$BOARD_CONF")" = wired-end ]' "got: $(eth_conn "$BOARD_CONF")"

# --- 3. connectivity recorder --------------------------------------------------
rec_ifaces() {  # <conf or ''> [env GA_CR_IFACES]
  env -u GA_CR_IFACES ${2:+GA_CR_IFACES="$2"} GA_CR_TEST=1 GA_BOARD_CONF="${1:-$W/none.conf}" \
      sh -c '. "$1"; echo "$IFACES"' _ "$GA/usr/sbin/ga-connectivity-recorder" 2>/dev/null
}
ok "BC-20 no board file: rungs are eth0 wlan0 usb0" '[ "$(rec_ifaces "")" = "eth0 wlan0 usb0" ]' "got: $(rec_ifaces '')"
ok "BC-21 DSGW board file: rungs are end0 wlan0 ppp0" '[ "$(rec_ifaces "$BOARD_CONF")" = "end0 wlan0 ppp0" ]' "got: $(rec_ifaces "$BOARD_CONF")"
ok "BC-22 an explicit GA_CR_IFACES still wins over the board file" '[ "$(rec_ifaces "$BOARD_CONF" "x0")" = x0 ]' "got: $(rec_ifaces "$BOARD_CONF" x0)"

# --- 4. USB authorization ------------------------------------------------------
usb() {  # <ports file or ''> <allowlist file> <syspath> <vid> <pid>
  GA_USB_TEST=1 GA_USB_PORT_ALLOWLIST="${1:-$W/none}" GA_USB_ALLOWLIST="$2" PATH="$W/bin:$PATH" \
    sh "$GA/usr/libexec/ga-usb-authorize" "$3" "$4" "$5" 2>/dev/null
}
: > "$W/empty-allow"
for p in 3-1 3-1.1 3-1.2 3-1.3; do
  ok "BC-30 DSGW: internal port $p is authorized" \
     '[ "$(usb "$PORTS" "$W/empty-allow" "/sys/devices/platform/x/usb3/3-1/$p" 1a86 7523)" = "authorize port $p" ]' "got: $(usb "$PORTS" "$W/empty-allow" "/sys/x/$p" 1a86 7523)"
done
ok "BC-31 DSGW: an external port with the SAME VID:PID as the on-board radios stays closed" \
   '[ "$(usb "$PORTS" "$W/empty-allow" /sys/devices/platform/x/usb3/3-1/3-1.4 1a86 7523)" = "deny 1a86:7523" ]' "got: $(usb "$PORTS" "$W/empty-allow" /sys/x/3-1.4 1a86 7523)"
ok "BC-32 DSGW: a device on another bus (usb1) stays closed" \
   '[ "$(usb "$PORTS" "$W/empty-allow" /sys/devices/platform/x/usb1/1-1 0781 5567)" = "deny 0781:5567" ]' "got: $(usb "$PORTS" "$W/empty-allow" /sys/x/1-1 0781 5567)"
ok "BC-33 DSGW: 3-1.1 is not matched as a prefix of 3-1.10 or 3-1.12" \
   '[ "$(usb "$PORTS" "$W/empty-allow" /sys/x/3-1.10 1a86 7523)" = "deny 1a86:7523" ] && [ "$(usb "$PORTS" "$W/empty-allow" /sys/x/3-1.12 1a86 7523)" = "deny 1a86:7523" ]' "prefix match"
ok "BC-34 no ports file (the iHost): nothing is authorized by port" \
   '[ "$(usb "" "$W/empty-allow" /sys/x/3-1.1 1a86 7523)" = "deny 1a86:7523" ]' "got: $(usb '' "$W/empty-allow" /sys/x/3-1.1 1a86 7523)"
ok "BC-35 (red proof) a ports file without 3-1.1 closes the modem port" \
   'grep -v "^3-1.1$" "$PORTS" > "$W/ports-mut"; [ "$(usb "$W/ports-mut" "$W/empty-allow" /sys/x/3-1.1 2c7c 0296)" = "deny 2c7c:0296" ]' "mutation did not flip"
# The VID:PID rule next to the port rule, and with several entries (the old
# helper stripped the newlines and matched only a single-entry list).
printf '# bench\n1A86:55D3\n0781:5567\n' > "$W/two-allow"
ok "BC-36 VID:PID list with several entries: every entry matches (first, last)" \
   '[ "$(usb "" "$W/two-allow" /sys/x/1-1 1a86 55d3)" = "authorize 1a86:55d3" ] && [ "$(usb "" "$W/two-allow" /sys/x/1-1 0781 5567)" = "authorize 0781:5567" ]' "multi-entry list broken"
ok "BC-37 VID:PID list: an unlisted ID is denied" \
   '[ "$(usb "" "$W/two-allow" /sys/x/1-1 dead beef)" = "deny dead:beef" ]' "unlisted ID authorized"

# --- 5. the DSGW boot script closes the host ports ------------------------------
USH="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/uboot-boot.ush"
ok "BC-40 DSGW boot script sets usbcore.authorized_default=0 and appends it to BOTH slots' bootargs after \${cmdline}" \
   '[ "$(grep -c "rauc.slot=[AB] \${cmdline} \${bootargs_ga}" "$USH")" = 2 ] && grep -q "^setenv bootargs_ga \"usbcore.authorized_default=0\"" "$USH"' "bootargs_ga not wired"
ok "BC-41 DSGW image carries the Ethernet-force marker for provisioning (haos-hook)" \
   'grep -q "ga-ethernet-force" "$ROOT/buildroot-dsgw210/board/dusun/dsgw210/haos-hook.sh"' "marker missing"

echo ""
echo "board_conf: $pass passed, $fail failed"
echo "{\"suite\":\"board_conf\",\"pass\":$pass,\"fail\":$fail,\"skip\":0}"
[ "$fail" -eq 0 ] && [ "$pass" -ge 20 ]
