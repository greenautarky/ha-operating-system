#!/bin/bash
# telegraf-plugin-guard.sh -- fail the build if a shipped telegraf config names
# a plugin the (slim) telegraf binary does not contain.
#
# Why: telegraf is built with `-tags custom,inputs.cpu,...` (only the plugins GA
# configures; ~22 MB instead of ~270 MB). A plugin added to a config but not to
# TELEGRAF_GA_PLUGINS makes telegraf refuse the WHOLE config on the device
# ("undefined but requested input") -> the unit crash-loops -> no metrics at
# all, and a missing metric looks exactly like a quiet fleet.
#
#   telegraf-plugin-guard.sh --binary BIN --src TELEGRAF_SRC_DIR
#                            [--qemu QEMU_USER_BIN --sysroot DIR] CONF...
#
# Two independent checks; the expected set is ALWAYS read from the CONF files
# (the artefacts that ship), never from the tag list the binary was built with.
#   1. static (always, any build host): for each plugin named in a CONF, find
#      the package that registers it in the telegraf source (<kind>.Add("name"))
#      and require that package's init function in the binary's pclntab
#      (survives `strip`).
#   2. exec (when a qemu-user binary is given, or the binary runs natively):
#      `telegraf plugins` must list every required plugin, and
#      `telegraf config check` must load every CONF without an error line.
#      Both the exit code (1 on a load error, 2 on a panic, measured on
#      1.38.0) AND the output (" E! " / "panic:" lines, "Loading config"
#      present) are checked -- either alone could go green while broken.
# If neither qemu nor native exec is possible, check 2 is skipped LOUDLY.
#
# Exit: 0 = every plugin present (and every config loads, if exec ran);
#       1 = a plugin is missing / a config does not load; 2 = usage/coverage.
set -u

BIN='' SRC='' QEMU='' SYSROOT=''
CONFS=()
while [ $# -gt 0 ]; do
    case $1 in
        --binary) BIN=$2; shift 2;;
        --src) SRC=$2; shift 2;;
        --qemu) QEMU=$2; shift 2;;
        --sysroot) SYSROOT=$2; shift 2;;
        -*) echo "telegraf-plugin-guard: unknown option $1" >&2; exit 2;;
        *) CONFS+=("$1"); shift;;
    esac
done
die2() { echo "telegraf-plugin-guard: FAIL: $*" >&2; exit 2; }
[ -f "$BIN" ] || die2 "binary '$BIN' not found"
[ -d "$SRC/plugins" ] || die2 "telegraf source '$SRC' has no plugins/ dir"
[ ${#CONFS[@]} -gt 0 ] || die2 "no config files given"
for c in "${CONFS[@]}"; do [ -f "$c" ] || die2 "config '$c' not found"; done

# --- required plugin set, from the configs ---------------------------------
# [[inputs.x]] / [[outputs.x]] / [[processors.x]] / [[aggregators.x]] /
# [[secretstores.x]] tables (comments stripped), and data_format = "y" inside
# an input/processor (-> parsers.y) or output (-> serializers.y).
required=$(awk '
    { sub(/#.*/, "") }
    match($0, /^[ \t]*\[\[(inputs|outputs|processors|aggregators|secretstores)\.[A-Za-z0-9_]+\]\]/) {
        t = $0; gsub(/[][ \t]/, "", t); print t
        split(t, a, "."); kind = a[1]; next
    }
    /^[ \t]*\[/ { kind = "" }
    /^[ \t]*data_format[ \t]*=/ {
        v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/["\x27 \t]/, "", v)
        if (kind == "inputs" || kind == "processors") print "parsers." v
        else if (kind == "outputs") print "serializers." v
    }' "${CONFS[@]}" | sort -u)
n_req=$(printf '%s\n' "$required" | grep -c .)
[ "$n_req" -gt 0 ] || die2 "parsed 0 plugins from ${CONFS[*]} -- refusing to pass an empty check"
echo "telegraf-plugin-guard: ${n_req} plugin(s) named in ${#CONFS[@]} config(s): $(printf '%s\n' "$required" | tr '\n' ' ')"

fail=0

# --- check 1: static (source registration -> init symbol in the binary) ----
n_static=0
for p in $required; do
    kind=${p%%.*}; name=${p#*.}
    f=$(grep -rlE --include='*.go' "^[[:space:]]*${kind}\.(Add|AddStreaming)\(\"${name}\"" "$SRC/plugins/$kind" 2>/dev/null \
        | grep -v '_test\.go$' | head -1)
    if [ -z "$f" ]; then
        echo "telegraf-plugin-guard: MISSING $p -- no such plugin in this telegraf source" >&2
        fail=1; continue
    fi
    pkg=$(basename "$(dirname "$f")")
    if grep -q -a -F "github.com/influxdata/telegraf/plugins/${kind}/${pkg}.init" "$BIN"; then
        n_static=$((n_static + 1))
    else
        echo "telegraf-plugin-guard: MISSING $p -- package plugins/${kind}/${pkg} is not compiled into $(basename "$BIN") (add it to TELEGRAF_GA_PLUGINS)" >&2
        fail=1
    fi
done
echo "telegraf-plugin-guard: static: ${n_static}/${n_req} present"

# --- check 2: exec (telegraf's own plugin list + config loader) ------------
run=()
if [ -n "$QEMU" ]; then
    [ -x "$QEMU" ] || die2 "qemu '$QEMU' not executable"
    [ -d "$SYSROOT" ] || die2 "--qemu needs --sysroot"
    run=("$QEMU" -L "$SYSROOT" "$BIN")
elif "$BIN" --version >/dev/null 2>&1; then
    run=("$BIN")
fi
if [ ${#run[@]} -eq 0 ]; then
    echo "telegraf-plugin-guard: WARNING: exec check SKIPPED (no qemu-user for this target arch on the build host, binary not native) -- only the static check ran" >&2
else
    have=$("${run[@]}" plugins 2>/dev/null)
    n_have=$(printf '%s\n' "$have" | grep -c .)
    [ "$n_have" -gt 0 ] || { echo "telegraf-plugin-guard: FAIL: 'telegraf plugins' listed nothing" >&2; fail=1; }
    n_exec=0
    for p in $required; do
        if printf '%s\n' "$have" | grep -qxF "$p"; then n_exec=$((n_exec + 1))
        else echo "telegraf-plugin-guard: MISSING $p -- not in 'telegraf plugins'" >&2; fail=1; fi
    done
    echo "telegraf-plugin-guard: exec: ${n_exec}/${n_req} listed by 'telegraf plugins' (${n_have} compiled in)"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/tg-guard.XXXXXX") || die2 "mktemp"
    mkdir -p "$tmp/buffer"
    for c in "${CONFS[@]}"; do
        # the disk buffer opens its WAL while loading; point it at a scratch dir
        sed -E "s|^([[:space:]]*buffer_directory[[:space:]]*=).*|\1 \"$tmp/buffer\"|" "$c" > "$tmp/check.conf"
        out=$("${run[@]}" config check --config "$tmp/check.conf" 2>&1); rc=$?
        if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -q 'Loading config' \
           || printf '%s\n' "$out" | grep -qE ' E! |^panic:'; then
            echo "telegraf-plugin-guard: FAIL: 'telegraf config check' rejects $(basename "$c") (rc=$rc):" >&2
            printf '%s\n' "$out" | grep -E ' E! |^panic:' | head -5 | sed 's/^/    /' >&2
            fail=1
        else
            echo "telegraf-plugin-guard: config check OK: $(basename "$c")"
        fi
    done
    rm -rf "$tmp"
fi

if [ $fail -ne 0 ]; then
    echo "telegraf-plugin-guard: FAIL" >&2
    exit 1
fi
echo "telegraf-plugin-guard: OK"
