#!/usr/bin/env bash
# =============================================================================
# ga-ssh-cert-plane-verify.sh — the login matrix against a REAL BOSv1.4.0 device
# =============================================================================
# ADR-0019 step 2, V2/V4/V7 + break-glass. Runs from the OPERATOR's machine
# (the device has no client to test itself with); the device-side half is
# tests/ga_tests/ssh_access (SSH-D-19..26). Same matrix as the local dry run
# (tests/gates/ssh_cert_plane/sshd_dryrun.sh), but against the real CA, the
# real image and the real hardware anchor.
#
#   ga-ssh-cert-plane-verify.sh --host <addr> \
#       --cert  <key>            key whose <key>-cert.pub names THIS device   (must be ACCEPTED)
#       --other <key>            key whose <key>-cert.pub names ANOTHER device (must be REFUSED)
#       [--shared <key>]         the pre-cut shared operator key               (must be REFUSED)
#       [--breakglass <key>]     the break-glass key typed in from paper      (must be ACCEPTED)
#       [--known-hosts <file>]   fleet-manager GET /api/known_hosts output     (host must VERIFY)
#
# Every omitted optional input is reported as UNVERIFIED and makes the run exit
# 2 — "not tested" is never printed as "passed".
#
# ORDER MATTERS: OpenSSH >= 9.8 penalises a source address after failed logins
# and drops its next connections for a while. Accepting cases run FIRST, the
# refusals after, and a pause separates them from the break-glass check.
# -----------------------------------------------------------------------------
set -uo pipefail
HOST=""; PORT=22222; LOGIN_USER=root; CERT=""; OTHER=""; SHARED=""; BG=""; KH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;; --port) PORT="$2"; shift 2 ;; --user) LOGIN_USER="$2"; shift 2 ;;
    --cert) CERT="$2"; shift 2 ;; --other) OTHER="$2"; shift 2 ;;
    --shared) SHARED="$2"; shift 2 ;; --breakglass) BG="$2"; shift 2 ;;
    --known-hosts) KH="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
[[ -n "$HOST" && -n "$CERT" && -n "$OTHER" ]] || { sed -n '6,15p' "$0"; exit 64; }
fails=0; unverified=0
unset SSH_AUTH_SOCK
try() {  # <key> [known_hosts]
  local kh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  [[ -n "${2:-}" ]] && kh_opts=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$2")
  local cert=(); [[ -f "$1-cert.pub" ]] && cert=(-o CertificateFile="$1-cert.pub")
  ssh -F /dev/null -p "$PORT" -i "$1" "${cert[@]}" -o IdentitiesOnly=yes -o IdentityAgent=none \
      -o BatchMode=yes -o ConnectTimeout=10 -o PasswordAuthentication=no "${kh_opts[@]}" \
      -o LogLevel=ERROR "$LOGIN_USER@$HOST" 'echo LOGIN-OK' 2>/dev/null | grep -q LOGIN-OK
}
check() {  # <accept|refuse> <desc> <key> [kh]
  if try "$3" "${4:-}"; then r=accept; else r=refuse; fi
  if [[ "$r" == "$1" ]]; then echo "  ok    $1  $2"; else echo "  FAIL  wanted $1, got $r — $2"; fails=$((fails+1)); fi
}
skip() { echo "  UNVERIFIED  $1"; unverified=$((unverified+1)); }

echo "── $HOST:$PORT ──"
check accept "certificate for this device"                 "$CERT"
if [[ -n "$KH" ]]; then check accept "certificate + host key verified against the fleet register" "$CERT" "$KH"
else skip "host-key verification (pass --known-hosts)"; fi
check refuse "certificate for ANOTHER device"              "$OTHER"
if [[ -n "$SHARED" ]]; then check refuse "pre-cut shared operator key" "$SHARED"; else skip "shared key refused (pass --shared)"; fi
if [[ -n "$BG" ]]; then
  echo "  (waiting 30 s so the refusals above do not penalise the break-glass attempt)"; sleep "${GA_VERIFY_PENALTY_WAIT:-30}"
  check accept "BREAK-GLASS key"                            "$BG"
else skip "break-glass accepted (pass --breakglass)"; fi

if (( fails > 0 )); then echo "RESULT: FAIL ($fails)"; exit 1; fi
if (( unverified > 0 )); then echo "RESULT: incomplete — $unverified case(s) UNVERIFIED"; exit 2; fi
echo "RESULT: all cases verified"
