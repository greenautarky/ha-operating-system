#!/bin/bash
# fluent-bit-plugin-guard.sh -- the minimal fluent-bit build contains exactly the
# plugins the shipped configs need, and not the Forward plugins.
#
# Why: buildroot-external/package/fluent-bit-config/fluent-bit-config.mk builds
# fluent-bit with -DFLB_MINIMAL=On plus one -D<switch>=On per plugin in
# FLUENT_BIT_GA_PLUGINS (the Forward output has an upstream advisory with no
# patched version, so the code is not built). Two things go wrong silently:
#   * a plugin a config names but the build lacks: fluent-bit refuses the WHOLE
#     config ("invalid plugin"), the unit crash-loops, and a device that ships no
#     logs looks exactly like a quiet device;
#   * a switch that cmake turns off by itself (FLB_IN_SYSTEMD is forced OFF when
#     libsystemd is not in the sysroot at configure time): the build succeeds
#     without the journal input.
#
#   fluent-bit-plugin-guard.sh --binary BIN [--mk FILE]
#       BIN must contain the registration text of every plugin in
#       FLUENT_BIT_GA_PLUGINS (read from FILE, default: the fluent-bit-config.mk
#       of this tree) and none of the forbidden ones. Works on a stripped,
#       cross-compiled binary: it reads the plugin descriptions the binary
#       carries, it does not run it.
#   fluent-bit-plugin-guard.sh --configs CONF... [--mk FILE]
#       every plugin the CONFs name (Name of an [INPUT]/[FILTER]/[OUTPUT]) must
#       be in FLUENT_BIT_GA_PLUGINS, and the list must not contain a forbidden
#       switch.
#
# The expected set is ALWAYS read from the live .mk and the live configs, never
# from the binary under test.
#
# Exit: 0 = ok; 1 = a plugin is missing / forbidden / not built; 2 = could not
# check (no strings(1), unreadable input, empty list, a switch without a needle).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MK="$HERE/../buildroot-external/package/fluent-bit-config/fluent-bit-config.mk"
BIN='' MODE=''
CONFS=()
while [ $# -gt 0 ]; do
    case $1 in
        --binary) MODE=binary; BIN=$2; shift 2;;
        --configs) MODE=configs; shift;;
        --mk) MK=$2; shift 2;;
        -*) echo "fluent-bit-plugin-guard: unknown option $1" >&2; exit 2;;
        *) CONFS+=("$1"); shift;;
    esac
done
die2() { echo "fluent-bit-plugin-guard: FAIL (cannot check): $*" >&2; exit 2; }
[ -n "$MODE" ] || die2 "usage: --binary BIN | --configs CONF..."
[ -f "$MK" ] || die2 "$MK not found"

# switch -> text the plugin registers about itself (its description). Exactly one
# line in `strings -a` output. Measured on fluent-bit 3.2.10 builds.
declare -A NEEDLE=(
    [FLB_IN_SYSTEMD]='Systemd (Journal) reader'
    [FLB_IN_TAIL]='Tail files'
    [FLB_IN_KMSG]='Kernel Log Buffer'
    [FLB_IN_EXEC]='Exec Input'
    [FLB_FILTER_GREP]='grep events by specified field values'
    [FLB_FILTER_RECORD_MODIFIER]='modify record'
    [FLB_FILTER_MODIFY]='modify records by applying rules'
    [FLB_OUT_LOKI]='Loki'
)
# storage_backlog registers no description of its own; fluent-bit prints a build
# flag for it ("Build Flags = ... FLB_HAVE_IN_STORAGE_BACKLOG ...").
declare -A NEEDLE_CONTAINS=(
    [FLB_IN_STORAGE_BACKLOG]='FLB_HAVE_IN_STORAGE_BACKLOG'
)
# Never built: switch, and the description text of that plugin.
FORBIDDEN_SWITCH=(FLB_OUT_FORWARD FLB_IN_FORWARD)
FORBIDDEN_NEEDLE=('Forward (Fluentd protocol)' 'Fluentd in-forward')

# The live list: FLUENT_BIT_GA_PLUGINS = A B \<newline> C D ...
LIST="$(sed -n '/^FLUENT_BIT_GA_PLUGINS[[:space:]]*=/,/[^\\]$/p' "$MK" | sed 's/^[^=]*=//; s/\\$//' | tr -s ' \t\n' ' ')"
read -r -a SWITCHES <<<"$LIST"
[ ${#SWITCHES[@]} -ge 1 ] || die2 "FLUENT_BIT_GA_PLUGINS not found (or empty) in $MK -- layout changed?"
for s in "${SWITCHES[@]}"; do
    [[ $s =~ ^FLB_(IN|FILTER|OUT)_[A-Z0-9_]+$ ]] || die2 "'$s' in FLUENT_BIT_GA_PLUGINS is not a plugin switch"
done

rc=0
fail() { echo "fluent-bit-plugin-guard: FAIL: $*" >&2; rc=1; }

for s in "${SWITCHES[@]}"; do
    for f in "${FORBIDDEN_SWITCH[@]}"; do
        [ "$s" = "$f" ] && fail "$s is in FLUENT_BIT_GA_PLUGINS -- the Forward plugins must not be built"
    done
done

if [ "$MODE" = configs ]; then
    [ ${#CONFS[@]} -ge 1 ] || die2 "no config files given"
    for c in "${CONFS[@]}"; do [ -f "$c" ] || die2 "config '$c' not found"; done
    # Name of each [INPUT]/[FILTER]/[OUTPUT] section, comments stripped.
    required="$(awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        /^[[:space:]]*\[/ {sect=toupper($1); next}
        tolower($1)=="name" && (sect=="[INPUT]" || sect=="[FILTER]" || sect=="[OUTPUT]") {
            k = (sect=="[INPUT]") ? "IN" : (sect=="[FILTER]") ? "FILTER" : "OUT"
            print "FLB_" k "_" toupper($2)
        }' "${CONFS[@]}" | sort -u)"
    [ -n "$required" ] || die2 "the configs name no plugin at all -- parser or layout changed?"
    n=0
    while IFS= read -r want; do
        n=$((n + 1))
        found=0
        for s in "${SWITCHES[@]}"; do [ "$s" = "$want" ] && found=1; done
        [ $found -eq 1 ] || fail "a config names a plugin that is not built: $want (add it to FLUENT_BIT_GA_PLUGINS)"
    done <<<"$required"
    echo "fluent-bit-plugin-guard: $n plugin(s) named by ${#CONFS[@]} config(s), ${#SWITCHES[@]} built"
    [ $rc -eq 0 ] && echo "fluent-bit-plugin-guard: OK -- every named plugin is built, no Forward plugin"
    exit $rc
fi

# --- binary ------------------------------------------------------------------
[ -f "$BIN" ] || die2 "binary '$BIN' not found"
command -v strings >/dev/null 2>&1 || die2 "strings(1) not found (binutils)"
STR="$(mktemp "${TMPDIR:-/tmp}/fb-guard.XXXXXX")" || die2 "mktemp"
trap 'rm -f "$STR"' EXIT
strings -a "$BIN" > "$STR" || die2 "strings failed on $BIN"
[ -s "$STR" ] || die2 "strings read nothing from $BIN"

for s in "${SWITCHES[@]}"; do
    if [ -n "${NEEDLE[$s]:-}" ]; then
        grep -Fxq -- "${NEEDLE[$s]}" "$STR" \
            || fail "$s is in FLUENT_BIT_GA_PLUGINS but the binary does not contain it (text: '${NEEDLE[$s]}') -- cmake turned it off?"
    elif [ -n "${NEEDLE_CONTAINS[$s]:-}" ]; then
        grep -Fq -- "${NEEDLE_CONTAINS[$s]}" "$STR" \
            || fail "$s is in FLUENT_BIT_GA_PLUGINS but the binary does not contain it ('${NEEDLE_CONTAINS[$s]}')"
    else
        die2 "no needle for $s -- add its description to the table in this script"
    fi
done
for n in "${FORBIDDEN_NEEDLE[@]}"; do
    ! grep -Fxq -- "$n" "$STR" || fail "the binary contains a plugin that must not be built ('$n')"
done
echo "fluent-bit-plugin-guard: ${#SWITCHES[@]} plugin(s) expected, binary checked: $BIN"
[ $rc -eq 0 ] && echo "fluent-bit-plugin-guard: OK -- every expected plugin is in the binary, no Forward plugin"
exit $rc
