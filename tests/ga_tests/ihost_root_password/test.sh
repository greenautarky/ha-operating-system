#!/bin/sh
# iHost board: ADR-0039 start-password bake hook is wired in the one tree (Q-0039).
#
# The iHost board bakes ROOT_PW_HASH into /etc/shadow with
# board/sonoff/ihost/post-build.d/80-root-password.sh (run by the board post-build.sh)
# + post-fakeroot.sh (BR2_ROOTFS_POST_FAKEROOT_SCRIPT), both fail closed. This suite
# holds that wiring to the tree: nothing else checks it before a build.
#
#   IHPW-01  defconfig wires BR2_ROOTFS_POST_FAKEROOT_SCRIPT to the board's post-fakeroot.sh (exists, executable)
#   IHPW-02  defconfig runs the iHost board post-build.sh; the hook exists and is executable
#   IHPW-03  post-fakeroot.sh, 80-root-password.sh, securetty equal their pinned sha256
#   IHPW-04  the live post-fakeroot.sh sets root's shadow field, nothing else, mode 0400
#   IHPW-05  the live 80-root-password.sh does the same, mode 0600
#   IHPW-06  fail closed: unset ROOT_PW_HASH -> exit 1 + shadow untouched (both scripts);
#            plaintext / $1$ hash rejected by the 80- hook
#   IHPW-07  the board post-build runner runs the hook (hash lands) and aborts when the hook fails
#   IHPW-08  securetty reaches the image (an effective overlay) and lists ttyS2 + ttyGS0
#
# NOT proven here: that a built iHost 1.6 image boots, that ROOT_PW_HASH reaches the
# buildroot container in the 1.6 bake, that login on ttyS2/ttyGS0 accepts the start
# password and refuses an empty one.
#
# GA_TREE=<dir> runs the suite against another checkout (red proof: the base tree).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"
suite_start "iHost root-password bake hook wired in the one tree (ADR-0039)"

R="${GA_TREE:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
DEFC="$R/buildroot-ihost/configs/ga_ihost_full_defconfig"
BOARD="$R/buildroot-ihost/board/sonoff/ihost"
# Pinned constants (never derived from the files they judge):
SECURETTY_SHA=23b44084cee8a2c965869d2b875dd505747086567f93b97448d0e480a0f301a3   # buildroot-ihost/rootfs-overlay/etc/securetty
FAKEROOT_SHA=8a1cfe478ecf767a2214286226d41f78dedba4dca1b626031ee8189251b6fb4b    # board/sonoff/ihost/post-fakeroot.sh
HOOK_SHA=eb57ff472755eb3c292968e5f3b4ec242442cc2541f877a30b9282323fffba0e        # board/sonoff/ihost/post-build.d/80-root-password.sh
HASH='$6$abcdefgh$'"$(printf 'A%.0s' $(seq 1 86))"
W="$(mktemp -d 2>/dev/null || echo /tmp/ihost_rootpw_$$)"; mkdir -p "$W"

resolve() { sed -e "s|\$(BR2_EXTERNAL_IHOST_PATH)|$R/buildroot-ihost|g" -e "s|\$(BR2_EXTERNAL_GA_HAOS_PATH)|$R/buildroot-external|g" -e "s|\$(BR2_EXTERNAL_HAOS_PATH)|$R/haos/buildroot-external|g"; }
defval() { grep -E "^$1=" "$DEFC" | head -1 | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//' | resolve; }
[ -f "$DEFC" ] || { echo "no defconfig at $DEFC"; suite_end; exit 2; }
FAKEROOT="$(defval BR2_ROOTFS_POST_FAKEROOT_SCRIPT)"
PB_LIST="$(defval BR2_ROOTFS_POST_BUILD_SCRIPT)"
PB_ARGS="$(defval BR2_ROOTFS_POST_SCRIPT_ARGS)"
OVERLAYS="$(defval BR2_ROOTFS_OVERLAY)"
IH_PB="$R/buildroot-ihost/scripts/post-build.sh"
HOOK="$BOARD/post-build.d/80-root-password.sh"
FAKEROOT_EXPECT="$BOARD/post-fakeroot.sh"

run_test "IHPW-01" "defconfig sets BR2_ROOTFS_POST_FAKEROOT_SCRIPT to the board post-fakeroot.sh; it exists and is executable" \
  "[ -n '$FAKEROOT' ] && [ '$FAKEROOT' = '$FAKEROOT_EXPECT' ] && [ -x '$FAKEROOT' ]"
run_test "IHPW-02" "defconfig runs the iHost board post-build.sh with the board dir as first script arg; hook exists and is executable" \
  "case ' $PB_LIST ' in *' $IH_PB '*) true ;; *) false ;; esac && [ -x '$IH_PB' ] && case ' $PB_ARGS ' in ' $BOARD '*) true ;; *) false ;; esac && [ -x '$HOOK' ]"
run_test "IHPW-03" "post-fakeroot.sh, 80-root-password.sh and securetty equal their pinned sha256" \
  "[ \"\$(sha256sum '$FAKEROOT_EXPECT' | cut -d' ' -f1)\" = $FAKEROOT_SHA ] && [ \"\$(sha256sum '$HOOK' | cut -d' ' -f1)\" = $HOOK_SHA ] && [ \"\$(sha256sum '$R/buildroot-ihost/rootfs-overlay/etc/securetty' | cut -d' ' -f1)\" = $SECURETTY_SHA ]"

mkshadow() { rm -rf "$1"; mkdir -p "$1/etc"
  printf 'root::19000:0:99999:7:::\nsystemd-network:!*:19000::::::\nhassio:!:19000:0:99999:7:::\n' > "$1/etc/shadow"; chmod 0644 "$1/etc/shadow"; }
chk_shadow() { [ "$(sed -n 1p "$1/etc/shadow")" = "root:$HASH:19000:0:99999:7:::" ] && \
  [ "$(sed -n 2p "$1/etc/shadow")" = "systemd-network:!*:19000::::::" ] && \
  [ "$(sed -n 3p "$1/etc/shadow")" = "hassio:!:19000:0:99999:7:::" ] && [ "$(wc -l < "$1/etc/shadow")" -eq 3 ]; }
chk_untouched() { [ "$(sed -n 1p "$1/etc/shadow")" = "root::19000:0:99999:7:::" ] && [ "$(wc -l < "$1/etc/shadow")" -eq 3 ]; }

mkshadow "$W/t1"; [ -f "$FAKEROOT" ] && ROOT_PW_HASH="$HASH" sh "$FAKEROOT" "$W/t1" > "$W/t1.out" 2>&1; echo $? > "$W/t1.rc"
run_test "IHPW-04" "post-fakeroot (path from the defconfig): root's field = ROOT_PW_HASH, others unchanged, mode 0400" \
  "[ \"\$(cat '$W/t1.rc')\" = 0 ] && chk_shadow '$W/t1' && [ \"\$(stat -c %a '$W/t1/etc/shadow')\" = 400 ]"
mkshadow "$W/t2"; [ -f "$HOOK" ] && ROOT_PW_HASH="$HASH" sh "$HOOK" "$W/t2" > "$W/t2.out" 2>&1; echo $? > "$W/t2.rc"
run_test "IHPW-05" "80-root-password.sh: root's field = ROOT_PW_HASH, others unchanged, mode 0600" \
  "[ \"\$(cat '$W/t2.rc')\" = 0 ] && chk_shadow '$W/t2' && [ \"\$(stat -c %a '$W/t2/etc/shadow')\" = 600 ]"

fc=0
try_bad() { # <script> <value, "-" = unset>
  [ -f "$1" ] || { fc=1; echo "script missing: '$1'" >> "$W/fc.why"; return 0; }   # no vacuous pass
  mkshadow "$W/f"
  if [ "$2" = "-" ]; then env -u ROOT_PW_HASH sh "$1" "$W/f" >/dev/null 2>&1; else env ROOT_PW_HASH="$2" sh "$1" "$W/f" >/dev/null 2>&1; fi
  rc=$?
  [ "$rc" -ne 0 ] || { fc=1; echo "no failure for '$2' in $(basename "$1")" >> "$W/fc.why"; }
  chk_untouched "$W/f" || { fc=1; echo "shadow changed for '$2' in $(basename "$1")" >> "$W/fc.why"; }
}
try_bad "$FAKEROOT" -
for bad in - plaintext '$1$abc$def'; do try_bad "$HOOK" "$bad"; done
show_verdict "IHPW-06" "fail closed: post-fakeroot rejects unset; the 80- hook rejects unset, plaintext and a \$1\$ hash; shadow untouched" "$fc" "$(cat "$W/fc.why" 2>/dev/null)"

mkdir -p "$W/b/post-build.d"; [ -f "$HOOK" ] && cp "$HOOK" "$W/b/post-build.d/"; cp "$BOARD/meta" "$W/b/meta"; mkshadow "$W/t3"
ROOT_PW_HASH="$HASH" bash "$IH_PB" "$W/t3" "$W/b" > "$W/t3.out" 2>&1; echo $? > "$W/t3.rc"
mkshadow "$W/f"; env -u ROOT_PW_HASH bash "$IH_PB" "$W/f" "$W/b" > /dev/null 2>&1; echo $? > "$W/t3f.rc"
run_test "IHPW-07" "board post-build runner runs the hook (hash lands) and aborts when the hook fails" \
  "[ \"\$(cat '$W/t3.rc')\" = 0 ] && chk_shadow '$W/t3' && [ \"\$(cat '$W/t3f.rc')\" != 0 ]"

SEC=""; for o in $OVERLAYS; do [ -f "$o/etc/securetty" ] && SEC="$o/etc/securetty"; done
run_test "IHPW-08" "an effective overlay ships /etc/securetty (last wins) with ttyS2 and ttyGS0" \
  "[ -n '$SEC' ] && grep -qx ttyS2 '$SEC' && grep -qx ttyGS0 '$SEC' && [ \"\$(sha256sum '$SEC' | cut -d' ' -f1)\" = $SECURETTY_SHA ]"

rm -rf "$W"
suite_end
