#!/bin/sh
# hassos-apparmor regression suite.
#
# Guards two failures the pre-2026-08-26 version had, both SILENT:
#
#  1. It gated the download on the DIRECTORY existing, not on the profile file.
#     A download that failed once left the directory behind, so every later boot
#     skipped the download entirely and the Supervisor ran unconfined forever.
#  2. curl ran without -f, so an HTTP error body (a 404 page) was written
#     straight to the final profile path and the script exited 0. apparmor_parser
#     then failed to load it, printed one line, and the script continued.
#
# Both are "a fallback must be loud" failures: the system kept running with no
# AppArmor confinement and nothing went red. Ported from upstream HAOS
# (hassos-* -> haos-* rename not followed; see KB #222).
#
# Pure host-side. curl / systemctl / apparmor_parser are the ENVIRONMENT and are
# stubbed; the subject under test — the script's decision logic and what lands
# on disk — is never stubbed.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "hassos-apparmor (profile presence + atomic download)"

AA="/usr/libexec/hassos-apparmor"
[ -x "$AA" ] || AA="$SCRIPT_DIR/../../../buildroot-external/rootfs-overlay/usr/libexec/hassos-apparmor"

run_test "AAP-01" "script present + executable" "test -x '$AA'"

WORK="$(mktemp -d 2>/dev/null || echo /tmp/aap_$$)"
BIN="$WORK/bin"; mkdir -p "$BIN"

printf '#!/bin/sh\nexit 0\n' > "$BIN/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$BIN/apparmor_parser"
# Mirrors real curl: without -f it writes the error body and still exits 0;
# with -f it deletes the partial output and exits 22.
cat > "$BIN/curl" <<'STUB'
#!/bin/sh
out=""; fflag=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -f*|--fail*) fflag=1; shift ;;
    *) shift ;;
  esac
done
if [ "${CURL_MODE}" = "ok" ]; then printf 'profile hassio-supervisor {}\n' > "$out"; exit 0; fi
printf '<html>404 Not Found</html>\n' > "$out"
[ "$fflag" = "1" ] && { rm -f "$out"; exit 22; }
exit 0
STUB
chmod +x "$BIN"/systemctl "$BIN"/apparmor_parser "$BIN"/curl

# Run the real script against a sandboxed PROFILES_DIR.
# $1 = state (missing|dir-only|present), $2 = curl mode. Echoes "<rc>|<first line>".
aa_run() {
  _d="$WORK/run$$_$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ' || echo $$)"
  mkdir -p "$_d"; _prof="$_d/profiles"
  case "$1" in
    dir-only) mkdir -p "$_prof" ;;
    present)  mkdir -p "$_prof"; printf 'ORIGINAL\n' > "$_prof/hassio-supervisor" ;;
  esac
  _s="$_d/script"; cp "$AA" "$_s"
  sed -i "s|^PROFILES_DIR=.*|PROFILES_DIR=\"$_prof\"|" "$_s"; chmod +x "$_s"
  CURL_MODE="$2" PATH="$BIN:$PATH" "$_s" >/dev/null 2>&1; _rc=$?
  _got="ABSENT"; [ -f "$_prof/hassio-supervisor" ] && _got=$(head -n1 "$_prof/hassio-supervisor")
  echo "${_rc}|${_got}"
  AA_LAST_DIR="$_prof"
}

# --- the bug: directory present, profile missing -----------------------------
R=$(aa_run dir-only ok)
run_test "AAP-02" "re-downloads when the directory exists but the profile does not" \
  "[ \"\${R#*|}\" = 'profile hassio-supervisor {}' ]"

# --- green proof: an existing profile is left alone --------------------------
R=$(aa_run present ok)
run_test "AAP-03" "existing profile is not re-downloaded or overwritten" \
  "[ \"\${R#*|}\" = ORIGINAL ]"
run_test "AAP-04" "exits 0 when the profile is already in place" \
  "[ \"\${R%%|*}\" = 0 ]"

# --- atomic download: a failed fetch must not install an error page ----------
R=$(aa_run missing fail)
run_test "AAP-05" "a failed download installs NOTHING at the profile path" \
  "[ \"\${R#*|}\" = ABSENT ]"
run_test "AAP-06" "a failed download exits NON-ZERO (loud, not silent)" \
  "[ \"\${R%%|*}\" != 0 ]"

# --- happy path still works --------------------------------------------------
R=$(aa_run missing ok)
run_test "AAP-07" "fresh device downloads the profile and exits 0" \
  "[ \"\${R#*|}\" = 'profile hassio-supervisor {}' ] && [ \"\${R%%|*}\" = 0 ]"

rm -rf "$WORK" 2>/dev/null

suite_end
