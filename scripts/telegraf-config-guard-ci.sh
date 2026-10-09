#!/bin/bash
# telegraf-config-guard-ci.sh -- PR-time check that every telegraf config the
# image ships is accepted by the telegraf version the image builds.
#
# Why: telegraf refuses the WHOLE config file on one unknown option or plugin
# ("configuration specified the fields [...] but they were not used"). The
# unit then does not start and the device sends no metrics at all -- which
# looks exactly like a quiet device. telegraf-debug.conf carried such an option
# (`perdevice`, removed in 1.38) for as long as 1.38 has been the built version.
#
# How: download the OFFICIAL linux/amd64 release of the version telegraf.mk
# builds (sha256 pinned below), plus its source archive, and run
# scripts/telegraf-plugin-guard.sh (ported unchanged from the Dusun tree,
# exp/1.6-telegraf-slim) against the shipped configs:
#   - static: every plugin a config names is registered in the source and
#     compiled into the binary;
#   - exec:   `telegraf plugins` lists it and `telegraf config check` loads
#     each config without an error line.
# Config parsing is the same Go code on every architecture, so the amd64
# release binary of the same tag runs natively on a CI runner without qemu.
# The image builds a reduced ("slim") telegraf: only TELEGRAF_GA_PLUGINS
# (telegraf.mk) are compiled in, while the official release has every plugin.
# So step 0 compares the configs' plugin set with that list, and the bake's
# post-install hook (scripts/telegraf-plugin-guard-build.sh) checks the configs
# against the armv7 binary it actually built. What THIS script does not prove:
# that the bake's binary contains the list (that is the build hook's job).
#
# 1. Self-test on committed fixtures (package/telegraf/guard-fixtures/):
#      must-fail/*.conf -- the guard must exit 1 AND report the SPECIFIC finding
#                          named by "# expect-missing: <kind.name>" (static/exec
#                          plugin check) or "# expect-error: <ERE>" (a line of
#                          `telegraf config check` output);
#      must-pass/*.conf -- the guard must exit 0.
# 2. The real check over package/telegraf/*.conf. Fails closed when the two
#    configs telegraf.mk installs are missing, or the exec check was skipped.
#
#   telegraf-config-guard-ci.sh [WORKDIR]      (default: mktemp -d)
#
# Bumping TELEGRAF_VERSION: add the new version's two hashes to pins() --
# binary hash from the release notes on github.com/influxdata/telegraf, source
# hash measured as in telegraf.hash. An unknown version fails here on purpose.
set -u
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PKG=$ROOT/buildroot-external/package/telegraf
GUARD=$HERE/telegraf-plugin-guard.sh
FIX=$PKG/guard-fixtures
die() { echo "telegraf-config-guard: FAIL: $*" >&2; exit 1; }

VERSION=$(sed -n 's/^TELEGRAF_VERSION[[:space:]]*=[[:space:]]*//p' "$PKG/telegraf.mk" | head -1)
[ -n "$VERSION" ] || die "cannot read TELEGRAF_VERSION from $PKG/telegraf.mk"

# --- 0. configs vs the build's plugin list (slim build) ----------------------
# telegraf.mk compiles in only TELEGRAF_GA_PLUGINS. A config naming a plugin
# outside that list passes the official-binary check below (it has every
# plugin) and fails only in the bake, hours later. Compare the two sources
# here, before any download. The config side is parsed by the guard itself
# (--list-required), never by a copy of its parser.
TAGS=$(awk '
    /^TELEGRAF_GA_PLUGINS[[:space:]]*=/ { on = 1; sub(/^[^=]*=/, "") }
    on { cont = ($0 ~ /\\[[:space:]]*$/); gsub(/\\/, ""); n = split($0, w, /[[:space:]]+/)
         for (i = 1; i <= n; i++) if (w[i] != "") print w[i]
         if (!cont) on = 0 }' "$PKG/telegraf.mk" | sort -u)
n_tags=$(printf '%s\n' "$TAGS" | grep -c .)
[ "$n_tags" -gt 0 ] || die "parsed 0 plugins from TELEGRAF_GA_PLUGINS in $PKG/telegraf.mk"
grep -qE '^TELEGRAF_TAGS[[:space:]]*\+=[[:space:]]*custom[[:space:]]+\$\(TELEGRAF_GA_PLUGINS\)' "$PKG/telegraf.mk" \
    || die "telegraf.mk does not build with TELEGRAF_TAGS += custom \$(TELEGRAF_GA_PLUGINS) -- the list below would not be what is compiled"
not_in_list() {  # CONF... -> plugins the configs name that the build does not compile in
    local req
    req=$("$GUARD" --list-required "$@") || die "guard --list-required failed on $*"
    comm -23 <(printf '%s\n' "$req") <(printf '%s\n' "$TAGS")
}
slim_fails=("$FIX"/must-fail-slim/*.conf)
[ -f "${slim_fails[0]}" ] || die "no must-fail-slim fixtures in $FIX"
for f in "${slim_fails[@]}"; do
    want=$(sed -n 's/^# expect-missing: *//p' "$f" | head -1)
    [ -n "$want" ] || die "fixture $(basename "$f") has no '# expect-missing:' line"
    not_in_list "$f" | grep -qxF "$want" \
        || die "self-test: plugin-list check does not report $want for must-fail-slim/$(basename "$f")"
    echo "telegraf-config-guard: plugin-list self-test red OK: $(basename "$f") -> $want not in TELEGRAF_GA_PLUGINS"
done
for f in "$FIX"/must-pass/*.conf; do
    [ -z "$(not_in_list "$f")" ] || die "self-test: plugin-list check flags must-pass/$(basename "$f")"
    echo "telegraf-config-guard: plugin-list self-test green OK: $(basename "$f")"
done
missing=$(not_in_list "$PKG"/*.conf)
if [ -n "$missing" ]; then
    printf 'telegraf-config-guard: MISSING %s -- named in a shipped config, not in TELEGRAF_GA_PLUGINS (telegraf.mk)\n' $missing >&2
    die "shipped configs name plugins the slim build does not compile in"
fi
echo "telegraf-config-guard: plugin list OK -- every plugin the shipped configs name is in TELEGRAF_GA_PLUGINS (${n_tags} compiled in)"

pins() {
    case $1 in
        1.38.0)
            BIN_SHA=57e6d733de44335127c06d9d9099c9dee7307beff992783438ce38b9ba1b8e5e
            SRC_SHA=18e3d7ba0a8e8ac1c8e8b619a5d97a704cfc9ea3cb49903d3894f0259e2f4a1a ;;
        *) return 1 ;;
    esac
}
pins "$VERSION" || die "no pinned hashes for telegraf $VERSION (telegraf.mk) -- add them to pins() in $(basename "$0")"

WORK=${1:-$(mktemp -d "${TMPDIR:-/tmp}/tg-cfg-guard.XXXXXX")}
mkdir -p "$WORK"
fetch() {  # url file sha
    if [ ! -f "$WORK/$2" ] || ! echo "$3  $WORK/$2" | sha256sum -c --status; then
        curl -fsSL --retry 3 -o "$WORK/$2" "$1" || die "download $1"
    fi
    echo "$3  $WORK/$2" | sha256sum -c - || die "sha256 mismatch for $2"
}
BIN_TGZ=telegraf-${VERSION}_linux_amd64.tar.gz
SRC_TGZ=telegraf-src-v${VERSION}.tar.gz
fetch "https://dl.influxdata.com/telegraf/releases/$BIN_TGZ" "$BIN_TGZ" "$BIN_SHA"
fetch "https://github.com/influxdata/telegraf/archive/refs/tags/v${VERSION}.tar.gz" "$SRC_TGZ" "$SRC_SHA"
rm -rf "${WORK:?}/bin" "${WORK:?}/src"; mkdir -p "$WORK/bin" "$WORK/src"
tar xzf "$WORK/$BIN_TGZ" -C "$WORK/bin" || die "extract $BIN_TGZ"
tar xzf "$WORK/$SRC_TGZ" -C "$WORK/src" || die "extract $SRC_TGZ"
BIN=$(find "$WORK/bin" -path '*/usr/bin/telegraf' -type f | head -1)
SRC=$(find "$WORK/src" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -x "$BIN" ] || die "no usr/bin/telegraf in $BIN_TGZ"

# The binary must BE the version telegraf.mk builds -- compare, do not assume.
got=$("$BIN" --version 2>&1)
case $got in "Telegraf $VERSION "*) ;; *) die "binary reports '$got', telegraf.mk builds $VERSION" ;; esac
echo "telegraf-config-guard: binary: $got (official linux/amd64, sha256 $BIN_SHA)"

# Configs reference ${VAR}s the device fills from ga-telegraf-env. Dummy values
# only -- this loads the config, it never connects anywhere with them.
for v in $(grep -ohE '\$\{[A-Z_][A-Z0-9_]*' "$PKG"/*.conf "$FIX"/*/*.conf | sed 's/^\${//' | sort -u); do
    [ -n "${!v:-}" ] || export "$v=guard-dummy"
done

run_guard() { "$GUARD" --binary "$BIN" --src "$SRC" "$@" 2>&1; }

# --- 1. self-test on fixtures ------------------------------------------------
shopt -s nullglob
fails=("$FIX"/must-fail/*.conf); passes=("$FIX"/must-pass/*.conf)
{ [ ${#fails[@]} -gt 0 ] && [ ${#passes[@]} -gt 0 ]; } || die "guard fixtures missing in $FIX (must-fail: ${#fails[@]}, must-pass: ${#passes[@]})"
for f in "${fails[@]}"; do
    miss=$(sed -n 's/^# expect-missing: *//p' "$f" | head -1)
    err=$(sed -n 's/^# expect-error: *//p' "$f" | head -1)
    { [ -n "$miss" ] || [ -n "$err" ]; } || die "fixture $(basename "$f") has neither '# expect-missing:' nor '# expect-error:'"
    out=$(run_guard "$f"); rc=$?
    ok=1
    [ $rc -eq 1 ] || ok=0
    if [ -n "$miss" ]; then printf '%s\n' "$out" | grep -qF "MISSING ${miss} " || ok=0; fi
    if [ -n "$err" ]; then printf '%s\n' "$out" | grep -qE "$err" || ok=0; fi
    if [ $ok -ne 1 ]; then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        die "self-test: must-fail fixture $(basename "$f") did not fail with the expected finding (rc=$rc)"
    fi
    echo "telegraf-config-guard: self-test red OK: $(basename "$f") -> ${miss:+MISSING $miss}${err:+error /$err/}"
done
for f in "${passes[@]}"; do
    out=$(run_guard "$f"); rc=$?
    if [ $rc -ne 0 ] || printf '%s\n' "$out" | grep -q 'exec check SKIPPED'; then
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        die "self-test: must-pass fixture $(basename "$f") failed (rc=$rc)"
    fi
    echo "telegraf-config-guard: self-test green OK: $(basename "$f")"
done

# --- 2. the shipped configs ---------------------------------------------------
for c in telegraf.conf telegraf-debug.conf; do
    [ -f "$PKG/$c" ] || die "$PKG/$c missing -- telegraf.mk installs it"
done
confs=("$PKG"/*.conf)
out=$(run_guard "${confs[@]}"); rc=$?
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q 'exec check SKIPPED' && die "exec check was skipped -- config check did not run"
n_ok=$(printf '%s\n' "$out" | grep -c 'config check OK: ')
[ $rc -eq 0 ] || die "shipped telegraf configs are rejected by telegraf $VERSION (see above)"
[ "$n_ok" -eq ${#confs[@]} ] || die "config check confirmed ${n_ok} of ${#confs[@]} configs"
echo "telegraf-config-guard: OK -- ${n_ok}/${#confs[@]} shipped configs load in telegraf $VERSION"
