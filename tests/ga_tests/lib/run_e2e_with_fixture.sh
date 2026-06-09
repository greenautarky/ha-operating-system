#!/bin/sh
# tests/ga_tests/lib/run_e2e_with_fixture.sh
#
# One-shot wrapper that provisions a freshly-flashed device with the
# synthetic fixture and then runs the on-device E2E user-flow suite.
#
# This is the "after every build" test the user asked for: ONE command
# from the laptop, against a freshly flashed bench iHost, returns
# PASS/FAIL for the entire post-boot user-facing surface.
#
# Usage (from the laptop / CI runner):
#
#   GHCR_PAT=ghp_xxx \
#   DEVICE_IP=100.126.x.x \
#   tests/ga_tests/lib/run_e2e_with_fixture.sh
#
# Optional env:
#   SSH_PORT       (default 22222)
#   SSH_USER       (default root)
#   SSH_KEY        (default /home/user/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem)
#   DEVICE_ID      (default KIB-SON-TEST — passed through to fixture)
#   GHCR_USER      (default Thomastaube — passed through to fixture)
#   BUNDLE_VERSION (default v1.2 — passed through to fixture)
#   WAIT_FOR_HA    (default 180 — seconds to wait for HA Core to respond)
#
# Returns the exit code of the E2E suite (= 0 on PASS).

set -eu

DEVICE_IP="${DEVICE_IP:-}"
GHCR_PAT="${GHCR_PAT:-}"
SSH_PORT="${SSH_PORT:-22222}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-/home/user/Nextcloud2/GreenAutarky/security_store/HomeassistantGreen0.pem}"
DEVICE_ID="${DEVICE_ID:-KIB-SON-TEST}"
GHCR_USER="${GHCR_USER:-Thomastaube}"
BUNDLE_VERSION="${BUNDLE_VERSION:-v1.2}"
WAIT_FOR_HA="${WAIT_FOR_HA:-180}"

if [ -z "$DEVICE_IP" ]; then
  echo "ERROR: DEVICE_IP env var required (= NetBird / Tailscale / LAN IP of the bench iHost)" >&2
  exit 64
fi
if [ -z "$GHCR_PAT" ]; then
  echo "ERROR: GHCR_PAT env var required (= fleet-wide read:packages PAT)" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="${SCRIPT_DIR}/provision_test_fixture.sh"
E2E="${SCRIPT_DIR}/../e2e_user_flows/test.sh"

[ -f "$FIXTURE" ] || { echo "ERROR: fixture missing at $FIXTURE" >&2; exit 65; }
[ -f "$E2E" ]     || { echo "ERROR: e2e suite missing at $E2E" >&2; exit 65; }

# ssh wants -p, scp wants -P (case-sensitive port flag mismatch).
common_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
[ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ] && common_opts="$common_opts -i $SSH_KEY"
ssh_opts="$common_opts -p $SSH_PORT"
scp_opts="$common_opts -P $SSH_PORT"
target="$SSH_USER@$DEVICE_IP"

log() { printf '[run_e2e_with_fixture] %s\n' "$*"; }

# 1. SSH reachability
log "1/5  probing SSH on $target:$SSH_PORT ..."
# shellcheck disable=SC2086
ssh $ssh_opts "$target" 'echo SSH_OK' >/dev/null || {
  echo "ERROR: cannot SSH to $target — is the device flashed / on the network?" >&2
  exit 66
}

# 2. Wait for HA Core (= ga-bootstrap + converge may still be churning on a fresh flash).
# HA's `/api/` returns 401 to unauthenticated callers — that's "up + healthy",
# NOT a failure. Probe via `/manifest.json` (= public) and accept any 2xx/3xx.
# A 401 on `/api/` would also count; we use manifest.json because it doesn't
# pollute the auth-ban log with WARNING lines.
log "2/5  waiting up to ${WAIT_FOR_HA}s for HA Core to respond on :8123 ..."
deadline=$(( $(date +%s) + WAIT_FOR_HA ))
while :; do
  # shellcheck disable=SC2086
  code=$(ssh $ssh_opts "$target" "curl -s -o /dev/null -m 3 -w '%{http_code}' http://localhost:8123/manifest.json" 2>/dev/null || echo "000")
  case "$code" in
    2*|3*) log "      HA Core responded (HTTP $code)"; break;;
  esac
  [ "$(date +%s)" -ge "$deadline" ] && { echo "ERROR: HA Core never responded within ${WAIT_FOR_HA}s (last HTTP $code)" >&2; exit 67; }
  sleep 5
done

# 3. Push + run the fixture
log "3/5  uploading + running provision_test_fixture.sh ..."
# shellcheck disable=SC2086
scp $scp_opts "$FIXTURE" "$target:/tmp/provision_test_fixture.sh" >/dev/null
# shellcheck disable=SC2086
ssh $ssh_opts "$target" "
  chmod +x /tmp/provision_test_fixture.sh
  GHCR_PAT='$GHCR_PAT' GHCR_USER='$GHCR_USER' DEVICE_ID='$DEVICE_ID' BUNDLE_VERSION='$BUNDLE_VERSION' \
    /tmp/provision_test_fixture.sh
" || { echo "ERROR: fixture exited non-zero" >&2; exit 68; }

# 4. Push + run the E2E suite
log "4/5  uploading + running e2e_user_flows/test.sh ..."
# shellcheck disable=SC2086
scp $scp_opts "$E2E" "$target:/tmp/e2e_user_flows_test.sh" >/dev/null
# Helpers if the test sources them — fall through to in-script minimal helpers otherwise
HELPERS="${SCRIPT_DIR}/test_helpers.sh"
if [ -f "$HELPERS" ]; then
  # shellcheck disable=SC2086
  ssh $ssh_opts "$target" 'mkdir -p /tmp/ga_tests_lib' >/dev/null
  # shellcheck disable=SC2086
  scp $scp_opts "$HELPERS" "$target:/tmp/ga_tests_lib/test_helpers.sh" >/dev/null
fi
# Stage the test under /tmp/e2e_user_flows/ so its `../lib/test_helpers.sh` resolves
# shellcheck disable=SC2086
ssh $ssh_opts "$target" '
  mkdir -p /tmp/e2e_user_flows
  mv /tmp/e2e_user_flows_test.sh /tmp/e2e_user_flows/test.sh
  ln -sf /tmp/ga_tests_lib /tmp/lib
  chmod +x /tmp/e2e_user_flows/test.sh
' >/dev/null

log "5/5  running E2E suite (=  17 tests over ~30s) ..."
# Don't `set -e` around this — we want to surface the exit code, not abort
# shellcheck disable=SC2086
ssh $ssh_opts "$target" '/tmp/e2e_user_flows/test.sh'
rc=$?

if [ "$rc" -eq 0 ]; then
  log "DONE: E2E PASS"
else
  log "DONE: E2E FAIL (exit $rc)"
fi
exit "$rc"
