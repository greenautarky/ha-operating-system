#!/bin/sh
# Host-side self-test for the WiFi first-boot fixes (no device needed):
#   WFB-1x  GreenAutarky-Install template ships powersave=2 AND still takes the PSK
#   WFB-2x  ga-wlan0-powersave-assert never re-activates, defers while activating
#   WFB-3x  50-ga.conf [connection-wifi-defaults] holds only keys NM 1.50 reads
#   WFB-4x  ga-firstboot-noupl-rescue: writes once, bounded, rotated, never on ok
# Every check reads the LIVE files of the tree (no copies of patterns/values).
# Expected key allowlist (WFB-30) is a PINNED constant taken from NM 1.50.2
# (src/core/devices/wifi/nm-device-wifi.c + man/NetworkManager.conf), not derived
# from the file under test.
# shellcheck disable=SC1090,SC2016
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXT="$ROOT/buildroot-external"
OVL="$EXT/rootfs-overlay"
ASSERT="$ROOT/buildroot-ihost/rootfs-overlay/usr/sbin/ga-wlan0-powersave-assert"
RESCUE="$OVL/usr/sbin/ga-firstboot-noupl-rescue"
NMC="$OVL/usr/share/ga-wifi/GreenAutarky-Install.nmconnection"
CONF="$OVL/etc/NetworkManager/conf.d/50-ga.conf"
PSKSCRIPT="$EXT/scripts/post-build.d/85-wifi-install-psk.sh"
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
run_assert() { ( export GA_PSAVE_TEST=1 GA_PSAVE_NMCLI="$T/nmcli" GA_PSAVE_IW="$T/iw" GA_PSAVE_WAIT=0; . "$ASSERT"; assert_once ) 2>/dev/null; }

mk_nm default activated; mk_iw on;  R="$(run_assert)"
ck WFB-20 test "$R" = fixed
ck WFB-21 sh -c "! grep -q 'connection up' '$T/nm.log'"          # no re-activation
ck WFB-22 grep -q 'connection modify inst 802-11-wireless.powersave 2' "$T/nm.log"
ck WFB-23 grep -q 'dev wlan0 set power_save off' "$T/iw.log"      # applied without deauth
mk_nm default activating; mk_iw on; R="$(run_assert)"
ck WFB-24 test "$R" = deferred
ck WFB-25 sh -c "! grep -q 'connection modify\\|connection up' '$T/nm.log'"
mk_nm default activated; mk_iw off; R="$(run_assert)"
ck WFB-26 test "$R" = ok                                           # conf.d default in effect
ck WFB-27 sh -c "! grep -q 'connection modify\\|connection up' '$T/nm.log'"
mk_nm 2 activated; mk_iw on; R="$(run_assert)"
ck WFB-28 test "$R" = ok

# ── WFB-3x: 50-ga.conf ──────────────────────────────────────────────────────
KEYS="$(awk '/^\[/{s=$0; next} s=="[connection-wifi-defaults]" && /^[A-Za-z]/{sub(/=.*/,""); print}' "$CONF")"
ck WFB-30 test -n "$KEYS"                                          # fail closed on zero
BAD=""; for k in $KEYS; do case "$k" in match-device|stop-match|wifi.powersave|wifi.cloned-mac-address) ;; *) BAD="$BAD $k";; esac; done
ck WFB-31 test -z "$BAD"
ck WFB-32 grep -q '^wifi.powersave=2$' "$CONF"
ck WFB-33 grep -q '^match-device=type:wifi$' "$CONF"

# ── WFB-4x: rescue ──────────────────────────────────────────────────────────
mk_rescue_cmds() { # $1 route(yes|no) $2 connectivity
    printf '#!/bin/sh\n[ "$1 $2 $3 $4" = "-4 route show default" ] && [ "%s" = yes ] && echo "default via 10.0.0.1"\nexit 0\n' "$1" > "$T/ip"
    printf '#!/bin/sh\ncase "$*" in *"connectivity check"*) echo %s ;; *) echo "nmcli-out $*" ;; esac\n' "$2" > "$T/rnm"
    printf '#!/bin/sh\ni=0; while [ $i -lt 3000 ]; do echo "journal line $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done\n' > "$T/jc"
    printf '#!/bin/sh\necho "dmesg-out"\n' > "$T/dm"
    chmod +x "$T/ip" "$T/rnm" "$T/jc" "$T/dm"
}
run_rescue() { ( export GA_RESCUE_TEST=1 GA_RESCUE_DIR="$T/data" GA_RESCUE_IP="$T/ip" GA_RESCUE_NMCLI="$T/rnm" GA_RESCUE_JOURNALCTL="$T/jc" GA_RESCUE_DMESG="$T/dm" GA_RESCUE_BOOTID="$T/bootid" GA_RESCUE_MAX_JOURNAL=5000 GA_RESCUE_KEEP=2; . "$RESCUE"; rescue_once ) 2>/dev/null; }
mkdir -p "$T/data"
echo "aaaaaaaa-bbbb-cccc-dddd-000000000001" > "$T/bootid"
mk_rescue_cmds yes full;  R="$(run_rescue)"
ck WFB-40 test "$R" = ok
ck WFB-41 test -z "$(ls "$T/data")"                                # nothing written when healthy
mk_rescue_cmds no full;   R="$(run_rescue)"
ck WFB-42 test "$R" = written
F="$T/data/ga-firstboot-noupl-aaaaaaaabbbb.txt"
ck WFB-43 test -s "$F"
ck WFB-44 grep -q '^## nmcli -f all dev' "$F"
ck WFB-45 grep -q '^## nmcli con show --active' "$F"
ck WFB-46 grep -q '^## dmesg' "$F"
ck WFB-47 grep -q 'journal line 2999' "$F"                          # newest part kept
ck WFB-48 sh -c "! grep -q 'journal line 0 ' '$F'"                  # bounded (oldest dropped)
R="$(run_rescue)"
ck WFB-49 test "$R" = exists                                        # once per boot
mk_rescue_cmds yes limited; R="$(run_rescue)"; ck WFB-50 test "$R" = exists   # route but no connectivity = no uplink (same boot -> exists)
for n in 2 3 4; do echo "aaaaaaa$n-bbbb-cccc-dddd-000000000001" > "$T/bootid"; sleep 1; mk_rescue_cmds no none; run_rescue >/dev/null; done
ck WFB-51 test "$(ls "$T/data" | wc -l)" -eq 2                      # rotation keeps newest 2
ck WFB-52 sh -c "! test -e '$T/data/ga-firstboot-noupl-aaaaaaaabbbb.txt'"   # oldest rotated out
# units
ck WFB-60 grep -q '^OnBootSec=3min$' "$OVL/etc/systemd/system/ga-firstboot-noupl-rescue.timer"
ck WFB-61 test -e "$OVL/etc/systemd/system/timers.target.wants/ga-firstboot-noupl-rescue.timer"
ck WFB-62 grep -q '^ExecStart=/usr/sbin/ga-firstboot-noupl-rescue$' "$OVL/etc/systemd/system/ga-firstboot-noupl-rescue.service"
ck WFB-63 test -x "$RESCUE"

TOTAL=$((PASSES+FAILS))
echo "wifi_firstboot: $PASSES/$TOTAL passed"
[ "$TOTAL" -gt 0 ] && [ "$FAILS" -eq 0 ]
