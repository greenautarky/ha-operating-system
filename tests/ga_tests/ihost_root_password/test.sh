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
#   IHPW-06  fail closed, both scripts: unset/empty ROOT_PW_HASH and every malformed value
#            (plaintext, $1$, truncated or over-long $6$, ':', two lines, trailing space)
#            -> exit 1 + shadow untouched (must-fail fixtures)
#   IHPW-09  the bake's hash pattern equals ga-root-shadow's runtime valid_hash (live, both sides)
#   IHPW-10  must-pass: an openssl-generated $6$ hash and the rounds= form land in both scripts
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
FAKEROOT_SHA=05566dcea691e6a1844c83e42950d6d5f5495d1c2e465979f51a1691906bdcfa    # board/sonoff/ihost/post-fakeroot.sh
HOOK_SHA=c1f7ba5e683c17e9e369d6758474d069842767a323cd1bfd0d83075218ca31cb        # board/sonoff/ihost/post-build.d/80-root-password.sh
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
# Must-fail values (none is a usable hash; nothing here is a real credential):
# unset, empty, plaintext, another scheme, a truncated $6$ value, a hash one
# character short, a salt one character too long, a field separator, a second
# line, trailing whitespace.
A85="$(printf 'A%.0s' $(seq 1 85))"; A86="${A85}A"; NL='
'
BAD_HASHES="- @EMPTY@ plaintext \$1\$abc\$def \$6\$short \$6\$abcdefgh\$$A85 \$6\$abcdefghijklmnopq\$$A86 \$6\$abc:defgh\$$A86 @TWOLINES@ @TRAILSP@"
bad_value() { case "$1" in @EMPTY@) printf '' ;; @TWOLINES@) printf '%s' "$HASH$NL$HASH" ;; @TRAILSP@) printf '%s ' "$HASH" ;; *) printf '%s' "$1" ;; esac; }
try_bad() { # <script> <value, "-" = unset>
  [ -f "$1" ] || { fc=1; echo "script missing: '$1'" >> "$W/fc.why"; return 0; }   # no vacuous pass
  mkshadow "$W/f"
  if [ "$2" = "-" ]; then env -u ROOT_PW_HASH sh "$1" "$W/f" >/dev/null 2>&1; else env ROOT_PW_HASH="$(bad_value "$2")" sh "$1" "$W/f" >/dev/null 2>&1; fi
  rc=$?
  [ "$rc" -ne 0 ] || { fc=1; echo "no failure for '$2' in $(basename "$1")" >> "$W/fc.why"; }
  chk_untouched "$W/f" || { fc=1; echo "shadow changed for '$2' in $(basename "$1")" >> "$W/fc.why"; }
}
for bad in $BAD_HASHES; do try_bad "$FAKEROOT" "$bad"; try_bad "$HOOK" "$bad"; done
show_verdict "IHPW-06" "fail closed: post-fakeroot and the 80- hook both reject unset, empty, plaintext, \$1\$, truncated or over-long \$6\$ values, a colon, a second line and trailing space; shadow untouched" "$fc" "$(cat "$W/fc.why" 2>/dev/null)"

# Must-pass: real-format hashes made here, at test time (a random password that
# is never stored; openssl is the generator ADR-0039 D3 names), plus the
# rounds= form. Both scripts must accept each and land it in root's field.
# No generator = FAIL, not skip: without it this check would pass on nothing.
gc=0; ngood=0
GEN="$(openssl rand -hex 16 2>/dev/null | openssl passwd -6 -stdin 2>/dev/null)"
[ -n "$GEN" ] || { gc=1; echo "openssl could not generate a \$6\$ hash" >> "$W/gc.why"; }
for good in "$GEN" "\$6\$rounds=5000\$abcdefghijklmnop\$$A86"; do
  [ -n "$good" ] || continue
  for s in "$FAKEROOT" "$HOOK"; do
    mkshadow "$W/g"; env ROOT_PW_HASH="$good" sh "$s" "$W/g" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] && [ "$(sed -n 1p "$W/g/etc/shadow")" = "root:$good:19000:0:99999:7:::" ] && [ "$(wc -l < "$W/g/etc/shadow")" -eq 3 ] \
      && ngood=$((ngood + 1)) || { gc=1; echo "rejected or not landed (rc=$rc): $(printf '%s' "$good" | cut -c1-12)... in $(basename "$s")" >> "$W/gc.why"; }
  done
done
[ "$ngood" -eq 4 ] || { gc=1; echo "accepted $ngood of 4 must-pass cases" >> "$W/gc.why"; }
show_verdict "IHPW-10" "must-pass: an openssl-generated \$6\$ hash and the rounds= form are accepted by both scripts and land in root's field" "$gc" "$(cat "$W/gc.why" 2>/dev/null)"

# The bake and the runtime must accept the same shape (rule 61: two sources, one
# truth -> compare). Extracted live from both scripts; an extraction that finds
# nothing is a FAIL.
RT="$R/buildroot-external/rootfs-overlay/usr/libexec/ga-root-shadow"
RT_RE="$(sed -n "s/^[[:space:]]*grep -Eqx '\([^']*\)' \"\$1\".*/\1/p" "$RT" 2>/dev/null | head -1)"
HK_RE="$(sed -n "s/^GA_ROOT_PW_HASH_RE='\([^']*\)'\$/\1/p" "$HOOK" 2>/dev/null | head -1)"
FR_RE="$(sed -n "s/^GA_ROOT_PW_HASH_RE='\([^']*\)'\$/\1/p" "$FAKEROOT" 2>/dev/null | head -1)"
run_test "IHPW-09" "the bake's hash pattern (80- hook and post-fakeroot) equals ga-root-shadow's valid_hash pattern" \
  "[ -n '$RT_RE' ] && [ '$RT_RE' = '$HK_RE' ] && [ '$RT_RE' = '$FR_RE' ]"

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
