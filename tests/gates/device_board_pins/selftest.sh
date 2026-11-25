#!/usr/bin/env bash
# The device suites' board-dependent checks (NET-11, reboot -08, FW-27, FEAT-02, ETHF-04, hw_iodomain) on
# an iHost-shaped and a DSGW-210-shaped fixture. LIVE code: whole suites where they run on a host, the
# marked block / the function of the suite where they do not; the firewall rules are rendered by the LIVE
# ga-firewall-gate with each board's own board file. Expected names are literals HERE.
# TREE=<checkout> runs the same scenarios against another tree and prints the verdicts only (before/after).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="${TREE:-$(cd "$HERE/../../.." && pwd)}"; T="$ROOT/tests/ga_tests"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT; mkdir -p "$W/bin"
ran=0; fails=0
v() { # <label> <want> <got>
  if [ -n "${TREE:-}" ]; then echo "$1 = $3"; return; fi
  ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "  ok    $1 -> $3"; else fails=$((fails+1)); echo "  FAIL  $1 -> '$3', wanted $2"; fi; }
verdict() { sed 's/\x1b\[[0-9;]*m//g' "$W/out" | grep -E "^ *(PASS|FAIL|SKIP) +$1:" | head -1 | awk '{print $1}'; }
osr() { printf 'VARIANT_ID=%s\n' "$1" > "$W/os"; }
cat > "$W/bin/nmcli" <<'N'
#!/bin/sh
cat "$NM"
N
chmod +x "$W/bin/nmcli"; export NM="$W/nm"
iface() { case "$1" in ihost) echo eth0 ;; *) echo end0 ;; esac; }

# --- NET-10..12: the marked block of the live suite
net() { # <board> <flag yes|no> <nmcli lines>
  osr "$1"; printf '%b' "$3" > "$W/nm"; if [ "$2" = yes ]; then echo GA_ETHERNET_DISABLED=true > "$W/env"; else : > "$W/env"; fi
  { echo "SCRIPT_DIR='$T/network'; . '$T/lib/test_helpers.sh'"; [ -f "$T/lib/board_pins.sh" ] && echo ". '$T/lib/board_pins.sh'; bp_load \"\$(ga_board)\" || true"
    if grep -q 'BEGIN eth-off' "$T/network/test.sh"; then sed -n '/BEGIN eth-off/,/END eth-off/p' "$T/network/test.sh"
    else sed -n '/^if \[ -f \/mnt\/data\/ga-env.conf \]/,/^fi/p' "$T/network/test.sh" | sed "s#/mnt/data/ga-env.conf#$W/env#g"; fi; } > "$W/net.sh"
  env PATH="$W/bin:$PATH" GA_T_OS_RELEASE="$W/os" GA_NET_GAENV="$W/env" sh "$W/net.sh" > "$W/out" 2>&1; }
for b in ihost dsgw210; do i=$(iface $b)
  net $b yes "$i:unavailable\nwlan0:connected\n"; v "NET-11 $b disabled, $i down" PASS "$(verdict NET-11)"
  net $b yes "$i:connected\nwlan0:connected\n";   v "NET-11 $b disabled but $i connected" FAIL "$(verdict NET-11)"
  net $b yes "wlan0:connected\n";                 v "NET-11 $b $i not in the device list" FAIL "$(verdict NET-11)"
  net $b no "$i:connected\n";                     v "NET-11 $b flag not set" SKIP "$(verdict NET-11)"
  [ -n "${TREE:-}" ] || v "NET-11 $b flag not set says not reached" 1 "$(grep -c 'NET-11.*not reached' "$W/out")"
done
net riscv yes "eth0:unavailable\n"; v "NET-11 unknown board" FAIL "$(verdict NET-11)"

# --- reboot -08: the live function with a stub ssh
reb() { # <board> <flag answer> <nmcli lines>
  osr "$1"; printf '%b' "$3" > "$W/nm"
  { echo 'set -euo pipefail'; [ -f "$T/lib/board_pins.sh" ] && echo ". '$T/lib/board_pins.sh'"
    echo '_p(){ echo "PASS $1"; }; _f(){ echo "FAIL $1"; }; _s(){ echo "SKIP $1"; }'
    echo "ssh_cmd(){ case \"\$1\" in *VARIANT_ID*) sed -n 's/^VARIANT_ID=//p' '$W/os' ;; *GA_ETHERNET_DISABLED*) printf '%s\n' '$2' | grep . ;; *\"grep '^eth0:'\"*) grep '^eth0:' '$W/nm' | cut -d: -f2 ;; *nmcli*) cat '$W/nm' ;; esac; }"
    if grep -q 'BEGIN eth-guard' "$T/reboot/test.sh"; then sed -n '/BEGIN eth-guard/,/END eth-guard/p' "$T/reboot/test.sh"
    else echo 'check_eth_guard() { local test_prefix=$1'; sed -n '/# Ethernet guard applied correctly/,/^}/p' "$T/reboot/test.sh"; fi
    echo 'check_eth_guard RBT'; } > "$W/reb.sh"
  bash "$W/reb.sh" > "$W/out" 2>&1 || true; R=$(awk '/RBT-08/{print $1; exit}' "$W/out"); }
for b in ihost dsgw210; do i=$(iface $b)
  reb $b yes "$i:disconnected\nwlan0:connected\n"; v "reboot-08 $b disabled, $i down" PASS "$R"
  reb $b yes "$i:connected\n";                     v "reboot-08 $b disabled but $i connected" FAIL "$R"
  reb $b yes "wlan0:connected\n";                  v "reboot-08 $b $i not listed" FAIL "$R"
  reb $b no "$i:connected\n";                      v "reboot-08 $b flag not set" SKIP "$R"
  reb $b "" "$i:connected\n";                      v "reboot-08 $b ssh answers nothing" FAIL "$R"
done

# --- FW-27 / FEAT-02: rules rendered by the live gate, through the suites' own check lines
cat > "$W/bin/nft" <<'N'
#!/bin/sh
if [ "$1" = -f ]; then cp "$2" "$CAP"; exit 0; fi
[ "$1 $2" = "list table" ] && [ -n "${SHOW:-}" ] && { cat "$SHOW"; exit 0; }
exit 1
N
printf '#!/bin/sh\nexit 0\n' > "$W/bin/logger"; chmod +x "$W/bin/"*
render() { # <board> -> file; the iHost has no board file
  local c="$W/none"; [ "$1" = dsgw210 ] && c="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/rootfs-overlay/usr/share/ga-board.conf"
  rm -f "$W/cap"; env -u GA_LAN_IFACES PATH="$W/bin:$PATH" CAP="$W/cap" GA_BOARD_CONF="$c" sh "$ROOT/buildroot-external/rootfs-overlay/usr/libexec/ga-firewall-gate" >/dev/null 2>&1; cp "$W/cap" "$W/rules.$1"; }
for b in ihost dsgw210; do render $b || { echo "FATAL: ga-firewall-gate rendered nothing for $b"; exit 1; }; done
fw() { # <image board> <rules file>
  osr "$1"
  { echo "SCRIPT_DIR='$T/firewall'; . '$T/lib/test_helpers.sh'"; [ -f "$T/lib/board_pins.sh" ] && echo ". '$T/lib/board_pins.sh'; bp_load \"\$(ga_board)\" || true"
    echo "fw_chain() { awk -v w=\"chain \$1\" 'index(\$0,w){p=1} p{print} p&&/^  }/{exit}' '$2'; }"
    grep -A1 '"FW-27"' "$T/firewall/test.sh"; grep -A1 '"FEAT-02"' "$T/device_features/test.sh"; } > "$W/fw.sh"
  env PATH="$W/bin:$PATH" SHOW="$2" CAP="$W/x" GA_T_OS_RELEASE="$W/os" sh "$W/fw.sh" > "$W/out" 2>&1; }
for b in ihost dsgw210; do i=$(iface $b); o=dsgw210; [ $b = dsgw210 ] && o=ihost
  fw $b "$W/rules.$b"; v "FW-27 $b own rules" PASS "$(verdict FW-27)"; v "FEAT-02 $b own rules" PASS "$(verdict FEAT-02)"
  fw $b "$W/rules.$o"; v "FW-27 $b with the other board's rules" FAIL "$(verdict FW-27)"; v "FEAT-02 $b with the other board's rules" FAIL "$(verdict FEAT-02)"
  grep -v "\"$i\".*drop" "$W/rules.$b" > "$W/nodrop"; fw $b "$W/nodrop"; v "FW-27 $b drop rule missing" FAIL "$(verdict FW-27)"
  sed 's/ 80,//' "$W/rules.$b" > "$W/no80"; fw $b "$W/no80"; v "FEAT-02 $b :80 not admitted" FAIL "$(verdict FEAT-02)"
done
fw riscv "$W/rules.ihost"; v "FW-27 unknown board" FAIL "$(verdict FW-27)"; v "FEAT-02 unknown board" FAIL "$(verdict FEAT-02)"

# --- ETHF-04: the whole live suite
eth() { # <board> <operstate|-> <source> [consent]
  osr "$1"; rm -rf "$W/net"; mkdir -p "$W/net"; [ "$2" = - ] || { mkdir -p "$W/net/$(iface "$1")"; echo "$2" > "$W/net/$(iface "$1")/operstate"; }
  printf '{ "source": "%s", "boot_marker": "absent", "enabled": true }\n' "$3" > "$W/st"; echo "${4:-}" > "$W/env"
  sed "s#/sys/class/net/eth0#$W/net/eth0#; s# /mnt/data/ga-env.conf# $W/env#" "$T/ethernet_force/test.sh" > "$W/ethf.sh"
  grep -q GA_ETHF_NETDIR "$T/ethernet_force/test.sh" && cp "$T/ethernet_force/test.sh" "$W/ethf.sh"
  sed -i "s#^SCRIPT_DIR=.*#SCRIPT_DIR='$T/ethernet_force'#" "$W/ethf.sh"
  env PATH="$W/bin:$PATH" GA_T_OS_RELEASE="$W/os" GA_T_DATA_ROOT=/nonexistent GA_ETHF_FORCE_BOOT="$W/nomarker" GA_ETHF_STATUS="$W/st" GA_ETHF_BIN=/nonexistent GA_ETHF_NETDIR="$W/net" GA_ETHF_GAENV="$W/env" sh "$W/ethf.sh" > "$W/out" 2>&1; }
for b in ihost dsgw210; do i=$(iface $b)
  eth $b down default;  v "ETHF-04 $b $i down, no consent" PASS "$(verdict ETHF-04)"
  eth $b up default;    v "ETHF-04 $b $i up without consent" FAIL "$(verdict ETHF-04)"
  eth $b up force-config; v "ETHF-04 $b remote override" SKIP "$(verdict ETHF-04)"
  eth $b up default GA_ETHERNET_ENABLED=true; v "ETHF-04 $b consent" SKIP "$(verdict ETHF-04)"
  eth $b - default;     v "ETHF-04 $b $i missing" SKIP "$(verdict ETHF-04)"
  [ -n "${TREE:-}" ] || v "ETHF-04 $b $i missing names it" 1 "$(grep -c "ETHF-04.*not judged.*$i" "$W/out")"
done
eth riscv up default; v "ETHF-04 unknown board" FAIL "$(verdict ETHF-04)"

# --- hw_iodomain: the whole live suite
iod() { # <board> <compatible> <regmap yes|no>
  osr "$1"; mkdir -p "$W/dt"; printf '%s\0' "$2" > "$W/dt/compatible"; rm -f "$W/regs"; [ "$3" = yes ] && cp "$T/hw_iodomain/fixtures/regs-86.txt" "$W/regs"
  env GA_T_OS_RELEASE="$W/os" IOD_DTBASE="$W/dt" IOD_REGMAP="$W/regs" IOD_GRF_REGMAP=/nonexistent IOD_BOOTCFG=/nonexistent IOD_REGSUM=/nonexistent IOD_PINCONF=/nonexistent IOD_NETDIR=/nonexistent IOD_CMDLINE=/dev/null sh "$T/hw_iodomain/test.sh" > "$W/out" 2>&1; }
n() { sed 's/\x1b\[[0-9;]*m//g' "$W/out" | grep -cE "^ *$1 +IOD-"; }
iod dsgw210 dusun,dsgw210 no;     v "IOD dsgw210: absence asserted" PASS "$(verdict IOD-09)"; v "IOD dsgw210: counted skips" 9 "$(n SKIP)"
iod dsgw210 dusun,dsgw210 yes;    v "IOD dsgw210 but the RV1126 register map exists" FAIL "$(verdict IOD-09)"
iod ihost dusun,dsgw210 yes;      v "IOD ihost image on a foreign tree" FAIL "$(verdict IOD-09)"
iod riscv rockchip,x no;          v "IOD unknown board" FAIL "$(verdict IOD-09)"
iod ihost itead,sonoff-ihost yes; v "IOD ihost: the checks run (IOD-01)" PASS "$(verdict IOD-01)"; v "IOD ihost: no board line added" "" "$(verdict IOD-09)"
iod ihost itead,sonoff-ihost no;  v "IOD ihost: unreadable register map" FAIL "$(verdict IOD-01)"
[ -n "${TREE:-}" ] && exit 0
echo "$ran cases, $fails failed"; [ "$ran" -ge 56 ] && [ "$fails" -eq 0 ]
