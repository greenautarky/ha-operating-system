#!/bin/sh
# haos-apparmor regression suite.
#
# Since Odoo #1281 (AA1 + AA2, patch 0132) the Supervisor profile is the copy
# baked into the read-only rootfs (/usr/share/ga-apparmor/hassio-supervisor,
# sha256-pinned at build time) and haos-apparmor loads THAT file on every boot.
# Nothing is downloaded. The copy in the data directory is kept equal to the
# baked one, but it is never the copy loaded for hassio-supervisor.
#
# Still guarded from the pre-2026-08-26 failures ("a fallback must be loud"):
# a missing or unloadable Supervisor profile exits non-zero instead of letting
# the Supervisor start unconfined, and a failed copy never leaves a partial
# profile at the final path.
#
# Pure host-side. curl / systemctl / apparmor_parser are the ENVIRONMENT and are
# stubbed (curl only to prove it is never called); the subject under test — the
# script's decision logic, what it loads and what lands on disk — is never
# stubbed.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "haos-apparmor (loads the baked, pinned Supervisor profile)"

# HAOS 18.x: haos-apparmor with GA patch 0132.
# In the repo: exported from haos/ as the build sees it (scripts/apply-haos-patches.sh).
AA="${GA_HAOS_APPARMOR_BIN:-/usr/libexec/haos-apparmor}"
if [ ! -x "$AA" ]; then
  _AA_EXP="$(mktemp -d 2>/dev/null || echo /tmp/aap_exp_$$)"
  "$SCRIPT_DIR/../../../scripts/apply-haos-patches.sh" --export "$_AA_EXP" \
    buildroot-external/rootfs-overlay/usr/libexec/haos-apparmor >/dev/null 2>&1
  AA="$_AA_EXP/buildroot-external/rootfs-overlay/usr/libexec/haos-apparmor"
fi

run_test "AAP-01" "script present + executable" "test -x '$AA'"

WORK="$(mktemp -d 2>/dev/null || echo /tmp/aap_$$)"
BIN="$WORK/bin"; mkdir -p "$BIN"

printf '#!/bin/sh\nexit 0\n' > "$BIN/systemctl"
# apparmor_parser: records the profile file it was asked to load (last arg);
# fails for a file whose first line is PARSE-ERROR.
cat > "$BIN/apparmor_parser" <<STUB
#!/bin/sh
for a in "\$@"; do f="\$a"; done
echo "\$f" >> "$WORK/parser.log"
[ "\$(head -n1 "\$f" 2>/dev/null)" = PARSE-ERROR ] && exit 1
exit 0
STUB
# curl: must never run. Records the call and "downloads" a different profile.
cat > "$BIN/curl" <<STUB
#!/bin/sh
echo "curl \$*" >> "$WORK/curl.log"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
[ -n "\$out" ] && printf 'DOWNLOADED\n' > "\$out"
exit 0
STUB
chmod +x "$BIN"/systemctl "$BIN"/apparmor_parser "$BIN"/curl

# Run the real script against a sandboxed baked profile + PROFILES_DIR.
# $1 = data copy state (missing|dir-only|same|differs), $2 = baked (ok|missing|bad)
# Sets RC, GOT (first line of the data copy or ABSENT), LOADED (parser args,
# one per line), CURLS (number of curl calls), OUT.
aa_run() {
  _d="$WORK/run_$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ' || echo $$)"
  rm -rf "$_d"; mkdir -p "$_d/rootfs"; _prof="$_d/profiles"; _baked="$_d/rootfs/hassio-supervisor"
  case "$2" in
    ok)  printf 'BAKED\nprofile hassio-supervisor {}\n' > "$_baked" ;;
    bad) printf 'PARSE-ERROR\n' > "$_baked" ;;
  esac
  case "$1" in
    dir-only) mkdir -p "$_prof" ;;
    same)     mkdir -p "$_prof"; cp "$_baked" "$_prof/hassio-supervisor" ;;
    differs)  mkdir -p "$_prof"; printf 'DOWNLOADED\nprofile hassio-supervisor {}\n' > "$_prof/hassio-supervisor" ;;
  esac
  if [ -n "${3:-}" ]; then mkdir -p "$_prof"; printf 'profile addon_x {}\n' > "$_prof/addon_x"; printf 'tmp\n' > "$_prof/.hassio-supervisor.tmp"; fi
  _s="$_d/script"; cp "$AA" "$_s"
  sed -i -e "s|^PROFILES_DIR=.*|PROFILES_DIR=\"$_prof\"|" -e "s|^BAKED_PROFILE=.*|BAKED_PROFILE=\"$_baked\"|" "$_s"; chmod +x "$_s"
  rm -f "$WORK/parser.log" "$WORK/curl.log"
  OUT="$(PATH="$BIN:$PATH" "$_s" 2>&1)"; RC=$?
  GOT="ABSENT"; [ -f "$_prof/hassio-supervisor" ] && GOT=$(head -n1 "$_prof/hassio-supervisor")
  LOADED="$(cat "$WORK/parser.log" 2>/dev/null)"
  CURLS=0; [ -f "$WORK/curl.log" ] && CURLS=$(wc -l < "$WORK/curl.log" | tr -d ' ')
  AA_BAKED="$_baked"; AA_PROF="$_prof"
}

# --- the load path reads the baked copy --------------------------------------
aa_run differs ok
run_test "AAP-02" "a data copy that differs is NOT loaded; the baked copy is" \
  "printf '%s\n' '$LOADED' | grep -qxF '$AA_BAKED' && ! printf '%s\n' '$LOADED' | grep -qxF '$AA_PROF/hassio-supervisor'"
run_test "AAP-03" "a data copy that differs is replaced by the baked one (with a warning)" \
  "[ '$GOT' = BAKED ] && printf '%s' '$OUT' | grep -q WARNING"
run_test "AAP-04" "exits 0 when the baked profile loads" "[ '$RC' = 0 ]"

aa_run missing ok
run_test "AAP-05" "fresh device (no data copy): nothing downloaded, data copy = baked, baked loaded" \
  "[ '$CURLS' = 0 ] && [ '$GOT' = BAKED ] && [ '$RC' = 0 ] && printf '%s\n' '$LOADED' | grep -qxF '$AA_BAKED'"

aa_run dir-only ok
run_test "AAP-06" "directory without profile: nothing downloaded, data copy = baked" \
  "[ '$CURLS' = 0 ] && [ '$GOT' = BAKED ]"

aa_run same ok
run_test "AAP-07" "an equal data copy is left alone (no warning), baked copy loaded" \
  "[ '$RC' = 0 ] && ! printf '%s' '$OUT' | grep -q WARNING && printf '%s\n' '$LOADED' | grep -qxF '$AA_BAKED'"

# --- loud failures -----------------------------------------------------------
aa_run differs missing
run_test "AAP-08" "baked profile missing: exits NON-ZERO, loads nothing, downloads nothing" \
  "[ '$RC' != 0 ] && [ -z '$LOADED' ] && [ '$CURLS' = 0 ]"

aa_run missing bad
run_test "AAP-09" "baked profile does not load: exits NON-ZERO" "[ '$RC' != 0 ]"

# --- add-on profiles keep loading --------------------------------------------
aa_run same ok addons
run_test "AAP-10" "other profiles in the data directory still load; dot files do not" \
  "printf '%s\n' '$LOADED' | grep -qxF '$AA_PROF/addon_x' && ! printf '%s\n' '$LOADED' | grep -qF '.hassio-supervisor.tmp'"
run_test "AAP-11" "the Supervisor profile is loaded exactly once (from the baked copy)" \
  "[ \"\$(printf '%s\n' '$LOADED' | grep -c 'hassio-supervisor\$')\" = 1 ]"

# --- a data copy that cannot be updated does not stop the load ---------------
if [ "$(id -u)" != 0 ]; then
  aa_run differs ok
  # same sandbox, a differing data copy again, directory read-only, run again
  printf 'DOWNLOADED\nprofile hassio-supervisor {}\n' > "$AA_PROF/hassio-supervisor"; chmod 555 "$AA_PROF"
  rm -f "$WORK/parser.log"
  OUT="$(PATH="$BIN:$PATH" "$(dirname "$AA_PROF")/script" 2>&1)"; RC=$?
  chmod 755 "$AA_PROF"
  W13=""; printf '%s\n' "$OUT" | grep -q "Can't update" && W13=y
  L13=""; grep -qxF "$AA_BAKED" "$WORK/parser.log" 2>/dev/null && L13=y
  run_test "AAP-13" "read-only data directory: warning, baked profile still loaded, exit 0" \
    "[ '$RC' = 0 ] && [ '$W13' = y ] && [ '$L13' = y ]"
else
  skip_test "AAP-13" "read-only data directory" "root ignores directory permissions"
fi

# --- static: the script as the build ships it --------------------------------
run_test "AAP-12" "the shipped script names /usr/share/ga-apparmor/hassio-supervisor and has no URL" \
  "grep -qx 'BAKED_PROFILE=\"/usr/share/ga-apparmor/hassio-supervisor\"' '$AA' && ! grep -qE 'curl|https?://' '$AA'"

rm -rf "$WORK" 2>/dev/null

suite_end
