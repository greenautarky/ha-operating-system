#!/bin/sh
# OS Integrity — does the FLASHED system match what the repo DECLARES?
#
# WHY THIS SUITE EXISTS
# =====================
# 2026-08-20: the rc3 image shipped OpenSSL 3.4.4 while master declared 3.5.7
# (#369 was merged a day earlier). The bake had moved the buildroot submodule
# pointer without updating the submodule — and the only detector was a human
# typing `openssl version` on the freshly flashed device. The same day four
# add-on pipelines were found building from bases their build.yaml did not
# declare. One class: declaration and artefact, compared by nobody.
#
# This suite is that comparison, run ON the device. The expectations come from
# expected.env, generated repo-side by gen_expected.sh out of the PINNED
# declarations (version.yaml, defconfig, buildroot submodule pointer,
# addon-images.json) — never from the device itself (N2). A missing
# expected.env is a hard FAIL, not a skip: "could not check" must never read
# as green.
#
# Run after every fresh flash and after every OTA. Works on an UNPROVISIONED
# device on purpose — everything here is baked state, not converge state
# (that is the addons_running suite).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "OS Integrity (declared vs flashed)"

EXP="$SCRIPT_DIR/expected.env"
if [ ! -s "$EXP" ]; then
  run_test "OSI-00" "expected.env present (generated repo-side)" "false"
  suite_end; exit 1
fi
. "$EXP"
# Print what we are comparing AGAINST. A device flashed from an older
# commit than the checkout that generated expected.env will fail the
# image rows — correctly, but the reason is invisible without this line.
# (Cost me a confused minute on 2026-08-24: master had moved mosquitto
# 7.2.2 -> 7.2.3 hours after the device was flashed.)
grep -m1 "^# source commit:" "$EXP" | sed "s/^# /  expectations from /"
run_test "OSI-00" "expected.env carries all seven expectation groups" \
  '[ -n "$EXPECTED_GA_RELEASE" ] && [ -n "$EXPECTED_KERNEL" ] && [ -n "$EXPECTED_OPENSSL" ] && [ -n "$EXPECTED_CORE" ] && [ -n "$EXPECTED_ADDON_IMAGES" ] && [ -n "$EXPECTED_PLUGINS" ] && [ -n "$EXPECTED_CHANNEL" ]'

# --- the OS layer ----------------------------------------------------------
run_test_show "OSI-01" "/etc/ga-release == declared ${EXPECTED_GA_RELEASE}" \
  '[ "$(cat /etc/ga-release 2>/dev/null)" = "$EXPECTED_GA_RELEASE" ]'

run_test_show "OSI-02" "kernel == declared ${EXPECTED_KERNEL}-haos" \
  '[ "$(uname -r)" = "${EXPECTED_KERNEL}-haos" ]'

# The one that was red on the day this suite was written: rc3 shipped 3.4.4
# against a declared 3.5.7, because the bake built a stale buildroot.
run_test_show "OSI-03" "openssl == declared ${EXPECTED_OPENSSL} (the rc3 lesson)" \
  '[ "$(openssl version 2>/dev/null | awk "{print \$2}")" = "$EXPECTED_OPENSSL" ]'

# --- HA Core ---------------------------------------------------------------
# Core is installed by the Supervisor on first boot — minutes on a fresh flash.
# Bounded wait, then assert: a Core that never appears still fails (OSI-04 was
# briefly red on the rc5 flash for exactly this timing, green once up).
run_test_ready "OSI-04" "HA Core container runs the pinned ${EXPECTED_CORE}" \
  'docker ps --format "{{.Names}}" | grep -q "^homeassistant$"' 600 \
  'docker inspect homeassistant --format "{{.Config.Image}}" 2>/dev/null | grep -q ":${EXPECTED_CORE}$"'

# --- the baked add-on set --------------------------------------------------
# Every image addon-images.json pins must be PRESENT at exactly that tag.
# Presence is what the bake promises; running is the addons_running suite.
_i=10
for pair in $EXPECTED_ADDON_IMAGES; do
  _slug="${pair%%=*}"; _ref="${pair#*=}"
  run_test "OSI-$_i" "baked image present: ${_slug} (${_ref##*:})" \
    "docker image inspect '$_ref' >/dev/null 2>&1"
  _i=$((_i+1))
done

# --- the Supervisor's own plane: plugins -----------------------------------
# The five plugins are NOT pinned in this repo; the Supervisor resolves them
# from the channel JSON (ADR-0018 §2). Two of them are GA-built since
# 2026-08-24 — an unbuilt plane is an unwatched plane, and upstream has already
# stopped shipping armv7 for them. Compare the DECLARED image:tag against what
# the Supervisor actually runs.
run_test_show "OSI-19" "supervisor channel == declared ${EXPECTED_CHANNEL}" \
  '[ "$(ha supervisor info --raw-json 2>/dev/null | sed -n "s/.*\"channel\":\"\([a-z]*\)\".*/\\1/p")" = "$EXPECTED_CHANNEL" ]'

_i=20
for pair in $EXPECTED_PLUGINS; do
  _slug="${pair%%=*}"; _ref="${pair#*=}"
  run_test_show "OSI-$_i" "plugin ${_slug} runs the declared ${_ref##*/}" \
    "[ \"\$(docker inspect hassio_${_slug} --format '{{.Config.Image}}' 2>/dev/null)\" = '$_ref' ]"
  _i=$((_i+1))
done

run_test "OSI-98" "coverage: all five plugins were checked" \
  '[ "$(echo "$EXPECTED_PLUGINS" | wc -w)" -eq 5 ]'

# Coverage: a loop over zero addons is a broken generator, not a clean device.
run_test "OSI-99" "coverage: at least 6 addon images were checked" \
  '[ "$(echo "$EXPECTED_ADDON_IMAGES" | wc -w)" -ge 6 ]'

suite_end
