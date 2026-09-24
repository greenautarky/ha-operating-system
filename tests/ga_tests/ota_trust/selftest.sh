#!/bin/sh
# selftest.sh — the KEYRING-NEG verdict logic, red AND green, without hardware.
#
# test.sh can only run for real on a device with a staged throwaway bundle, so
# on a pull request its verdicts are never exercised. This drives the LIVE
# test.sh with a stub `rauc` on PATH that answers the way RAUC does. The
# rejection text is RAUC 1.13's real output for a bundle whose signer the
# keyring does not trust (captured 2026-09-24 in a Debian container):
#   "signature verification failed: Verify error: self-signed certificate"
#
# The property worth protecting is the discriminator: a rejection for any
# OTHER reason (compatible mismatch, D-Bus down, broken file) must not count as
# proof that the device refuses foreign signatures — and if the device ACCEPTS
# the signature, `rauc install` must never be run.
#
# Needs sh + coreutils. No device, no rauc.
HERE="$(cd "$(dirname "$0")" && pwd)"
SUITE="$HERE/test.sh"
[ -r "$SUITE" ] || { echo "FATAL: $SUITE missing"; exit 1; }

W="$(mktemp -d 2>/dev/null || echo /tmp/ota_trust_st_$$)"
trap 'rm -rf "$W"' EXIT INT TERM
mkdir -p "$W/bin"
: > "$W/bundle.raucb"; : > "$W/cert.pem"

cat > "$W/bin/rauc" <<'STUB'
#!/bin/sh
# Stub rauc. Behaviour per call is chosen by $SHIM (see selftest.sh cases).
echo "$*" >> "$SHIM_LOG"
SIG='signature verification failed: Verify error: self-signed certificate'
case "$1" in
  status)
    n=$(grep -c '^status' "$SHIM_LOG")
    if [ "$SHIM" = status_moves ] && [ "$n" -ge 2 ]; then echo "RAUC_SLOT_STATUS_1=bad"; else echo "RAUC_SLOT_STATUS_1=good"; fi
    exit 0 ;;
  info)
    case "$2" in
      --keyring=*)  [ "$SHIM" = broken_bundle ] && { echo "Failed to read bundle: truncated"; exit 1; }; echo "Verified inline signature by 'CN=throwaway'"; exit 0 ;;
    esac
    case "$SHIM" in
      accepted)         echo "Verified inline signature by 'CN=throwaway'"; exit 0 ;;
      wrong_reason)     echo "Compatible mismatch: Expected 'haos-ihost' but bundle manifest has 'other'"; exit 1 ;;
      *)                echo "$SIG"; exit 1 ;;
    esac ;;
  install)
    case "$SHIM" in
      install_ok)       echo "Installing done."; exit 0 ;;
      install_dbus)     echo "D-Bus error while installing"; exit 1 ;;
      *)                echo "$SIG"; exit 1 ;;
    esac ;;
esac
echo "stub rauc: unexpected call: $*" >&2; exit 99
STUB
chmod +x "$W/bin/rauc"

pass=0; fail=0; ran=0
# case <label> <SHIM> <want: 0|nonzero> <install-called: yes|no|any> [<regex that must appear>]
case_() {
  ran=$((ran + 1))
  _label="$1"; _shim="$2"; _want="$3"; _inst="$4"; _re="${5:-}"
  _log="$W/calls.$ran"; : > "$_log"
  if [ "$_shim" = missing_inputs ]; then
    PATH="$W/bin:$PATH" SHIM="$_shim" SHIM_LOG="$_log" sh "$SUITE" > "$W/out.$ran" 2>&1; _rc=$?
  else
    PATH="$W/bin:$PATH" SHIM="$_shim" SHIM_LOG="$_log" \
      THROWAWAY_RAUCB="$W/bundle.raucb" THROWAWAY_CERT="$W/cert.pem" sh "$SUITE" > "$W/out.$ran" 2>&1; _rc=$?
  fi
  _ok=1
  if [ "$_want" = 0 ] && [ "$_rc" -ne 0 ]; then _ok=0; fi
  if [ "$_want" = nonzero ] && [ "$_rc" -eq 0 ]; then _ok=0; fi
  _called=no; grep -q '^install' "$_log" && _called=yes
  if [ "$_inst" != any ] && [ "$_inst" != "$_called" ]; then _ok=0; fi
  if [ -n "$_re" ] && ! grep -qE "$_re" "$W/out.$ran"; then _ok=0; fi
  if [ "$_ok" = 1 ]; then
    pass=$((pass + 1)); echo "  ok    $_label"
  else
    fail=$((fail + 1)); echo "  FAIL  $_label (suite exit $_rc, install called: $_called)"
    sed 's/^/        /' "$W/out.$ran" | grep -E 'PASS|FAIL|->' | head -8
  fi
}

echo "=== Self-test: KEYRING-NEG verdict logic (stub rauc, live test.sh) ==="
echo "must-pass:"
case_ "device rejects with a signature error on info AND install, status unchanged" good 0 yes 'PASS  KEYRING-NEG-03'
echo "must-fail:"
case_ "device ACCEPTS the foreign signature -> red, and rauc install is NEVER run" accepted nonzero no 'FAIL  KEYRING-NEG-02.*REJECTS'
case_ "rejected, but for compatible mismatch -> not proof, red"                    wrong_reason nonzero any 'FAIL  KEYRING-NEG-02.*NOT with a signature'
case_ "rauc install exits 0 -> red"                                               install_ok nonzero yes 'FAIL  KEYRING-NEG-03'
case_ "install fails on D-Bus, not on the signature -> red"                        install_dbus nonzero yes 'FAIL  KEYRING-NEG-03.*NOT with a signature'
case_ "slot status changed by the attempt -> red"                                  status_moves nonzero yes 'FAIL  KEYRING-NEG-04'
case_ "positive control fails (broken bundle) -> red, no install"                  broken_bundle nonzero no 'FAIL  KEYRING-NEG-01'
case_ "inputs not staged -> red, never a skip"                                     missing_inputs nonzero no 'FAIL  KEYRING-NEG-00'

if [ "$ran" -lt 8 ]; then echo "ERROR: only $ran cases ran" >&2; exit 2; fi
echo "$ran cases, $fail failed"
[ "$fail" -eq 0 ]
