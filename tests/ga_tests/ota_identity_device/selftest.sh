#!/bin/sh
# Host-side selftest of ota_identity_device/test.sh: the LIVE suite driving the LIVE
# ga-rauc-install (tree copy) with a stub for the NETWORK only (the "real" curl). Known-good
# must PASS every check; four mutants of the installer - token on the command line, a 0644
# identity file, the file left behind, an anonymous device that cannot download - must each be
# red on the check that guards it; a store that denies must not turn client-side checks red.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/devsuite_selftest.sh"
ds_init
REAL="$DS_ROOT/../buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install"
[ -s "$REAL" ] || { echo "FATAL: installer missing: $REAL"; exit 2; }
mkdir -p "$W/run"
printf '100.%d.0.21\n' 100 > "$W/pin"        # a mesh address (CGNAT range), as the resolver writes it

# the network: a curl that answers the store's probe object, slowly enough for the /proc scan
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output" ] && out="$a"; prev="$a"; done
/bin/sleep 0.4
[ "${FAKE_CURL:-ok}" = deny ] && { echo "curl: (22) The requested URL returned error: 403" >&2; exit 22; }
[ -n "$out" ] && printf 'OK\n' > "$out"
exit 0
STUB
cat > "$W/bin/resolver" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$W/bin/curl" "$W/bin/resolver"

mutant() {   # mutant <name> <python-replace-old> <python-replace-new>
  python3 - "$REAL" "$W/$1" "$2" "$3" <<'PYEOF'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
assert old in s, "mutation target not found: " + old
open(dst, "w").write(s.replace(old, new, 1))
PYEOF
  chmod +x "$W/$1"
}
run() { # run <installer> [VAR=val ...]
  _i="$1"; shift
  ds_run ota_identity_device GA_OTAID_INSTALLER="$_i" GA_OTA_ACTIVE_FILE="$W/pin" GA_RESOLVE_OTA_BIN="$W/bin/resolver" \
    GA_OTA_IDENT_DIR="$W/run" TMPDIR="$W" "$@"
}

echo "== known-good installer, open store"
run "$REAL"
for i in OTAID-00 OTAID-01 OTAID-01b OTAID-02 OTAID-03 OTAID-03c OTAID-04 OTAID-05 OTAID-06 OTAID-07; do ds_expect "$i" PASS "stage-1 identity as designed"; done

echo "== the store denies the synthetic identity (stage-2-like): client-side checks stay green"
run "$REAL" FAKE_CURL=deny
for i in OTAID-01 OTAID-02 OTAID-03 OTAID-05 OTAID-07; do ds_expect "$i" PASS "client side does not depend on the store's answer"; done
ds_expect OTAID-06 FAIL "anonymous download cannot complete against a denying store"

echo "== mutants of the installer"
mutant m-cmdline 'curl --config "$IDENT_CONF" "$@"' 'curl -H "Authorization: Bearer $_tok" "$@"'
run "$W/m-cmdline"
ds_expect OTAID-01 FAIL "token passed with -H, no --config"
ds_expect OTAID-01b FAIL "token among curl's arguments"
ds_expect OTAID-03 FAIL "token on the process command line while curl runs"
mutant m-mode '( umask 077' '( umask 022'
run "$W/m-mode"
ds_expect OTAID-02 FAIL "identity file world-readable"
mutant m-leftover 'cleanup_ident() { [ -z "$IDENT_CONF" ] || rm -f "$IDENT_CONF"; }' 'cleanup_ident() { :; }'
run "$W/m-leftover"
ds_expect OTAID-05 FAIL "identity file left in /run"
mutant m-noanon 'this device cannot download." >&2
        return 0' 'this device cannot download." >&2
        exit 3'
run "$W/m-noanon"
ds_expect OTAID-06 FAIL "an anonymous device that cannot download"
mutant m-install 'rm -f "$BUNDLE"
    exit 4' 'rauc install "$BUNDLE"; exit 4'
run "$W/m-install"
ds_expect OTAID-07 FAIL "an installer that reaches rauc install in the dry run"

ds_done
