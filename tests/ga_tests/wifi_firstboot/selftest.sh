#!/bin/sh
# Host-side self-test for the WiFi first-boot fixes (no device needed):
#   WFB-1x  GreenAutarky-Install template ships powersave=2 AND still takes the PSK
#   WFB-2x  ga-wlan0-powersave-assert never re-activates, defers while activating
#   WFB-3x  50-ga.conf [connection-wifi-defaults] holds only keys NM 1.50 reads
# Every check reads the LIVE files of the tree (no copies of patterns/values).
# Expected key allowlist (WFB-30) is a PINNED constant taken from NM 1.50.2
# (src/core/devices/wifi/nm-device-wifi.c + man/NetworkManager.conf), not derived
# from the file under test.
# shellcheck disable=SC1090,SC2016,SC2034
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXT="$ROOT/buildroot-external"
IH="$ROOT/buildroot-ihost"
OVL="$EXT/rootfs-overlay"
ASSERT="$IH/rootfs-overlay/usr/sbin/ga-wlan0-powersave-assert"
NMC="$IH/rootfs-overlay/usr/share/ga-wifi/GreenAutarky-Install.nmconnection"
CONF="$OVL/etc/NetworkManager/NetworkManager.conf"
PSKSCRIPT="$IH/board/sonoff/ihost/post-build.d/85-wifi-install-psk.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0; PASSES=0
ck() { # name, command...
    _n="$1"; shift
    if "$@" >/dev/null 2>&1; then PASSES=$((PASSES+1)); echo "PASS $_n"; else FAILS=$((FAILS+1)); echo "FAIL $_n"; fi
}

# ── WFB-1x: template + PSK injection ────────────────────────────────────────
ck WFB-10 test -f "$NMC"
ck WFB-11 sh -c "awk '/^\\[/{s=\$0} s==\"[wifi]\" && /^powersave=2\$/{f=1} END{exit !f}' '$NMC'"
ck WFB-12 grep -q '^psk=__WIFI_INSTALL_PSK__$' "$NMC"
mkdir -p "$T/tgt/usr/share/ga-wifi"; cp "$NMC" "$T/tgt/usr/share/ga-wifi/"
printf 'fixture-psk-not-real\n' > "$T/psk"
WIFI_INSTALL_PSK_FILE="$T/psk" bash "$PSKSCRIPT" "$T/tgt" >/dev/null 2>&1
BUILT="$T/tgt/usr/share/ga-wifi/GreenAutarky-Install.nmconnection"
ck WFB-13 grep -q '^psk=fixture-psk-not-real$' "$BUILT"
ck WFB-14 sh -c "awk '/^\\[/{s=\$0} s==\"[wifi]\" && /^powersave=2\$/{f=1} END{exit !f}' '$BUILT'"
ck WFB-15 sh -c "! grep -q __WIFI_INSTALL_PSK__ '$BUILT'"

# ── WFB-2x: assert ──────────────────────────────────────────────────────────
mk_nm() { # $1 profile powersave, $2 conn state  -> fake nmcli logging to $T/nm.log
    cat > "$T/nmcli" <<NM
#!/bin/sh
echo "\$*" >> "$T/nm.log"
case "\$*" in
  *"-f NAME,DEVICE connection show --active"*) echo "inst:wlan0" ;;
  *"-g GENERAL.STATE connection show"*) echo "$2" ;;
  *"-f 802-11-wireless.powersave connection show"*) echo "802-11-wireless.powersave:$1" ;;
esac
NM
    chmod +x "$T/nmcli"; : > "$T/nm.log"
}
mk_iw() { # $1 = off|on ; get -> "Power save: $1"
    cat > "$T/iw" <<IW
#!/bin/sh
echo "\$*" >> "$T/iw.log"
case "\$*" in *"get power_save"*) echo "Power save: $1" ;; esac
IW
    chmod +x "$T/iw"; : > "$T/iw.log"
}
mk_nmbin() { # $1 = global wifi.powersave value or "" ; fake NetworkManager --print-config
    printf '#!/bin/sh\necho "[main]"\necho "[connection-wifi-defaults]"\n[ -n "%s" ] && echo "wifi.powersave=%s"\nexit 0\n' "$1" "$1" > "$T/NetworkManager"
    chmod +x "$T/NetworkManager"
}
mk_nmbin 2
run_assert() { ( logger() { echo "$*" >> "$T/log"; }; export GA_PSAVE_TEST=1 GA_PSAVE_NM="$T/NetworkManager" GA_PSAVE_NMCLI="$T/nmcli" GA_PSAVE_IW="${IWOVR:-$T/iw}" GA_PSAVE_WAIT=0; . "$ASSERT"; assert_once ) 2>/dev/null; }

# must-pass: profile default + global 2 -> no action at all (even if iw says on)
mk_nm default activated; mk_iw on; R="$(run_assert)"
ck WFB-29 test "$R" = ok
ck WFB-29b sh -c "! grep -q 'connection modify\\|connection up' '$T/nm.log' && ! grep -q 'set power_save' '$T/iw.log'"
mk_nmbin ""
mk_nm default activated; mk_iw on;  R="$(run_assert)"
ck WFB-20 test "$R" = fixed
ck WFB-21 sh -c "! grep -q 'connection up' '$T/nm.log'"          # no re-activation
ck WFB-22 grep -q 'connection modify inst 802-11-wireless.powersave 2' "$T/nm.log"
ck WFB-23 grep -q 'dev wlan0 set power_save off' "$T/iw.log"      # applied without deauth
mk_nmbin ""; mk_nm default activating; mk_iw on; R="$(run_assert)"
ck WFB-24 test "$R" = deferred
ck WFB-25 sh -c "! grep -q 'connection modify\\|connection up' '$T/nm.log'"
mk_nmbin ""; mk_nm default activated; mk_iw off; R="$(run_assert)"
ck WFB-26 test "$R" = ok                                           # conf.d default in effect
ck WFB-27 sh -c "! grep -q 'connection modify\\|connection up' '$T/nm.log'"
mk_nmbin ""; mk_nm 2 activated; mk_iw on; R="$(run_assert)"
ck WFB-28 test "$R" = ok

# F1: iw ABSENT (not faked) — must not claim a live disable
IWOVR=/nonexistent/iw; export IWOVR
mk_nmbin ""; mk_nm 1 activated; : > "$T/log"; R="$(run_assert)"
ck WFB-70 test "$R" = pending-next-activation
ck WFB-71 grep -q 'connection modify inst 802-11-wireless.powersave 2' "$T/nm.log"
ck WFB-72 grep -q 'live disable unavailable' "$T/log"
ck WFB-73 sh -c "! grep -q 'switched the driver off' '$T/log'"
mk_nmbin 2; mk_nm default activated; R="$(run_assert)"; ck WFB-74 test "$R" = ok   # still no action
unset IWOVR
ck WFB-75 grep -q '^BR2_PACKAGE_IW=y$' "$IH/configs/ga_ihost_full_defconfig"

# F2: global_powersave loud on empty, and parses REAL NM output
mk_nmbin ""; mk_nm default activated; mk_iw off; : > "$T/log"; R="$(run_assert)"
ck WFB-76 grep -q 'cannot read the global wifi.powersave' "$T/log"
FIX="$ROOT/tests/ga_tests/wifi_firstboot/nm-print-config.1.50.2.txt"
printf '#!/bin/sh\ncat "%s"\n' "$FIX" > "$T/nm_fixture"; chmod +x "$T/nm_fixture"
gp() { ( GA_PSAVE_TEST=1; . "$ASSERT"; NMBIN="$1"; IFACE=wlan0; global_powersave ) 2>/dev/null; }
ck WFB-77 test "$(gp "$T/nm_fixture")" = 2
# a first [connection*] section that does NOT apply to wifi must not win
printf '#!/bin/sh\nprintf "[connection-eth]\\nmatch-device=type:ethernet\\nwifi.powersave=3\\n[connection-wifi-defaults]\\nmatch-device=type:wifi\\nwifi.powersave=2\\n[connection]\\nwifi.powersave=1\\n"\n' > "$T/nm_multi"; chmod +x "$T/nm_multi"
ck WFB-78 test "$(gp "$T/nm_multi")" = 2
# live binary (this box only: needs the ihost build tree + qemu-arm); CI prints SKIP
NMB=/home/user/build16/out-ihost
if command -v qemu-arm >/dev/null 2>&1 && [ -x "$NMB/target/usr/sbin/NetworkManager" ]; then
    mkdir -p "$T/nmcfg"; cp "$CONF" "$T/nmcfg/50-ga.conf"; printf '[main]\nplugins=keyfile\n' > "$T/nmcfg/NetworkManager.conf"
    printf '#!/bin/sh\nexec qemu-arm -L %s/target %s/target/usr/sbin/NetworkManager --config %s/NetworkManager.conf --config-dir %s --print-config\n' "$NMB" "$NMB" "$T/nmcfg" "$T/nmcfg" > "$T/nm_real"; chmod +x "$T/nm_real"
    ck WFB-79 test "$(gp "$T/nm_real")" = 2
else
    echo "SKIP WFB-79 (real NetworkManager 1.50.2 under qemu-arm not available here; fixture WFB-77 holds its captured output)"
fi

# ── WFB-3x: 50-ga.conf ──────────────────────────────────────────────────────
KEYS="$(awk '/^\[/{s=$0; next} s=="[connection-wifi-defaults]" && /^[A-Za-z]/{sub(/=.*/,""); print}' "$CONF")"
ck WFB-30 test -n "$KEYS"                                          # fail closed on zero
BAD=""; for k in $KEYS; do case "$k" in match-device|stop-match|wifi.powersave|wifi.cloned-mac-address) ;; *) BAD="$BAD $k";; esac; done
ck WFB-31 test -z "$BAD"
ck WFB-32 grep -q '^wifi.powersave=2$' "$CONF"
ck WFB-33 grep -q '^match-device=type:wifi$' "$CONF"


TOTAL=$((PASSES+FAILS))
echo "wifi_firstboot: $PASSES/$TOTAL passed"
[ "$TOTAL" -gt 0 ] && [ "$FAILS" -eq 0 ]
