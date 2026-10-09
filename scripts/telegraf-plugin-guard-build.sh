#!/bin/bash
# telegraf-plugin-guard-build.sh -- build-time wrapper around
# telegraf-plugin-guard.sh, called from buildroot-external/package/telegraf/
# telegraf.mk (TELEGRAF_POST_INSTALL_TARGET_HOOKS).
#
#   telegraf-plugin-guard-build.sh TARGET_DIR TELEGRAF_SRC_DIR STAGING_DIR QEMU_ARCH
#
# Why: telegraf is built with only the plugins GA's configs use (TELEGRAF_TAGS
# in telegraf.mk). A config naming a plugin the binary lacks makes telegraf
# refuse the WHOLE file on the device, so the unit restarts in a loop and sends
# no metrics at all. This fails the build instead.
#
# 1. Self-test of the guard against the binary just built, on the committed
#    fixtures in package/telegraf/guard-fixtures/:
#      must-fail/*.conf, must-fail-slim/*.conf
#                       -- the guard must exit 1 AND report the SPECIFIC finding:
#                          "# expect-missing: <kind.name>" (static or exec plugin
#                          check) or "# expect-error: <ERE>" (a line of
#                          `telegraf config check` output; exec only -- skipped
#                          with a WARNING when the exec check cannot run);
#      must-pass/*.conf -- the guard must exit 0.
#    A guard that cannot go red, or cannot go green, fails the build.
# 2. The real check: every *.conf in TARGET_DIR/etc/telegraf against
#    TARGET_DIR/usr/bin/telegraf. Fails closed on zero configs.
set -u
TARGET_DIR=${1:?TARGET_DIR}; SRC=${2:?telegraf src dir}; SYSROOT=${3:?staging dir}; QARCH=${4:-}
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
GUARD=$HERE/telegraf-plugin-guard.sh
FIX=$HERE/../buildroot-external/package/telegraf/guard-fixtures
BIN=$TARGET_DIR/usr/bin/telegraf
die() { echo "telegraf-plugin-guard-build: FAIL: $*" >&2; exit 1; }
[ -x "$GUARD" ] || die "guard $GUARD not found"
[ -f "$BIN" ] || die "no telegraf binary at $BIN"

q=()
QEMU=""
[ -n "$QARCH" ] && QEMU=$(command -v "qemu-$QARCH" 2>/dev/null || true)
if [ -n "$QEMU" ]; then
    q=(--qemu "$QEMU" --sysroot "$SYSROOT")
else
    echo "telegraf-plugin-guard-build: WARNING: no qemu-${QARCH:-?} on the build host -- the exec check (telegraf plugins / config check) may be SKIPPED, the static check still runs" >&2
fi
run_guard() { "$GUARD" --binary "$BIN" --src "$SRC" "${q[@]}" "$@" 2>&1; }

# Does the exec half run on this host? Ask the guard itself (must-pass fixture).
shopt -s nullglob
fails=("$FIX"/must-fail/*.conf "$FIX"/must-fail-slim/*.conf); passes=("$FIX"/must-pass/*.conf)
{ [ ${#fails[@]} -gt 0 ] && [ ${#passes[@]} -gt 0 ]; } || die "guard fixtures missing in $FIX (must-fail: ${#fails[@]}, must-pass: ${#passes[@]})"
exec_ok=1
run_guard "${passes[0]}" | grep -q 'exec check SKIPPED' && exec_ok=0

# --- 1. self-test on fixtures ------------------------------------------------
n_red=0
for f in "${fails[@]}"; do
    name=${f#"$FIX"/}
    miss=$(sed -n 's/^# expect-missing: *//p' "$f" | head -1)
    err=$(sed -n 's/^# expect-error: *//p' "$f" | head -1)
    { [ -n "$miss" ] || [ -n "$err" ]; } || die "fixture $name has neither '# expect-missing:' nor '# expect-error:'"
    if [ -n "$err" ] && [ -z "$miss" ] && [ $exec_ok -eq 0 ]; then
        echo "telegraf-plugin-guard-build: WARNING: self-test SKIPPED for $name (expects a config-check error; exec check cannot run here)" >&2
        continue
    fi
    out=$(run_guard "$f"); rc=$?
    ok=1
    [ $rc -eq 1 ] || ok=0
    if [ -n "$miss" ]; then printf '%s\n' "$out" | grep -qF "MISSING ${miss} " || ok=0; fi
    if [ -n "$err" ] && [ $exec_ok -eq 1 ]; then printf '%s\n' "$out" | grep -qE "$err" || ok=0; fi
    if [ $ok -ne 1 ]; then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        die "self-test: must-fail fixture $name did not fail with the expected finding (rc=$rc)"
    fi
    n_red=$((n_red + 1))
    echo "telegraf-plugin-guard-build: self-test red OK: $name ->${miss:+ MISSING $miss}${err:+ error /$err/}"
done
[ $n_red -gt 0 ] || die "self-test: no must-fail fixture ran -- the guard was never shown to go red"
for f in "${passes[@]}"; do
    out=$(run_guard "$f"); rc=$?
    if [ $rc -ne 0 ]; then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        die "self-test: must-pass fixture ${f#"$FIX"/} failed (rc=$rc)"
    fi
    echo "telegraf-plugin-guard-build: self-test green OK: ${f#"$FIX"/}"
done

# --- 2. the shipped configs ---------------------------------------------------
confs=("$TARGET_DIR"/etc/telegraf/*.conf)
[ ${#confs[@]} -gt 0 ] || die "no *.conf in $TARGET_DIR/etc/telegraf -- nothing to check"
"$GUARD" --binary "$BIN" --src "$SRC" "${q[@]}" "${confs[@]}" \
    || die "shipped telegraf configs name plugins the binary lacks, or do not load (see above) -- add the plugin to TELEGRAF_GA_PLUGINS in telegraf.mk"
echo "telegraf-plugin-guard-build: OK -- ${#confs[@]} shipped config(s), self-test ${n_red} red / ${#passes[@]} green"
