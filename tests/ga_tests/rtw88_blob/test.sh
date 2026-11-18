#!/bin/sh
# rtw88_blob (Odoo #2186): the DSGW-210 image keeps exactly rtw8821c_fw.bin.
# Host test: the REAL post-build hook against a fake TARGET_DIR. On-device: device.sh.
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOK="$ROOT/buildroot-dsgw210/board/dusun/dsgw210/post-build.d/60-rtw88-single-blob.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
PASS() { echo "  PASS  $1"; pass=$((pass+1)); }
FAIL() { echo "  FAIL  $1 ($2)"; fail=$((fail+1)); }
mk() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/lib/firmware/rtw88"; for b in "$@"; do echo x > "$WORK/t/lib/firmware/rtw88/$b"; done; }
echo "=== rtw88 single blob (Odoo #2186) ==="
mk rtw8703b_fw.bin rtw8703b_wow_fw.bin rtw8723d_fw.bin rtw8812a_fw.bin rtw8814a_fw.bin rtw8821a_fw.bin rtw8821c_fw.bin rtw8822b_fw.bin rtw8822c_fw.bin rtw8822c_wow_fw.bin
sh "$HOOK" "$WORK/t" > "$WORK/out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(ls "$WORK/t/lib/firmware/rtw88")" = rtw8821c_fw.bin ] && PASS "the measured 10-blob set is pruned to exactly rtw8821c_fw.bin" || FAIL "prune" "rc=$rc $(ls "$WORK/t/lib/firmware/rtw88")"
grep -q "removed 9 other" "$WORK/out" && PASS "it reports how many it removed (8)" || FAIL "report" "$(cat "$WORK/out")"
mk rtw8822c_fw.bin; sh "$HOOK" "$WORK/t" > "$WORK/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q "missing" "$WORK/out" && PASS "rtw8821c_fw.bin missing: the build fails (exit 1), nothing pretends to work" || FAIL "fail closed" "rc=$rc"
mk rtw8821c_fw.bin; mkdir -p "$WORK/t/lib/firmware/rtw88/sub"; echo x > "$WORK/t/lib/firmware/rtw88/.hidden"; sh "$HOOK" "$WORK/t" >/dev/null 2>&1
[ "$(find "$WORK/t/lib/firmware/rtw88" -mindepth 1 | wc -l)" = 1 ] && PASS "sub-directories and hidden files go too" || FAIL "extras" "$(find "$WORK/t/lib/firmware/rtw88" -mindepth 1)"
sh "$HOOK" "" >/dev/null 2>&1 && FAIL "no TARGET_DIR" "exit 0" || PASS "no TARGET_DIR: exit != 0"
[ -x "$HOOK" ] && PASS "hook is executable (post-build.sh refuses non-executables)" || FAIL "exec bit" "not executable"
[ -z "$(find "$ROOT/buildroot-ihost" "$ROOT/buildroot-external" -name '*rtw88-single-blob*' 2>/dev/null | head -1)" ] && PASS "iHost / shared tree untouched (DSGW post-build.d only)" || FAIL "iHost" "found"
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
