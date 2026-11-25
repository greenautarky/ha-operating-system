#!/bin/sh
# baked_boot_device - F1/F5: a FRESH device starts from what the image baked, without
# the internet (Odoo #2065 updater.json seed, #2067 unpacked snapshots) - the DEVICE side.
#
# The build side is judged on the artefact before it ever ships: VER-13 (the baked images
# are unpacked in data.ext4, scripts/check-baked-snapshots.sh) and VER-14 (the built
# updater.json carries version.json, scripts/check-baked-updater.sh) in run_build_tests.sh.
# They prove the IMAGE. They cannot prove that a device booting it did not go to the
# registry anyway - that is what this suite looks at, on the running system:
#
#   BKD-01  /mnt/data/supervisor/updater.json is a JSON object with a channel and
#           auto_update exactly false (Odoo #1615: else the device follows the channel)
#   BKD-02  it carries version AND a ghcr.io/greenautarky image for each of cli dns audio
#           multicast observer and the Supervisor (+ Core when a homeassistant container
#           exists). VER-14 pins the artefact against version.json; here the expectation is
#           the pinned registry prefix, so an upstream image name (which sends a fresh device
#           to the internet) is red whatever version.json said.
#   BKD-03  each plugin container that runs is on the version updater.json names (two
#           sources compared; >= 3 containers must be inspected, never zero)
#   BKD-04  the Supervisor log has no "Downloading docker image" line. On a FRESH boot
#           (GA_TEST_FRESH_BOOT=1, set by the fresh-flash gate for a first boot after
#           flashing) any such line is a FAIL: the baked images were not used. On a
#           device that has been up and updated, a download can be legitimate: the count
#           is reported and the verdict is SKIP, never PASS-by-silence and never a
#           false red.
# Both boards: DSGW-210 and iHost bake the five plugins (a board may skip Core/Supervisor
# images, not the plugins).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/test_helpers.sh"

suite_start "Baked images on a fresh device: updater.json + no registry download (Odoo #2065, #2067)"

UPD="${GA_BKD_UPDATER:-/mnt/data/supervisor/updater.json}"
PLUGINS="cli dns audio multicast observer"
SUPLOG_CMD="${GA_BKD_SUPLOG_CMD:-docker logs hassio_supervisor}"

if jq -e 'type == "object" and ((.channel // "") != "") and .auto_update == false' "$UPD" >/dev/null 2>&1; then _rc=0; else _rc=1; fi
show_verdict "BKD-01" "updater.json is a JSON object with a channel and auto_update false" "$_rc" "$UPD channel='$(jq -r '.channel // empty' "$UPD" 2>/dev/null)' auto_update='$(jq -c '.auto_update' "$UPD" 2>/dev/null)'"

# Required: the five plugins and the Supervisor (this runs ON a running Supervisor), plus Core when
# a homeassistant container exists (a board may skip Core). The image must be the GA registry's: an
# upstream name (homeassistant/{arch}-hassio-cli) is what sends a fresh device to the internet.
REQ="$PLUGINS supervisor"
docker inspect homeassistant >/dev/null 2>&1 && REQ="$REQ homeassistant"
MISSING=""; N=0
for p in $REQ; do
  N=$((N + 1))
  v=$(jq -r --arg p "$p" '.[$p] // empty' "$UPD" 2>/dev/null)
  i=$(jq -r --arg p "$p" '.image[$p] // empty' "$UPD" 2>/dev/null)
  case "$i" in ghcr.io/greenautarky/*) _gi=ok ;; *) _gi=bad ;; esac
  if [ -z "$v" ] || [ "$_gi" != ok ]; then MISSING="$MISSING $p(${v:-no version}, ${i:-no image})"; fi
done
if [ -z "$MISSING" ] && [ "$N" -ge 6 ]; then _rc=0; else _rc=1; fi
show_verdict "BKD-02" "updater.json: version + ghcr.io/greenautarky image for cli dns audio multicast observer supervisor (+ Core when present): $N inspected" "$_rc" "${MISSING:+not baked-clean:$MISSING}"

# BKD-03: container tag == updater.json version (the Supervisor names plugin images image:version)
SEEN=0; DIFF=""
for p in $PLUGINS; do
  img=$(docker inspect -f '{{.Config.Image}}' "hassio_$p" 2>/dev/null) || continue
  [ -n "$img" ] || continue
  SEEN=$((SEEN + 1))
  want=$(jq -r --arg p "$p" '.[$p] // empty' "$UPD" 2>/dev/null)
  [ "${img##*:}" = "$want" ] || DIFF="$DIFF $p(running ${img##*:}, updater.json ${want:-none})"
done
if [ "$SEEN" -ge 3 ] && [ -z "$DIFF" ]; then _rc=0; else _rc=1; fi
show_verdict "BKD-03" "running plugin containers are on the version updater.json names ($SEEN inspected, >= 3 required)" "$_rc" "${DIFF:+differ:$DIFF}"

# BKD-04
LOG=$($SUPLOG_CMD 2>&1); LRC=$?
if [ "$LRC" -ne 0 ] || [ -z "$LOG" ]; then
  show_verdict "BKD-04" "no 'Downloading docker image' in the Supervisor log" 1 "could not read the Supervisor log (rc=$LRC) - nothing inspected"
else
  DL=$(printf '%s\n' "$LOG" | grep -c 'Downloading docker image')
  LINES=$(printf '%s\n' "$LOG" | wc -l)
  FIRST=$(printf '%s\n' "$LOG" | grep 'Downloading docker image' | head -3 | cut -c1-160 | tr '\n' '|')
  if [ "$DL" = 0 ]; then
    show_verdict "BKD-04" "no 'Downloading docker image' in the Supervisor log ($LINES log lines inspected)" 0 "0 downloads"
  elif [ "${GA_TEST_FRESH_BOOT:-0}" = 1 ]; then
    show_verdict "BKD-04" "no 'Downloading docker image' in the Supervisor log (FRESH boot)" 1 "$DL download line(s): $FIRST"
  else
    skip_test "BKD-04" "no 'Downloading docker image' in the Supervisor log" "$DL download line(s), but this is not declared a fresh boot (GA_TEST_FRESH_BOOT=1): $FIRST"
  fi
fi

suite_end
