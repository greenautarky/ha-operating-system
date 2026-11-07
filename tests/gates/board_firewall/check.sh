#!/bin/bash
# board_firewall/check.sh BOARD TARGET_DIR -- the host firewall is IN the built image of BOARD and its
# rendered ruleset keeps the add-on ports (InfluxDB 8086/8088, ...) closed to the customer LAN.
# Odoo #1591. ONE shared definition (buildroot-external ga-firewall-gate + ga-firewall.service); a board
# supplies only its NIC names (usr/share/ga-board.conf). This check reads the TARGET tree: the unit, the
# wants link, the gate, nft, the board file -- and RENDERS the ruleset by running the target's own gate.
# Expected values below are pinned constants, never derived from the tree under test.
# Output: "PASS id msg" / "FAIL id msg" lines; exit = number of FAILs; zero checks = FAIL.
set -u
BOARD="${1:?board}"; T="${2:?target dir}"
# pinned policy: the only TCP ports the LAN may reach (sshd for operator certificates, HA UI)
WANT_PORTS="22222, 80, 8123"
case "$BOARD" in
  ihost)   WANT_IFACES='"eth0", "wlan0"' ;;
  dsgw210) WANT_IFACES='"end0", "wlan0"' ;;
  *) echo "FAIL FWB-00 unknown board '$BOARD' (add its pinned LAN interfaces here)"; exit 1 ;;
esac
n=0; f=0
P() { n=$((n+1)); echo "PASS $1 $2"; }
F() { n=$((n+1)); f=$((f+1)); echo "FAIL $1 $2"; }
chk() { if eval "$3"; then P "$1" "$2"; else F "$1" "$2"; fi; }
[ -d "$T" ] || { echo "FAIL FWB-00 target dir '$T' missing"; exit 1; }

UNIT="$T/etc/systemd/system/ga-firewall.service"
WANTS="$T/etc/systemd/system/multi-user.target.wants/ga-firewall.service"
GATE="$T/usr/libexec/ga-firewall-gate"
chk FWB-01 "$BOARD: ga-firewall.service is in the image" '[ -f "$UNIT" ]'
chk FWB-02 "$BOARD: the unit is ENABLED (multi-user wants link resolves to it)" \
  '[ -L "$WANTS" ] && [ "$(readlink -f "$WANTS")" = "$(readlink -f "$UNIT")" ]'
chk FWB-03 "$BOARD: the unit runs the gate and the gate is executable" \
  'grep -q "^ExecStart=/usr/libexec/ga-firewall-gate$" "$UNIT" 2>/dev/null && [ -x "$GATE" ]'
chk FWB-04 "$BOARD: nft is in the image (the gate fails open without it)" \
  '[ -e "$T/usr/sbin/nft" ] || [ -e "$T/usr/bin/nft" ] || [ -e "$T/sbin/nft" ]'
chk FWB-05 "$BOARD: no off-marker is baked into the image" '[ ! -e "$T/mnt/boot/ga-firewall-off" ]'

# --- render the ruleset with the target's gate; nft is a stub that keeps the file it is asked to load
W="$(mktemp -d "${TMPDIR:-/tmp}/fwb-XXXXXX")"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/nft" <<'S'
#!/bin/sh
[ "$1" = "-f" ] && { cp "$2" "$NFT_CAPTURE"; exit 0; }
exit 1
S
chmod +x "$W/bin/nft"
CONF="$T/usr/share/ga-board.conf"; [ -r "$CONF" ] || CONF="$W/none.conf"
if [ -x "$GATE" ]; then
  env -u GA_LAN_IFACES PATH="$W/bin:$PATH" NFT_CAPTURE="$W/rules" GA_BOARD_CONF="$CONF" sh "$GATE" >/dev/null 2>&1
fi
R="$W/rules"
if [ ! -s "$R" ]; then
  F FWB-10 "$BOARD: the gate rendered no ruleset"
else
  chk FWB-10 "$BOARD: the gate rendered a ruleset" 'grep -q "^table inet ga_firewall {" "$R"'
  chk FWB-11 "$BOARD: LAN accept = exactly the pinned interfaces and ports ($WANT_IFACES / $WANT_PORTS)" \
    'grep -qxF "    iifname { $WANT_IFACES } tcp dport { $WANT_PORTS } accept" "$R" && ! grep -o "tcp dport {[^}]*}" "$R" | grep -oE "[0-9]+" | grep -qvE "^(22222|80|8123)$"'
  chk FWB-12 "$BOARD: everything else from those interfaces is dropped (input and forwarded DNAT)" \
    'grep -qxF "    iifname { $WANT_IFACES } drop" "$R" && grep -qxF "    iifname { $WANT_IFACES } ct status dnat drop" "$R"'
  chk FWB-13 "$BOARD: loopback and the mesh are accepted" \
    'grep -qxF "    iif \"lo\" accept" "$R" && grep -qF "iifname { \"wt0\", \"tailscale0\" } accept" "$R"'
  chk FWB-14 "$BOARD: no add-on port (InfluxDB 8086/8088, MQTT 1883/8883, ...) is accepted anywhere" \
    '! grep -E "tcp dport" "$R" | grep -qE "(^|[^0-9])(8086|8088|1883|8883|3000|5432|8099)([^0-9]|$)"'
  chk FWB-15 "$BOARD: the chain policy stays accept (a truncated load fails OPEN, never locks out)" \
    '[ "$(grep -c "policy accept;" "$R")" = 2 ]'
fi
[ "$n" -ge 10 ] || { echo "FAIL FWB-99 only $n checks ran"; exit 1; }
exit "$f"
