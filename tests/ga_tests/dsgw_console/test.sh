#!/bin/sh
# DSGW-210 serial consoles follow the iHost model (ADR-0039) -- build-time/static.
#
# The iHost mechanism: (1) the bake writes the start password hash into the
# image's /etc/shadow (80-root-password.sh in post-build.d + post-fakeroot.sh,
# fail closed without ROOT_PW_HASH), (2) /etc/securetty lists the consoles root
# may log in on (ttyS2 = internal UART, ttyGS0 = USB-C gadget) and pam.d/login
# enforces it (pam_securetty), (3) the GA layer ships ga-root-shadow (per-device
# hash from the overlay, D4/D4b).
#
#   DCON-01  defconfig: post-build runner + post-fakeroot script wired, files exist+executable
#   DCON-02  /etc/securetty in the effective overlays lists ttyS2 and ttyGS0
#   DCON-03  securetty, pam.d/login, post-fakeroot.sh, 80-root-password.sh equal the iHost files (pinned sha256)
#   DCON-04  the live post-fakeroot.sh writes the hash into root's shadow field, nothing else
#   DCON-05  the live 80-root-password.sh does the same
#   DCON-06  both fail closed: no ROOT_PW_HASH / not a $6$ hash -> exit 1, shadow untouched
#   DCON-07  the board post-build runner runs 80-root-password.sh and aborts on its failure
#   DCON-08  shared pieces are present: ga-root-shadow script + unit + sysinit link in the GA layer,
#            sulogin + login packages in the defconfig
#   DCON-09  both consoles are reachable: kernel console=ttyS2, getty@ttyGS0 started after the gadget
#
# Not proven here: that a built image boots, that pam_securetty/ttyGS0 accept the
# start password and refuse the empty one, and that ga-root-shadow rotates; those
# need a device.
#
# GA_TREE=<dir> runs the suite against another checkout (red proof: the base tree).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "DSGW-210 consoles follow the iHost model (ADR-0039)"

R="${GA_TREE:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
DEFC="$R/buildroot-dsgw210/configs/dsgw210_defconfig"
BOARD="$R/buildroot-dsgw210/board/dusun/dsgw210"
GA="$R/buildroot-external"
# Pinned constants (never derived from the files they judge): the iHost board's files.
SECURETTY_SHA=23b44084cee8a2c965869d2b875dd505747086567f93b97448d0e480a0f301a3   # buildroot-ihost/rootfs-overlay/etc/securetty
PAMLOGIN_SHA=41dafb49ff35340d240d25421d17beca91568876691171409cf3762904892c40    # buildroot-ihost/rootfs-overlay/etc/pam.d/login
FAKEROOT_SHA=8a1cfe478ecf767a2214286226d41f78dedba4dca1b626031ee8189251b6fb4b    # board/sonoff/ihost/post-fakeroot.sh
HOOK_SHA=eb57ff472755eb3c292968e5f3b4ec242442cc2541f877a30b9282323fffba0e        # board/sonoff/ihost/post-build.d/80-root-password.sh
HASH='$6$abcdefgh$'"$(printf 'A%.0s' $(seq 1 86))"
W="$(mktemp -d 2>/dev/null || echo /tmp/dsgw_console_$$)"

# resolve the $(BR2_EXTERNAL_X_PATH) references of the defconfig to this tree
resolve() { sed -e "s|\$(BR2_EXTERNAL_DSGW210_PATH)|$R/buildroot-dsgw210|g" -e "s|\$(BR2_EXTERNAL_GA_HAOS_PATH)|$GA|g" -e "s|\$(BR2_EXTERNAL_HAOS_PATH)|$R/haos/buildroot-external|g"; }
defval() { grep -E "^$1=" "$DEFC" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//' | resolve; }
[ -f "$DEFC" ] || { echo "no defconfig at $DEFC"; suite_end; exit 2; }
FAKEROOT="$(defval BR2_ROOTFS_POST_FAKEROOT_SCRIPT)"
PB_LIST="$(defval BR2_ROOTFS_POST_BUILD_SCRIPT)"
OVERLAYS="$(defval BR2_ROOTFS_OVERLAY)"
DSGW_PB="$R/buildroot-dsgw210/scripts/post-build.sh"
HOOK="$BOARD/post-build.d/80-root-password.sh"

run_test "DCON-01" "defconfig wires the DSGW post-build runner and a post-fakeroot script; both exist and are executable" \
  "[ -n '$FAKEROOT' ] && [ -x '$FAKEROOT' ] && case ' $PB_LIST ' in *' $DSGW_PB '*) true ;; *) false ;; esac && [ -x '$DSGW_PB' ] && [ -x '$HOOK' ]"

SEC=""; PAM=""
for o in $OVERLAYS; do [ -f "$o/etc/securetty" ] && SEC="$o/etc/securetty"; [ -f "$o/etc/pam.d/login" ] && PAM="$o/etc/pam.d/login"; done
run_test "DCON-02" "an overlay of the DSGW build (not the haos/ one) ships /etc/securetty with ttyS2 and ttyGS0" \
  "[ -n '$SEC' ] && case '$SEC' in '$R/haos/'*) false ;; esac && grep -qx ttyS2 '$SEC' && grep -qx ttyGS0 '$SEC'"
run_test "DCON-03" "securetty, pam.d/login, post-fakeroot.sh and 80-root-password.sh equal the iHost files (pinned sha256)" \
  "[ -n '$SEC' ] && [ -n '$PAM' ] && [ \"\$(sha256sum '$SEC' | cut -d' ' -f1)\" = $SECURETTY_SHA ] && [ \"\$(sha256sum '$PAM' | cut -d' ' -f1)\" = $PAMLOGIN_SHA ] && [ \"\$(sha256sum '$FAKEROOT' | cut -d' ' -f1)\" = $FAKEROOT_SHA ] && [ \"\$(sha256sum '$HOOK' | cut -d' ' -f1)\" = $HOOK_SHA ]"

mkshadow() { # a target with the HAOS default (empty root password) + two more accounts
  rm -rf "$1"
  mkdir -p "$1/etc"
  printf 'root::19000:0:99999:7:::\nsystemd-network:!*:19000::::::\nhassio:!:19000:0:99999:7:::\n' > "$1/etc/shadow"
  chmod 0644 "$1/etc/shadow"
}
chk_shadow() { # root = $HASH, the other two lines and the line count unchanged
  [ "$(sed -n 1p "$1/etc/shadow")" = "root:$HASH:19000:0:99999:7:::" ] && \
  [ "$(sed -n 2p "$1/etc/shadow")" = "systemd-network:!*:19000::::::" ] && \
  [ "$(sed -n 3p "$1/etc/shadow")" = "hassio:!:19000:0:99999:7:::" ] && [ "$(wc -l < "$1/etc/shadow")" -eq 3 ]
}
chk_untouched() { [ "$(sed -n 1p "$1/etc/shadow")" = "root::19000:0:99999:7:::" ] && [ "$(wc -l < "$1/etc/shadow")" -eq 3 ]; }

mkshadow "$W/t1"; ROOT_PW_HASH="$HASH" sh "$FAKEROOT" "$W/t1" > "$W/t1.out" 2>&1; echo $? > "$W/t1.rc"
run_test "DCON-04" "post-fakeroot (from the defconfig): root's field = ROOT_PW_HASH, other accounts unchanged, mode 0400" \
  "[ \"\$(cat '$W/t1.rc')\" = 0 ] && chk_shadow '$W/t1' && [ \"\$(stat -c %a '$W/t1/etc/shadow')\" = 400 ]"
mkshadow "$W/t2"; ROOT_PW_HASH="$HASH" sh "$HOOK" "$W/t2" > "$W/t2.out" 2>&1; echo $? > "$W/t2.rc"
run_test "DCON-05" "80-root-password.sh: root's field = ROOT_PW_HASH, other accounts unchanged, mode 0600" \
  "[ \"\$(cat '$W/t2.rc')\" = 0 ] && chk_shadow '$W/t2' && [ \"\$(stat -c %a '$W/t2/etc/shadow')\" = 600 ]"

# fail closed: nothing may produce an image with a passwordless root.
# Division of labour (as on the iHost): 80-root-password.sh rejects unset AND malformed
# hashes; post-fakeroot.sh rejects only an unset/empty one -- so the 80- hook must stay wired
# (DCON-01/07 assert that) or a malformed ROOT_PW_HASH would reach /etc/shadow.
fc=0
try_bad() { # try_bad <script> <ROOT_PW_HASH value, "-" = unset>
  [ -f "$1" ] || { fc=1; echo "script missing: '$1'" >> "$W/fc.why"; return 0; }   # no vacuous pass
  mkshadow "$W/f"
  if [ "$2" = "-" ]; then env -u ROOT_PW_HASH sh "$1" "$W/f" >/dev/null 2>&1; else env ROOT_PW_HASH="$2" sh "$1" "$W/f" >/dev/null 2>&1; fi
  rc=$?
  [ "$rc" -ne 0 ] || { fc=1; echo "no failure for '$2' in $(basename "$1")" >> "$W/fc.why"; }
  chk_untouched "$W/f" || { fc=1; echo "shadow changed for '$2' in $(basename "$1")" >> "$W/fc.why"; }
}
try_bad "$FAKEROOT" -
for bad in - plaintext '$1$abc$def'; do try_bad "$HOOK" "$bad"; done
show_verdict "DCON-06" "fail closed: post-fakeroot rejects unset; the 80- hook rejects unset, plaintext, and a \$1\$ hash; shadow untouched" "$fc" "$(cat "$W/fc.why" 2>/dev/null)"

mkdir -p "$W/b/post-build.d"; cp "$HOOK" "$W/b/post-build.d/"; mkshadow "$W/t3"
ROOT_PW_HASH="$HASH" bash "$DSGW_PB" "$W/t3" "$W/b" > "$W/t3.out" 2>&1; echo $? > "$W/t3.rc"
mkshadow "$W/f"; env -u ROOT_PW_HASH bash "$DSGW_PB" "$W/f" "$W/b" > /dev/null 2>&1; echo $? > "$W/t3f.rc"
run_test "DCON-07" "board post-build runner runs the hook (hash lands) and aborts when the hook fails" \
  "[ \"\$(cat '$W/t3.rc')\" = 0 ] && chk_shadow '$W/t3' && [ \"\$(cat '$W/t3f.rc')\" != 0 ]"

RS_LINK="$GA/rootfs-overlay/etc/systemd/system/sysinit.target.wants/ga-root-shadow.service"
run_test "DCON-08" "shared pieces present: ga-root-shadow script + unit + sysinit link in the GA layer, sulogin and login in the defconfig" \
  "[ -x '$GA/rootfs-overlay/usr/libexec/ga-root-shadow' ] && [ -e '$GA/rootfs-overlay/usr/lib/systemd/system/ga-root-shadow.service' ] && [ -L '$RS_LINK' ] && grep -q '^BR2_PACKAGE_UTIL_LINUX_SULOGIN=y' '$DEFC' && grep -q '^BR2_PACKAGE_UTIL_LINUX_LOGIN=y' '$DEFC'"

run_test "DCON-09" "both consoles reachable: kernel console=ttyS2 (getty generator) and serial-getty@ttyGS0 started after the gadget exists" \
  "head -1 '$BOARD/cmdline.txt' | grep -q 'console=ttyS2' && grep -q '^ExecStartPost=.*serial-getty@ttyGS0' '$BOARD/rootfs-overlay/etc/systemd/system/ga-usb-gadget-serial.service' && [ -e '$BOARD/rootfs-overlay/etc/systemd/system/multi-user.target.wants/ga-usb-gadget-serial.service' ]"

rm -rf "$W"
suite_end
