#!/bin/sh
# rc19 device synthetic checks — runs ON a booted GA OS device (BOSv1.2.21-rc*).
# Verifies the rc19 OS features are actually live on the device, complementing
# the host-side static build asserts in run_build_tests.sh (RAUC-*, STAGE-*, …):
#   - /etc/ga-release is a BOSv1.2.21-rc* marker
#   - the every-boot stager populated /share/ga-custom-components
#   - staged component versions match what got PLACED under /config
#   - the ga-rauc-install.path host-install bridge is active
#   - per-device cred files are either absent (pre-activation) OR mode 0600
#
# Every check gates on the relevant device path/tool, so a host/laptop run
# degrades to SKIP rather than FAIL.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "rc19 device features"

# Resolve the host views of the addon /share bridge and the HA config tree.
SHARE="/mnt/data/supervisor/share"; [ -d "$SHARE" ] || SHARE="/share"
CFG="/mnt/data/supervisor/homeassistant"
[ -d "$CFG" ] || CFG="/homeassistant"
[ -d "$CFG" ] || CFG="/config"
STAGED="$SHARE/ga-custom-components"
PLACED="$CFG/custom_components"
INFLUX_CRED="$SHARE/ga-fleet-influx.yaml"

# ----- /etc/ga-release marker -----
if [ -f /etc/ga-release ]; then
  run_test "RC19-01" "/etc/ga-release is a BOSv1.2.21-rc* marker" \
    "grep -qE 'BOSv1[.]2[.]21-rc[0-9]+' /etc/ga-release"
else
  skip_test "RC19-01" "/etc/ga-release marker" "no /etc/ga-release (host run)"
fi

# ----- every-boot vendored stager populated /share -----
if [ -d "$STAGED" ]; then
  run_test "RC19-02" "/share/ga-custom-components populated (>=1 component manifest)" \
    "[ \"\$(find '$STAGED' -maxdepth 2 -name manifest.json 2>/dev/null | head -1)\" != '' ]"
else
  skip_test "RC19-02" "/share/ga-custom-components populated" "staging dir absent (stager not run / pre-activation)"
fi

# ----- staged component versions match the placed /config copies -----
# Passes when every staged component that is ALSO placed has a matching version.
# (A staged-but-not-yet-placed component is fine — that's converge's job.)
_rc19_versions_match() {
  _sd="$1"; _pd="$2"
  [ -d "$_sd" ] || return 1
  _ok=1
  for _m in "$_sd"/*/manifest.json; do
    [ -f "$_m" ] || continue
    _comp=$(basename "$(dirname "$_m")")
    _pm="$_pd/$_comp/manifest.json"
    [ -f "$_pm" ] || continue   # not placed yet — skip, not a mismatch
    _sv=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_m" | head -1)
    _pv=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_pm" | head -1)
    [ "$_sv" = "$_pv" ] || { echo "mismatch $_comp: staged=$_sv placed=$_pv"; _ok=0; }
  done
  [ "$_ok" = 1 ]
}
if [ -d "$STAGED" ] && [ -d "$PLACED" ]; then
  run_test_show "RC19-03" "staged component versions == placed /config versions" \
    "_rc19_versions_match '$STAGED' '$PLACED'"
else
  skip_test "RC19-03" "staged==placed versions" "staged or placed tree absent"
fi

# ----- ga-rauc-install.path host-install bridge active -----
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^ga-rauc-install.path'; then
  run_test "RC19-04" "ga-rauc-install.path watcher is active" \
    "systemctl is-active ga-rauc-install.path"
else
  skip_test "RC19-04" "ga-rauc-install.path active" "no systemctl / unit not installed (host run)"
fi

# ----- per-device cred files: absent OR mode 0600 (never wrong-mode) -----
# The unified per-device InfluxDB cred may legitimately be absent before the
# fleet-manager delivers it; if present it MUST be 0600 (single-writer secret).
_rc19_cred_mode_ok() {
  _f="$1"
  [ -f "$_f" ] || return 0            # absent = acceptable pre-activation
  _m=$(stat -c '%a' "$_f" 2>/dev/null)
  [ "$_m" = 600 ]
}
run_test_show "RC19-05" "per-device influx cred absent or 0600 (never wrong-mode)" \
  "_rc19_cred_mode_ok '$INFLUX_CRED'"

# ----- secret /share cred files should not be group/other-readable (informational) -----
# Scoped to genuine per-device SECRET files (influx/mqtt cred, *.token) — NOT the
# non-secret bundle-expectation metadata (ga-fleet-bundle.yaml) or its .bak copies.
# Kept informational (warn, not fail): there is no ratified 0600 contract for every
# cred yet (ADR-0003 unification is in flight), so a loose file is a hygiene flag,
# not a build breakage.
_rc19_list_loose_creds() {
  _dir="$1"
  [ -d "$_dir" ] || return 0
  find "$_dir" -maxdepth 1 -type f \
    \( -name 'ga-fleet-influx.yaml' -o -name 'ga-fleet-mqtt.yaml' -o -name 'ga-*cred*' -o -name '*.token' \) \
    -perm /077 2>/dev/null
}
if [ -d "$SHARE" ]; then
  _loose=$(_rc19_list_loose_creds "$SHARE")
  [ -n "$_loose" ] && echo "        note: group/other-readable secret cred file(s): $_loose"
  warn_test "RC19-06" "secret /share cred files are not group/other-readable (informational)" \
    "[ -z \"\$(_rc19_list_loose_creds '$SHARE')\" ]"
else
  skip_test "RC19-06" "secret /share cred file modes" "no /share dir (host run)"
fi

suite_end
