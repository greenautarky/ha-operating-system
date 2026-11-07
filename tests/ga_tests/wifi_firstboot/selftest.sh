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
# shellcheck disable=SC1090,SC2016,SC2034
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
mk_nmbin() { # $1 = global wifi.powersave value or "" ; fake NetworkManager --print-config
    printf '#!/bin/sh\necho "[main]"\necho "[connection-wifi-defaults]"\n[ -n "%s" ] && echo "wifi.powersave=%s"\nexit 0\n' "$1" "$1" > "$T/NetworkManager"
    chmod +x "$T/NetworkManager"
}
mk_iw_stuck() { cat > "$T/iw" <<IW
#!/bin/sh
echo "\$*" >> "$T/iw.log"
case "\$*" in *"get power_save"*) echo "Power save: on" ;; esac
IW
    chmod +x "$T/iw"; : > "$T/iw.log"; }
mk_iw_flip() { cat > "$T/iw" <<IW
#!/bin/sh
echo "\$*" >> "$T/iw.log"
case "\$*" in *"set power_save off"*) echo off > "$T/iwst" ;; *"get power_save"*) echo "Power save: \$(cat "$T/iwst" 2>/dev/null || echo on)" ;; esac
IW
    chmod +x "$T/iw"; rm -f "$T/iwst"; : > "$T/iw.log"; }
mk_nmbin 2
run_assert() { ( logger() { echo "$*" >> "$T/log"; }; export GA_PSAVE_TEST=1 GA_PSAVE_NM="$T/NetworkManager" GA_PSAVE_NMCLI="$T/nmcli" GA_PSAVE_IW="${IWOVR:-$T/iw}" GA_PSAVE_WAIT=0; . "$ASSERT"; assert_once ) 2>/dev/null; }

# must-pass: profile default + global 2 -> no action at all (even if iw says on)
mk_nm default activated; mk_iw on; R="$(run_assert)"
ck WFB-29 test "$R" = ok
ck WFB-29b sh -c "! grep -q 'connection modify\\|connection up' '$T/nm.log' && ! grep -q 'set power_save' '$T/iw.log'"
mk_nmbin ""
mk_nm default activated; mk_iw_flip;  R="$(run_assert)"   # stub flips to off after set
ck WFB-20 test "$R" = fixed
ck WFB-21 sh -c "! grep -q 'connection up' '$T/nm.log'"          # no re-activation
ck WFB-22 grep -q 'connection modify inst 802-11-wireless.powersave 2' "$T/nm.log"
ck WFB-23 grep -q 'dev wlan0 set power_save off' "$T/iw.log"      # applied without deauth
# #1572: `iw set power_save off` itself FAILS -> must NOT print "fixed"; distinct state + warning
mk_iw_fail() { # fake iw: get -> on, set -> error exit 237 (rc pinned)
    cat > "$T/iw" <<IW
#!/bin/sh
echo "\$*" >> "$T/iw.log"
case "\$*" in *"get power_save"*) echo "Power save: on" ;; *"set power_save"*) echo "command failed: Operation not supported (-95)" >&2; exit 237 ;; esac
IW
    chmod +x "$T/iw"; : > "$T/iw.log"
}
mk_nmbin ""; mk_nm default activated; mk_iw_fail; : > "$T/log"; R="$(run_assert)"
ck WFB-80 test "$R" = fix-failed
ck WFB-81 sh -c "! [ '$R' = fixed ]"
ck WFB-82 grep -q 'FAILED (exit 237' "$T/log"
ck WFB-83 grep -q 'warning' "$T/log"
ck WFB-84 grep -q 'Operation not supported' "$T/log"      # iw's own error reaches the log
ck WFB-85 grep -q 'connection modify inst 802-11-wireless.powersave 2' "$T/nm.log"   # still persisted
ck WFB-86 sh -c "! grep -q 'connection up' '$T/nm.log'"
# #1572 re-read: set succeeds (rc 0) but the re-read still says on -> not fixed
mk_nmbin ""; mk_nm default activated; mk_iw_stuck; : > "$T/log"; R="$(run_assert)"
ck WFB-87 test "$R" = fix-failed
ck WFB-88 grep -q 're-read state is .on.' "$T/log"
mk_nmbin ""; mk_nm default activated; mk_iw_flip; R="$(run_assert)"
ck WFB-89 test "$R" = fixed
ck WFB-90 sh -c "grep -c 'get power_save' '$T/iw.log' | grep -qx 2"   # once before, once after the set
# main path: status file written, fix-failed exits non-zero
mk_nmbin ""; mk_nm default activated; mk_iw_stuck
cat > "$T/nmbin_main" <<NB
#!/bin/sh
echo "[connection-wifi-defaults]"
NB
chmod +x "$T/nmbin_main"
( GA_PSAVE_NM="$T/nmbin_main" GA_PSAVE_NMCLI="$T/nmcli" GA_PSAVE_IW="$T/iw" GA_PSAVE_WAIT=0 GA_PSAVE_STATUS="$T/status" sh "$ASSERT" >"$T/out" 2>/dev/null ); RC=$?
ck WFB-91 test "$RC" = 1
ck WFB-92 grep -qx fix-failed "$T/status"
mk_iw_flip
( GA_PSAVE_NM="$T/nmbin_main" GA_PSAVE_NMCLI="$T/nmcli" GA_PSAVE_IW="$T/iw" GA_PSAVE_WAIT=0 GA_PSAVE_STATUS="$T/status" sh "$ASSERT" >"$T/out" 2>/dev/null ); RC=$?
ck WFB-93 test "$RC" = 0
ck WFB-94 grep -qx fixed "$T/status"
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
ck WFB-75 grep -q '^BR2_PACKAGE_IW=y$' "$ROOT/buildroot-ihost/configs/ga_ihost_full_defconfig"

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
NMB="${GA_NM_BUILD_DIR:-}"   # set GA_NM_BUILD_DIR to an ihost build output to run WFB-79; unset -> SKIP
if [ -n "$NMB" ] && command -v qemu-arm >/dev/null 2>&1 && [ -x "$NMB/target/usr/sbin/NetworkManager" ]; then
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

# ── WFB-4x: rescue ──────────────────────────────────────────────────────────
mk_rescue_cmds() { # $1 route(yes|no) $2 connectivity
    printf '#!/bin/sh\n[ "$1 $2 $3 $4" = "-4 route show default" ] && [ "%s" = yes ] && echo "default via gateway-fixture"\nexit 0\n' "$1" > "$T/ip"
    printf '#!/bin/sh\ncase "$*" in *"connectivity check"*) echo %s ;; *) echo "nmcli-out $*" ;; esac\n' "$2" > "$T/rnm"
    printf '#!/bin/sh\ni=0; while [ $i -lt 3000 ]; do echo "journal line $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done\n' > "$T/jc"
    printf '#!/bin/sh\necho "dmesg-out"\n' > "$T/dm"
    chmod +x "$T/ip" "$T/rnm" "$T/jc" "$T/dm"
}
run_rescue() { ( logger() { echo "$*" >> "$T/rlog"; }; export GA_RESCUE_TEST=1 GA_RESCUE_DIR="$T/data" GA_RESCUE_IP="$T/ip" GA_RESCUE_NMCLI="${NMOVR:-$T/rnm}" GA_RESCUE_JOURNALCTL="$T/jc" GA_RESCUE_DMESG="$T/dm" GA_RESCUE_BOOTID="$T/bootid" GA_RESCUE_MAX_JOURNAL=5000 GA_RESCUE_KEEP=2; . "$RESCUE"; rescue_once ) 2>/dev/null; }
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
ck WFB-53 grep -q '^## ls /sys/class/net' "$F"
ck WFB-54 grep -q 'rtw|efuse|wlan0' "$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-firstboot-noupl-rescue"
ck WFB-55 grep -q '^## journalctl NM + wifi helpers' "$F"
ck WFB-56 grep -q -- '-t ga-rtw-recover' "$ROOT/buildroot-external/rootfs-overlay/usr/sbin/ga-firstboot-noupl-rescue"
ck WFB-47 grep -q 'journal line 2999' "$F"                          # newest part kept
ck WFB-48 sh -c "! grep -q 'journal line 0 ' '$F'"                  # bounded (oldest dropped)
R="$(run_rescue)"
ck WFB-49 test "$R" = exists                                        # once per boot
mk_rescue_cmds yes limited; R="$(run_rescue)"; ck WFB-50 test "$R" = exists   # route but no connectivity = no uplink (same boot -> exists)
for n in 2 3 4; do echo "aaaaaaa$n-bbbb-cccc-dddd-000000000001" > "$T/bootid"; sleep 1; mk_rescue_cmds no none; run_rescue >/dev/null; done
ck WFB-51 test "$(ls "$T/data" | wc -l)" -eq 2                      # rotation keeps newest 2
ck WFB-52 sh -c "! test -e '$T/data/ga-firstboot-noupl-aaaaaaaabbbb.txt'"   # oldest rotated out
# units
# F3: private from creation, even under a permissive caller umask
echo "ffffffff-0000-0000-0000-000000000001" > "$T/bootid"; mk_rescue_cmds no none
( umask 022; run_rescue >/dev/null ); ck WFB-80 test "$(stat -c %a "$T/data/ga-firstboot-noupl-ffffffff0000.txt")" = 600
# F4: connectivity 'unknown' is not "no uplink"
echo "eeeeeeee-0000-0000-0000-000000000001" > "$T/bootid"; mk_rescue_cmds yes unknown; : > "$T/rlog"; R="$(run_rescue)"
ck WFB-81 test "$R" = unverified
ck WFB-82 test ! -e "$T/data/ga-firstboot-noupl-eeeeeeee0000.txt"
ck WFB-83 grep -q "connectivity is 'unknown'" "$T/rlog"
# F4: orphan tmp removed; write failure is loud and writes nothing
touch "$T/data/ga-firstboot-noupl-dead.txt.tmp"; echo "dddddddd-0000-0000-0000-000000000001" > "$T/bootid"; mk_rescue_cmds no none; run_rescue >/dev/null
ck WFB-84 test ! -e "$T/data/ga-firstboot-noupl-dead.txt.tmp"
chmod 555 "$T/data"; echo "cccccccc-0000-0000-0000-000000000001" > "$T/bootid"; : > "$T/rlog"; R="$(run_rescue)"; chmod 755 "$T/data"
ck WFB-85 test "$R" = failed
ck WFB-86 grep -q 'NOT written' "$T/rlog"
# F4: no nmcli/ip on the board -> skipped, loud
: > "$T/rlog"; R="$(NMOVR=/nonexistent/nmcli run_rescue)"; ck WFB-87 test "$R" = skipped
ck WFB-88 grep -q 'rescue skipped' "$T/rlog"
# F4: unit timeout covers the script's documented worst-case budget (140 s)
ck WFB-89 sh -c "[ \"\$(sed -n 's/^TimeoutStartSec=//p' '$OVL/etc/systemd/system/ga-firstboot-noupl-rescue.service')\" -ge 160 ]"
ck WFB-60 grep -q '^OnBootSec=3min$' "$OVL/etc/systemd/system/ga-firstboot-noupl-rescue.timer"
ck WFB-61 test -e "$OVL/etc/systemd/system/timers.target.wants/ga-firstboot-noupl-rescue.timer"
ck WFB-62 grep -q '^ExecStart=/usr/sbin/ga-firstboot-noupl-rescue$' "$OVL/etc/systemd/system/ga-firstboot-noupl-rescue.service"
ck WFB-63 test -x "$RESCUE"

TOTAL=$((PASSES+FAILS))
echo "wifi_firstboot: $PASSES/$TOTAL passed"
[ "$TOTAL" -gt 0 ] && [ "$FAILS" -eq 0 ]
