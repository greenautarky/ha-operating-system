#!/usr/bin/env bash
# run_host_suites.sh — run the host-lane test suites inside a container.
#
# These suites exercise DEVICE scripts on a workstation. That is only safe if the
# workstation cannot be acted upon: on 2026-08-28 the ga-rauc-install fixtures
# rebooted a developer's laptop twice, because the script detaches its reboot
# timer and the fixture's PATH stubs were gone by the time it fired.
#
# So they run in a container with no systemd. Not "should not reboot" — cannot.
#
#   tests/run_host_suites.sh                 # every host suite
#   tests/run_host_suites.sh ota_resolve_pin # one suite
#   HOST_LANE_LOCAL=1 tests/run_host_suites.sh   # ESCAPE HATCH, see below
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ga-host-lane:local"

SUITES=("$@")
if [ ${#SUITES[@]} -eq 0 ]; then
  # The set lint.yml's host-suites job runs. Keep the two in step: a suite that
  # runs here and not in CI is a suite nobody re-checks.
  SUITES=(share_publish rauc_slots stage_components apparmor_profile
          publish_services ota_resolve_pin)
fi

if [ "${HOST_LANE_LOCAL:-}" = "1" ]; then
  # Deliberate, explicit, and loud. There is one legitimate reason to take this
  # path — debugging the container itself — and it is not "docker is slow".
  echo "!! HOST_LANE_LOCAL=1 — running DEVICE scripts directly on this machine."
  echo "!! The isolation that exists because these suites once rebooted a laptop"
  echo "!! is OFF. Ctrl-C now unless you meant it."
  for s in "${SUITES[@]}"; do sh "$REPO/tests/ga_tests/$s/test.sh"; done
  exit $?
fi

if ! command -v docker >/dev/null 2>&1; then
  # Fail closed. Silently falling back to the host is exactly how the isolation
  # would rot away, and the failure it prevents is not one you notice in a diff.
  echo "::error::docker not found. These suites run DEVICE scripts and are only" >&2
  echo "::error::safe in a container. Install docker, or set HOST_LANE_LOCAL=1 if" >&2
  echo "::error::you have read tests/host-lane/Dockerfile and accept the risk." >&2
  exit 2
fi

docker build -q -t "$IMAGE" "$REPO/tests/host-lane" >/dev/null

fail=0
for s in "${SUITES[@]}"; do
  # Read-only repo, tmpfs for the suites' scratch space, no network, everything
  # dropped. A suite that needs more than this should have to say why.
  docker run --rm \
    --network none \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,exec,size=64m \
    -v "$REPO:/repo:ro" \
    -e TMPDIR=/tmp \
    "$IMAGE" sh "/repo/tests/ga_tests/$s/test.sh" || fail=$((fail + 1))
done

echo
if [ "$fail" -ne 0 ]; then
  echo "::error::$fail host suite(s) failed"
  exit 1
fi
echo "all host suites passed (in the container — no systemd, nothing to reboot)"
