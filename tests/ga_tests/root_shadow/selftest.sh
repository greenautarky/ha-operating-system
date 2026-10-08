#!/bin/sh
# root_shadow selftest — ga-root-shadow (ADR-0039 D4/D4b/D6), host side, no device.
#
# Drives the REAL /usr/libexec/ga-root-shadow from the overlay with real bind
# mounts, inside a private mount namespace, against a fake image root on a
# tmpfs. Only paths are redirected (GA_RS_* hooks); nothing of the script is
# replaced. What it pins:
#
#   absent hash file   → the image's shadow, status "start"
#   valid hash file    → a merged copy bind-mounted, ONLY root's field changed,
#                        every other line byte-identical, status "rotated"
#   re-run             → updated in place, still exactly one mount
#   file removed       → back to the image's shadow
#   malformed file     → NOT applied, exit 1, status "malformed" (loud)
#   --early            → no-op when applied; applies from a mounted overlay;
#                        mounts the partition READ-ONLY when it is not;
#                        a banner when it cannot be read
#   the units          → ordered before sysinit.target, enabled, and the
#                        emergency/rescue drop-ins call --early
#
# Needs a private mount namespace: as root it re-executes itself under
# `unshare -m`; otherwise under `unshare -rm` (user namespace). The partition
# case (loop-mounted ext4) needs real root; without it that case is SKIPPED,
# unless GA_RS_REQUIRE_ALL=1 (CI), where a skip is a failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

if [ "${GA_RS_IN_NS:-}" != 1 ]; then
	if [ "$(id -u)" = 0 ]; then
		exec env GA_RS_IN_NS=1 GA_RS_REAL_ROOT=1 unshare -m --propagation private sh "$0" "$@"
	fi
	exec env GA_RS_IN_NS=1 GA_RS_REAL_ROOT=0 unshare -rm --propagation private sh "$0" "$@"
fi

. "$HERE/../lib/test_helpers.sh"
suite_start "ga-root-shadow (per-device root password, ADR-0039)"

OV="$REPO/buildroot-external/rootfs-overlay"
TOOL="$OV/usr/libexec/ga-root-shadow"
UNIT="$OV/usr/lib/systemd/system/ga-root-shadow.service"
run_test "RS-00" "helper present + executable" "test -x '$TOOL'"
command -v openssl >/dev/null 2>&1 || { echo "FATAL: openssl needed to make test hashes"; exit 1; }

W="$(mktemp -d)"
cleanup() {
	while awk -v w="$W" 'index($5, w) == 1 { f = 1 } END { exit !f }' /proc/self/mountinfo; do
		m="$(awk -v w="$W" 'index($5, w) == 1 { p = $5 } END { print p }' /proc/self/mountinfo)"
		umount -l "$m" 2>/dev/null || break
	done
	rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$W/root" "$W/ov/etc" "$W/run" "$W/share" "$W/stage"
mount -t tmpfs tmpfs "$W/root" || { echo "FATAL: cannot mount a tmpfs — no private mount namespace?"; exit 1; }
mkdir -p "$W/root/etc"

# Hashes of random throwaway strings, made here: nothing secret is committed.
mkhash() { head -c 18 /dev/urandom | base64 | openssl passwd -6 -stdin; }
IMG_HASH="$(mkhash)"; DEV_HASH="$(mkhash)"; DEV_HASH2="$(mkhash)"
{
	printf 'root:%s:19000:0:99999:7:::\n' "$IMG_HASH"
	printf 'daemon:*:19000:0:99999:7:::\n'
	printf 'nobody:*:19000:0:99999:7:::\n'
	printf 'svcroot:!:19000:0:99999:7:::\n'   # a later account whose name starts with "root" is not root
} > "$W/root/etc/shadow"
chmod 0600 "$W/root/etc/shadow"
cp "$W/root/etc/shadow" "$W/image-shadow.orig"

SH="$W/root/etc/shadow"
HF="$W/ov/etc/ga-root-pw-hash"
ST="$W/share/ga-root-shadow-status.json"
export GA_RS_ROOTFS="$W/root" GA_RS_OVERLAY="$W/ov" GA_RS_RUN_DIR="$W/run" \
	GA_RS_STATUS="$ST" GA_RS_CONSOLE="$W/console" GA_RS_BOOT_ID="test-boot" \
	GA_RS_UPTIME="$W/uptime" \
	GA_RS_PUBLISH="$OV/usr/libexec/ga-share-publish" GA_SHARE_STAGE_DIR="$W/stage"

rs() { "$TOOL" "$@" 2>>"$W/stderr"; }
mounts_on() { awk -v p="$1" '$5 == p' /proc/self/mountinfo | wc -l; }
root_field() { awk -F: '$1 == "root" { print $2 }' "$SH"; }
state() { sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p' "$ST" 2>/dev/null; }
others_identical() { [ "$(grep -v '^root:' "$SH")" = "$(grep -v '^root:' "$W/image-shadow.orig")" ]; }

# ── absent ────────────────────────────────────────────────────────────────
echo "4.20 3.10" > "$W/uptime"
rm -f "$HF" "$ST"; rs; RC=$?
run_test "RS-01" "no hash file → exit 0, nothing mounted, image hash in effect" \
	"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 0 ] && [ \"\$(root_field)\" = '$IMG_HASH' ]"
run_test "RS-02" "no hash file → status 'start'" "[ \"\$(state)\" = start ]"
run_test "RS-40" "the first run of a boot records its uptime and state" \
	"[ \"\$(cat '$W/run/boot')\" = '4.20 start' ]"
echo "99.00 3.10" > "$W/uptime"

# ── valid ─────────────────────────────────────────────────────────────────
printf '%s\n' "$DEV_HASH" > "$HF"; chmod 0600 "$HF"
rm -f "$ST"; rs; RC=$?
run_test "RS-03" "valid hash → exit 0 and exactly one bind mount on the shadow" \
	"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 1 ]"
run_test "RS-04" "valid hash → root's field is the device hash" "[ \"\$(root_field)\" = '$DEV_HASH' ]"
run_test "RS-05" "valid hash → every other line byte-identical (svcroot untouched)" "others_identical"
run_test "RS-06" "the merged copy is 0600" "[ \"\$(stat -c %a '$SH')\" = 600 ]"
run_test "RS-07" "valid hash → status 'rotated' with the boot id" \
	"[ \"\$(state)\" = rotated ] && grep -q '\"boot_id\": \"test-boot\"' '$ST'"
run_test "RS-41" "a later run in the same boot does not overwrite the boot record" \
	"[ \"\$(cat '$W/run/boot')\" = '4.20 start' ]"

# ── re-run (station sets a new hash without a reboot) ─────────────────────
printf '%s\n' "$DEV_HASH2" > "$HF"
rs; RC=$?
run_test "RS-08" "restart with a new hash → still exactly one mount, new hash in effect" \
	"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 1 ] && [ \"\$(root_field)\" = '$DEV_HASH2' ]"
run_test "RS-09" "restart → rebuilt from the IMAGE's shadow, not from the previous copy" "others_identical"

# ── malformed: loud, and never applied ────────────────────────────────────
malformed_case() { # <id> <desc> <content-writer>
	umount "$SH" 2>/dev/null; rm -f "$ST"
	eval "$3"
	rs; rc=$?
	run_test "$1" "$2 → exit 1, not applied, status 'malformed'" \
		"[ $rc -eq 1 ] && [ \$(mounts_on '$SH') -eq 0 ] && [ \"\$(root_field)\" = '$IMG_HASH' ] && [ \"\$(state)\" = malformed ]"
}
malformed_case "RS-10" "two hashes"        "printf '%s\n%s\n' '$DEV_HASH' '$DEV_HASH2' > '$HF'"
malformed_case "RS-11" "an MD5-crypt hash" "printf '\$1\$abcdefgh\$0123456789012345678901\n' > '$HF'"
malformed_case "RS-12" "an empty file"     ": > '$HF'"
malformed_case "RS-13" "a hash with a trailing field" "printf '%s:extra\n' '$DEV_HASH' > '$HF'"
malformed_case "RS-14" "a plain-text word" "printf 'notahash\n' > '$HF'"

# malformed while a good one is applied: the applied one stays (no silent
# fall-back to the image's password at runtime), and the status says malformed
umount "$SH" 2>/dev/null; printf '%s\n' "$DEV_HASH" > "$HF"; rs
printf 'garbage\n' > "$HF"; rs; RC=$?
run_test "RS-15" "malformed at runtime over an applied hash → exit 1, applied hash kept, status malformed" \
	"[ $RC -eq 1 ] && [ \"\$(root_field)\" = '$DEV_HASH' ] && [ \"\$(state)\" = malformed ]"

# ── removed at runtime ────────────────────────────────────────────────────
rm -f "$HF"; rs; RC=$?
run_test "RS-16" "hash file removed + restart → back to the image's shadow, status 'start'" \
	"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 0 ] && [ \"\$(root_field)\" = '$IMG_HASH' ] && [ \"\$(state)\" = start ]"

# ── no root line in the image ─────────────────────────────────────────────
cp "$SH" "$W/keep"; grep -v '^root:' "$W/keep" > "$SH"
printf '%s\n' "$DEV_HASH" > "$HF"; rs; RC=$?
run_test "RS-17" "image without a root line → exit 1, nothing mounted" \
	"[ $RC -eq 1 ] && [ \$(mounts_on '$SH') -eq 0 ]"
cp "$W/keep" "$SH"

# ── --early (D4b) ─────────────────────────────────────────────────────────
printf '%s\n' "$DEV_HASH" > "$HF"; rs
# The overlay now offers a DIFFERENT hash: a no-op must leave the applied one.
mount -t tmpfs tmpfs "$W/ov"; mkdir -p "$W/ov/etc"; printf '%s\n' "$DEV_HASH2" > "$HF"
rm -f "$ST"; rs --early; RC=$?
run_test "RS-20" "--early with the copy already mounted → no-op (applied hash kept, one mount, no status write)" \
	"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 1 ] && [ \"\$(root_field)\" = '$DEV_HASH' ] && [ ! -e '$ST' ]"

umount "$SH"
printf '%s\n' "$DEV_HASH" > "$HF"
rs --early; RC=$?
run_test "RS-21" "--early with the overlay mounted → applied from it" \
	"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 1 ] && [ \"\$(root_field)\" = '$DEV_HASH' ]"
run_test "RS-22" "--early publishes no status (the data partition may be absent)" "[ ! -e '$ST' ]"
umount "$SH"; umount "$W/ov"

: > "$W/console"
GA_RS_OVERLAY_DEV="$W/no-such-partition" rs --early; RC=$?
run_test "RS-23" "--early, partition unreadable → exit 0, image's shadow, banner on the console" \
	"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 0 ] && grep -q 'unreadable' '$W/console'"

if [ "${GA_RS_REAL_ROOT:-0}" = 1 ] && command -v mkfs.ext4 >/dev/null 2>&1; then
	IMG="$W/overlay.ext4"
	truncate -s 8M "$IMG" && mkfs.ext4 -q -L hassos-overlay "$IMG"
	mkdir -p "$W/seed" && mount -o loop "$IMG" "$W/seed" && mkdir -p "$W/seed/etc" \
		&& printf '%s\n' "$DEV_HASH2" > "$W/seed/etc/ga-root-pw-hash" && umount "$W/seed"
	LOOP="$(losetup -f --show "$IMG")"
	SUM_BEFORE="$(sha256sum < "$IMG")"
	GA_RS_OVERLAY_DEV="$LOOP" rs --early; RC=$?
	sync
	run_test "RS-24" "--early, overlay not mounted → partition mounted read-only, hash applied" \
		"[ $RC -eq 0 ] && [ \$(mounts_on '$SH') -eq 1 ] && [ \"\$(root_field)\" = '$DEV_HASH2' ]"
	run_test "RS-25" "--early leaves the partition unmounted again" \
		"! grep -q '^$LOOP ' /proc/self/mounts"
	run_test "RS-26" "--early did not write one byte to the partition (read-only, no journal replay)" \
		"[ \"\$(sha256sum < '$IMG')\" = '$SUM_BEFORE' ]"
	umount "$SH"; losetup -d "$LOOP"
elif [ "${GA_RS_REQUIRE_ALL:-0}" = 1 ]; then
	run_test "RS-24" "--early from an unmounted partition (needs real root + mkfs.ext4)" "false"
else
	skip_test "RS-24" "--early from an unmounted partition" "needs real root + mkfs.ext4"
fi

# ── the device suite's verdicts (verdicts.sh), must-pass and must-fail ─────
# test.sh measures on the device; these functions judge. They are the LIVE
# definitions test.sh sources, not a copy.
. "$HERE/verdicts.sh"
v() { "$@" >/dev/null 2>&1; echo $?; }
run_test "RS-50" "boot order: overlay 3.0s <= run 4.20s <= sysinit 6.0s → pass" \
	"[ \$(v rs_boot_order '4.20 rotated' 3000000 6000000) = 0 ]"
run_test "RS-51" "boot order: run after sysinit.target (a runtime-only run) → fail" \
	"[ \$(v rs_boot_order '61.33 rotated' 3000000 6000000) = 1 ]"
run_test "RS-52" "boot order: run before the overlay was mounted → fail" \
	"[ \$(v rs_boot_order '2.50 start' 3000000 6000000) = 1 ]"
run_test "RS-53" "boot order: no boot record (the unit did not run this boot) → fail" \
	"[ \$(v rs_boot_order '' 3000000 6000000) = 1 ]"
run_test "RS-54" "boot order: sysinit.target time unknown (0) → fail, never pass" \
	"[ \$(v rs_boot_order '4.20 rotated' 3000000 0) = 1 ]"
run_test "RS-55" "boot state: hash file + boot applied 'rotated' → pass" \
	"[ \$(v rs_boot_state '4.20 rotated' 1 0) = 0 ]"
run_test "RS-56" "boot state: hash file from before this boot, boot left 'start' → fail" \
	"[ \$(v rs_boot_state '4.20 start' 1 0) = 1 ]"
run_test "RS-57" "boot state: hash file written during this boot, boot left 'start' → undecided (2)" \
	"[ \$(v rs_boot_state '4.20 start' 1 1) = 2 ]"
run_test "RS-58" "boot state: hash file from before this boot + 'malformed' → fail" \
	"[ \$(v rs_boot_state '4.20 malformed' 1 0) = 1 ]"
run_test "RS-59" "boot state: no hash file + 'start' → pass; no hash file + 'rotated' → fail" \
	"[ \$(v rs_boot_state '4.20 start' 0) = 0 ] && [ \$(v rs_boot_state '4.20 rotated' 0) = 1 ]"

R="$W/ota-record"
rec() { printf 'slot=%s\nversion=%s\nhashsum=%s\n' "$1" "$2" "$3" > "$R"; }
rm -f "$R"
run_test "RS-60" "OTA: no previous record → undecided (2)" \
	"[ \$(v rs_ota_survival '$R' A 17.0 abc) = 2 ]"
rec A 17.0 abc
run_test "RS-61" "OTA: slot and version changed, same hash → pass" \
	"[ \$(v rs_ota_survival '$R' B 17.1 abc) = 0 ]"
run_test "RS-62" "OTA: slot and version changed, hash file gone → fail" \
	"[ \$(v rs_ota_survival '$R' B 17.1 none) = 1 ]"
run_test "RS-63" "OTA: hash file gone without an update → fail too" \
	"[ \$(v rs_ota_survival '$R' A 17.0 none) = 1 ]"
run_test "RS-64" "OTA: hash changed across the update → fail" \
	"[ \$(v rs_ota_survival '$R' B 17.1 def) = 1 ]"
run_test "RS-65" "OTA: nothing changed since the previous run → undecided (2)" \
	"[ \$(v rs_ota_survival '$R' A 17.0 abc) = 2 ]"
rec A 17.0 none
run_test "RS-66" "OTA: updated, but there was no device password before → undecided (2)" \
	"[ \$(v rs_ota_survival '$R' B 17.1 abc) = 2 ]"

# ── what the device suite PRINTS for a verdict (RSD-10b, RSD-11) ───────────
# The return codes above say nothing about the report. On BOSv1.5.0-rc1 the
# report was the defect: test.sh pasted the reason into an eval'd "echo '…'",
# the reason "…the image's password" closed the quote, and a correct PASS was
# printed as "unterminated quoted string" + FAIL. These cases drive the LIVE
# report functions test.sh calls (verdicts.sh) with reasons produced by the
# LIVE verdict functions, and compare the printed lines exactly.
# The subshell keeps the inner PASS/FAIL counts out of this suite's totals.
report() { ( _GREEN='' _RED='' _YELLOW='' _RESET=''; "$@" ) 2>&1; }
has_apostrophe() { case "$1" in *\'*) return 0 ;; esac; return 1; }
D10="the boot's own run applied what the hash file says"
D11="the device password survived the OS update"

M="$(rs_boot_state '4.20 start' 0)"; R=$?
OUT="$(report rs_report_boot_state "$R" "$M")"
EXP="$(printf '  PASS  RSD-10b: %s\n        -> %s' "$D10" "no hash file, the boot left the image's password")"
run_test "RS-70" "RSD-10b, reason with an apostrophe, pass → PASS and the reason verbatim" \
	'has_apostrophe "$M" && [ "$OUT" = "$EXP" ]'
M="$(rs_boot_state '4.20 rotated' 0)"; R=$?
OUT="$(report rs_report_boot_state "$R" "$M")"
EXP="$(printf '  FAIL  RSD-10b: %s\n        -> %s' "$D10" "no hash file, but the boot's own run ended in 'rotated'")"
run_test "RS-71" "RSD-10b, reason with apostrophes and quotes, fail → FAIL and the reason verbatim" \
	'has_apostrophe "$M" && [ "$OUT" = "$EXP" ]'
M="$(rs_boot_state '4.20 start' 1 1)"; R=$?
OUT="$(report rs_report_boot_state "$R" "$M")"
EXP="$(printf '  SKIP  RSD-10b: %s (%s)' "$D10" "$M")"
run_test "RS-72" "RSD-10b, undecided → SKIP with the reason" '[ "$R" = 2 ] && [ "$OUT" = "$EXP" ]'
Q="it's \"quoted\"; \$(false) \`false\` and a \\ backslash"
OUT="$(report rs_report_ota 0 "$Q" 0)"
EXP="$(printf '  PASS  RSD-11: %s\n        -> %s' "$D11" "$Q")"
run_test "RS-73" "RSD-11, pass with shell metacharacters in the reason → PASS, reason verbatim, nothing executed" \
	'[ "$OUT" = "$EXP" ]'
OUT="$(report rs_report_ota 1 "$Q" 0)"
EXP="$(printf '  FAIL  RSD-11: %s\n        -> %s' "$D11" "$Q")"
run_test "RS-74" "RSD-11, fail → FAIL and the reason verbatim" '[ "$OUT" = "$EXP" ]'
OUT="$(report rs_report_ota 2 "$Q" 1)"
EXP="$(printf '  FAIL  RSD-11: %s (GA_RS_EXPECT_OTA=1)\n        -> %s' "$D11" "$Q")"
run_test "RS-75" "RSD-11, undecided right after an update → FAIL and the reason" '[ "$OUT" = "$EXP" ]'
OUT="$(report rs_report_ota 2 "$Q" 0)"
EXP="$(printf '  SKIP  RSD-11: survival across an OS update (%s)' "$Q")"
run_test "RS-76" "RSD-11, undecided otherwise → SKIP with the reason" '[ "$OUT" = "$EXP" ]'
# test.sh must report through these functions, or the cases above test a path
# the device suite does not take.
T="$HERE/test.sh"
run_test "RS-77" "test.sh reports RSD-10b and RSD-11 through the functions pinned above" \
	"grep -q '^rs_report_boot_state \"\$BS_RC\" \"\$BS_MSG\"\$' '$T' && grep -q '^rs_report_ota \"\$OTA_RC\" \"\$OTA_MSG\"' '$T'"
no_quoted_echo() { ! grep -nF "echo '\$" "$1"; }
run_test "RS-78" "test.sh pastes no message into an eval'd single-quoted echo" "no_quoted_echo '$T'"

# ── the units ─────────────────────────────────────────────────────────────
unit_has() { grep -qx "$2" "$1"; }
run_test "RS-30" "unit runs before sysinit.target, after the overlay" \
	"unit_has '$UNIT' 'DefaultDependencies=no' && unit_has '$UNIT' 'Before=sysinit.target shutdown.target' && grep -q '^After=.*hassos-overlay.service' '$UNIT'"
run_test "RS-31" "unit is enabled (sysinit.target.wants link → the unit)" \
	"[ \"\$(readlink '$OV/etc/systemd/system/sysinit.target.wants/ga-root-shadow.service')\" = /usr/lib/systemd/system/ga-root-shadow.service ]"
for u in emergency rescue; do
	run_test "RS-32-$u" "$u.service runs ga-root-shadow --early before sulogin" \
		"unit_has '$OV/usr/lib/systemd/system/$u.service.d/ga-root-shadow.conf' 'ExecStartPre=-/usr/libexec/ga-root-shadow --early'"
done

suite_end
