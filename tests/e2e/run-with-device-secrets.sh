#!/usr/bin/env bash
# run-with-device-secrets.sh — run Playwright e2e specs with a device's secrets
# fetched from the fleet-manager and handed to Playwright through its
# ENVIRONMENT ONLY.
#
# Why this exists: the PIN specs skip without DEVICE_PIN and the dashboard
# specs skip without an admin password, and the only other way to supply them
# was typing the values into a shell — which lands them in shell history and,
# via run_e2e_tests.sh --admin-pass, in the process table (`ps` shows argv to
# every user on the host). This script never prints, logs, or puts a secret on
# a command line: the bearer token reaches curl on stdin, the JSON bodies stay
# in shell variables, and the values are exported into the exec'd Playwright
# process and nowhere else.
#
# Usage:
#   tests/e2e/run-with-device-secrets.sh [options] [--] [playwright test args]
#
# Options:
#   --device ID        fleet-manager device id      (default: KIB-SON-00000031)
#   --device-ip IP     HA host; sets DEVICE_IP + DEVICE_URL for the fixtures.
#                      Alternatively export DEVICE_IP or DEVICE_URL yourself.
#   --fm-url URL       fleet-manager base            (default: $GA_FM_URL; mesh-only, never a literal here)
#   --token-file PATH  bearer token file             (default: ~/.config/ga/fleet-manager.token)
#   -h, --help         this text
#
# Everything else (and everything after `--`) is passed to `npx playwright test`.
#
# Fetched (both need the operator bearer token):
#   GET /api/label-credentials/{id}          -> DEVICE_PIN         (onboarding_pin)
#   GET /api/devices/{id}/admin-credential   -> HA_ADMIN_PASSWORD  (admin_password)
#                                               + HA_ADMIN_PASS (the name helpers/auth.ts reads)
#   HA_ADMIN_USER comes from the label row when it carries a user field, else "admin".
#   If the device has not reported its admin credential yet (404), the label's
#   printed admin_password is used instead and that substitution is announced.
#
# Examples:
#   tests/e2e/run-with-device-secrets.sh --device-ip <device-mesh-ip> -- \
#       tests/pin-verification.spec.ts --project=desktop
#   DEVICE_IP=<device-mesh-ip> tests/e2e/run-with-device-secrets.sh \
#       tests/dashboard-smoke.spec.ts --project=desktop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$SCRIPT_DIR"

DEVICE_ID="KIB-SON-00000031"
FM_URL="${GA_FM_URL:-}"
TOKEN_FILE="${HOME}/.config/ga/fleet-manager.token"
DEVICE_IP_ARG=""
PW_ARGS=()

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)     DEVICE_ID="$2";     shift 2 ;;
    --device-ip)  DEVICE_IP_ARG="$2"; shift 2 ;;
    --fm-url)     FM_URL="$2";        shift 2 ;;
    --token-file) TOKEN_FILE="$2";    shift 2 ;;
    -h|--help)    usage 0 ;;
    --)           shift; PW_ARGS+=("$@"); break ;;
    *)            PW_ARGS+=("$1");    shift ;;
  esac
done

FM_URL="${FM_URL%/}"
[[ -n "$FM_URL" ]] || die "no fleet-manager URL: pass --fm-url or export GA_FM_URL (mesh-only address, kept out of this public repo)"

# --- Preconditions ---------------------------------------------------------
command -v curl >/dev/null || die "curl is required"
if command -v jq >/dev/null; then
  PARSER="jq"
elif command -v python3 >/dev/null; then
  PARSER="python3"
else
  die "need jq or python3 to parse the fleet-manager responses"
fi

[[ -r "$TOKEN_FILE" ]] || die "token file not readable: $TOKEN_FILE"
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || die "token file is empty: $TOKEN_FILE"

# The device address is NOT defaulted: the fixture would silently fall back
# to homeassistant.local and the run would measure the wrong device.
if [[ -n "$DEVICE_IP_ARG" ]]; then
  export DEVICE_IP="$DEVICE_IP_ARG"
  export DEVICE_URL="http://${DEVICE_IP_ARG}:8123"
elif [[ -n "${DEVICE_IP:-}" ]]; then
  export DEVICE_URL="${DEVICE_URL:-http://${DEVICE_IP}:8123}"
elif [[ -z "${DEVICE_URL:-}" ]]; then
  die "no device address: pass --device-ip <ip> or export DEVICE_IP / DEVICE_URL"
fi

# --- Helpers ---------------------------------------------------------------

# fm_get PATH -> JSON body on stdout. Non-2xx: prints only the status code and
# the path to stderr (never the body — a body can carry a value) and returns 1.
# The Authorization header is fed to curl on stdin (-H @-) so the token is not
# in argv.
fm_get() {
  local path="$1" out status body
  out="$(printf 'Authorization: Bearer %s\n' "$TOKEN" \
    | curl -sS --max-time 20 -H @- -w '\n%{http_code}' "${FM_URL}${path}")" || {
    echo "ERROR: fleet-manager unreachable at ${FM_URL}${path}" >&2
    return 1
  }
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "fleet-manager: GET ${path} -> HTTP ${status}" >&2
    return 1
  fi
  printf '%s' "$body"
}

# json_field KEY <json -> value (empty when absent / null). Never echoes input.
json_field() {
  case "$PARSER" in
    jq) jq -r --arg k "$1" 'if type == "object" and has($k) and .[$k] != null then .[$k] else empty end' ;;
    python3) python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
v = d.get(sys.argv[1]) if isinstance(d, dict) else None
if v is not None:
    sys.stdout.write(str(v))
' "$1" ;;
  esac
}

# --- Fetch -----------------------------------------------------------------
# The LIVE onboarding PIN is the one identity-backfill minted (fm identity_backfill
# store, GET /api/devices/{id}/identity); the label store carries the PIN printed
# on the box, which differs after any identity-backfill (K31, 2026-09-03: the two
# hashes did not match and the "correct PIN" test ran with the wrong one).
LABEL_JSON="$(fm_get "/api/label-credentials/${DEVICE_ID}" 2>/dev/null || true)"
PIN_SOURCE="identity"
IDENTITY_JSON="$(fm_get "/api/devices/${DEVICE_ID}/identity" 2>/dev/null || true)"
PIN="$(printf '%s' "$IDENTITY_JSON" | json_field onboarding_pin 2>/dev/null || true)"
if [[ -z "$PIN" ]]; then
  echo "WARNING: no identity record for ${DEVICE_ID} — falling back to the LABEL pin (may differ from the device)" >&2
  PIN_SOURCE="label-credentials (fallback)"
  [[ -n "$LABEL_JSON" ]] || LABEL_JSON="$(fm_get "/api/label-credentials/${DEVICE_ID}")"
  PIN="$(printf '%s' "$LABEL_JSON" | json_field onboarding_pin)"
fi
[[ -n "$PIN" ]] || die "no onboarding_pin for ${DEVICE_ID} (identity + label)"
# Product truth (Thomas, 2026-09-03): the resident uses the LABEL/QR PIN. Until
# fm 0.113.0 (identity-backfill aligns with the label) is deployed the two can
# differ; say so loudly, compare by equality only, never print either.
LABEL_PIN="$(printf '%s' "${LABEL_JSON:-}" | json_field onboarding_pin 2>/dev/null || true)"
if [[ -n "$LABEL_PIN" && "$LABEL_PIN" != "$PIN" ]]; then
  echo "WARNING: the device's live PIN (identity record) differs from the LABEL PIN — the printed QR would be rejected on this device (fm identity-backfill < 0.113.0)" >&2
fi

ADMIN_USER=""
for key in admin_user admin_username username; do
  ADMIN_USER="$(printf '%s' "$LABEL_JSON" | json_field "$key")"
  [[ -n "$ADMIN_USER" ]] && break
done
ADMIN_USER="${ADMIN_USER:-admin}"

PASSWORD_SOURCE="admin-credential"
if ADMIN_JSON="$(fm_get "/api/devices/${DEVICE_ID}/admin-credential")"; then
  ADMIN_PASSWORD="$(printf '%s' "$ADMIN_JSON" | json_field admin_password)"
else
  # Loud fallback (rule 44): the device has not reported its generated owner
  # password, so the label's printed password is the best remaining guess.
  echo "WARNING: ${DEVICE_ID} has not reported an admin credential; falling back to the label's admin_password" >&2
  PASSWORD_SOURCE="label-credentials (fallback)"
  ADMIN_PASSWORD="$(printf '%s' "$LABEL_JSON" | json_field admin_password)"
fi
[[ -n "$ADMIN_PASSWORD" ]] || die "no admin password available for ${DEVICE_ID}"

# --- Hand over -------------------------------------------------------------
export DEVICE_PIN="$PIN"
export HA_ADMIN_PASSWORD="$ADMIN_PASSWORD"
export HA_ADMIN_PASS="$ADMIN_PASSWORD"
export HA_ADMIN_USER="$ADMIN_USER"
export GA_DEVICE_ID="$DEVICE_ID"
unset PIN ADMIN_PASSWORD LABEL_JSON ADMIN_JSON TOKEN

echo "=============================================="
echo "  GA OS E2E (device secrets from fleet-manager)"
echo "  Device:   ${DEVICE_ID} at ${DEVICE_URL}"
echo "  fm:       ${FM_URL}"
echo "  DEVICE_PIN:        set (${#DEVICE_PIN} chars, source: ${PIN_SOURCE})"
echo "  HA_ADMIN_PASSWORD: set (source: ${PASSWORD_SOURCE})"
echo "  HA_ADMIN_USER:     ${HA_ADMIN_USER}"
echo "=============================================="

cd "$E2E_DIR"
exec npx playwright test "${PW_ARGS[@]}"
