#!/bin/sh
# Container-name gate. (1) scripts/check-container-names.sh is red on addon_-only
# spellings and green on app_-aware ones, and refuses to pass over nothing.
# (2) the live device-side tree is clean. (3) the resolver in
# tests/ga_tests/lib/test_helpers.sh is driven against a docker shim that knows
# ONLY app_* (BOSv1.6), only addon_* (BOSv1.5.x), both, and neither.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CHECK="$REPO/scripts/check-container-names.py"
HELP="$REPO/tests/ga_tests/lib/test_helpers.sh"
[ -f "$CHECK" ] && [ -f "$HELP" ] || { echo "FATAL: gate or helper missing"; exit 1; }
fails=0
ok()  { echo "  ok    $*"; }
bad() { echo "  FAIL  $*"; fails=$((fails + 1)); }
for f in "$HERE"/must-fail/*; do
  d="$(mktemp -d)"; cp "$f" "$d/"; out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?; rm -rf "$d"
  [ "$rc" -eq 1 ] && ok "must-fail $(basename "$f")" || bad "must-fail $(basename "$f") rc=$rc: $out"
done
for f in "$HERE"/must-pass/*; do
  d="$(mktemp -d)"; cp "$f" "$d/"; out="$(python3 "$CHECK" "$d" 2>&1)"; rc=$?; rm -rf "$d"
  [ "$rc" -eq 0 ] && ok "must-pass $(basename "$f")" || bad "must-pass $(basename "$f") rc=$rc: $out"
done
e="$(mktemp -d)"; python3 "$CHECK" "$e" >/dev/null 2>&1; rc=$?; rmdir "$e"
[ "$rc" -eq 2 ] && ok "empty root fails closed (rc 2)" || bad "empty root rc=$rc, want 2"
# live roots: device tests, the OS tree, scripts/ and .github/ (builder-side exceptions live in ALLOW in the gate, commented)
out="$(python3 "$CHECK" "$REPO/tests" "$REPO/buildroot-external" "$REPO/scripts" "$REPO/.github" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "live device-side tree: $out" || bad "live tree rc=$rc: $out"

# --- resolver against a docker shim
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cat > "$W/docker" <<'SH'
#!/bin/sh
# knows exactly the containers listed in $GA_SHIM_CTRS (space separated)
case "$1" in
  ps) for c in $GA_SHIM_CTRS; do echo "$c"; done ;;
  inspect) shift; while [ $# -gt 0 ]; do case "$1" in -f) shift ;; *) n="$1" ;; esac; shift; done
           for c in $GA_SHIM_CTRS; do [ "$c" = "$n" ] && { echo true; exit 0; }; done; exit 1 ;;
esac
SH
chmod +x "$W/docker"
t() {  # t <label> <"ctrs"> <fn> <arg> <want-stdout> <want-rc> <want-stderr-substr|"">
  out="$(PATH="$W:$PATH" GA_SHIM_CTRS="$2" sh -c ". '$HELP'; $3 $4" 2>"$W/err")"; rc=$?
  err="$(cat "$W/err")"
  if [ "$out" = "$5" ] && [ "$rc" -eq "$6" ] && { [ -z "$7" ] && [ -z "$err" ] || { [ -n "$7" ] && printf '%s' "$err" | grep -q "$7"; }; }; then ok "$1"
  else bad "$1: out='$out' rc=$rc err='$err' (want '$5' rc=$6 err~'$7')"; fi
}
t "BOSv1.6: app_ only -> ga_ctr_of"       "app_99f1cad4_ga_manager app_99f1cad4_ga_mosquitto" ga_ctr_of ga_manager app_99f1cad4_ga_manager 0 ""
t "BOSv1.6: app_ only -> ga_ctr_exact"    "app_99f1cad4_ga_manager" ga_ctr_exact 99f1cad4_ga_manager app_99f1cad4_ga_manager 0 ""
t "BOSv1.5.x: addon_ only -> ga_ctr_of"   "addon_99f1cad4_ga_manager" ga_ctr_of ga_manager addon_99f1cad4_ga_manager 0 "" # ga-ctr-ok
t "BOSv1.5.x: addon_ only -> ga_ctr_exact" "addon_99f1cad4_ga_manager" ga_ctr_exact 99f1cad4_ga_manager addon_99f1cad4_ga_manager 0 "" # ga-ctr-ok
t "both present: app_ wins"               "addon_99f1cad4_ga_manager app_99f1cad4_ga_manager" ga_ctr_of ga_manager app_99f1cad4_ga_manager 0 "" # ga-ctr-ok
t "slug absent under known scheme: silent" "app_99f1cad4_ga_manager" ga_ctr_of ga_zigbee2mqtt "" 1 ""
t "no add-on container at all: LOUD"      "hassio_supervisor homeassistant" ga_ctr_of ga_manager "" 1 "naming unresolved"
t "ga_ctr_exact neither: LOUD"            "homeassistant" ga_ctr_exact 99f1cad4_ga_manager "" 1 "neither app_"
[ "$fails" -eq 0 ] && echo "container_names selftest: all ok" || { echo "container_names selftest: $fails FAIL"; exit 1; }
