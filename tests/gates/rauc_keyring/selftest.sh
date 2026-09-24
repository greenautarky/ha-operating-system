#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the RAUC keyring audit must go BOTH ways (ADR-0027 D9).
# =============================================================================
# WHY THIS EXISTS
# ---------------
# scripts/verify-rauc-keyring.sh is the only thing that asserts what a device
# will trust. It normally runs over a real build output on the builder, so on a
# pull request nobody sees it fire — and an audit nobody has seen fire is not
# evidence. This drives the LIVE audit over keyrings whose correct verdict is
# known in advance, and asserts that the SPECIFIC guard fires (KEYRING-02, -03,
# -05, -06 — not merely "something failed").
#
# THE ONE COMPROMISE, stated plainly
# ----------------------------------
# The audit pins the fingerprint of the real OTA root. That certificate is not
# in the repository (ota/*.pem is gitignored), and a certificate with a given
# SHA-256 fingerprint cannot be manufactured. So:
#
#   * every must-FAIL case that is about "not the pinned root" runs against the
#     UNMODIFIED live script — the real pin rejects our fixture root;
#   * cases that need a keyring the audit ACCEPTS run the live script with ONE
#     line changed: the GA_OTA_ROOT_FP assignment, pointed at a fixture root.
#     Every decision under test is the live code; the substitution is asserted
#     to have replaced exactly one line, and fails the run if it did not.
#   * the pin VALUE is held against docs/RAUC-KEYRING.md, where the root's
#     fingerprint was recorded when it was minted — two sources that must agree.
#   * if the public root certificate is ever committed at
#     tests/gates/rauc_keyring/fixtures/ota-root-ca.pem, the green case runs
#     against the UNMODIFIED script too. Until then the real green case is the
#     bake: ga_build.sh --check-root and RAUC-KEYRING-01 on every build.
#
# Fully offline: temp dirs, openssl only, ~3 seconds.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
AUDIT="$ROOT/scripts/verify-rauc-keyring.sh"
DOC="$ROOT/docs/RAUC-KEYRING.md"
REAL_ROOT_PEM="$HERE/fixtures/ota-root-ca.pem"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; YEL=''; NC=''; }
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

# FAIL, never skip, if the subject or a tool disappears.
[[ -x "$AUDIT" ]] || { echo "FATAL: $AUDIT missing or not executable"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "FATAL: openssl required"; exit 1; }

# --- the live pin ------------------------------------------------------------
PIN_LINES="$(grep -cE '^GA_OTA_ROOT_FP="' "$AUDIT")"
[[ "$PIN_LINES" == "1" ]] || { echo "FATAL: expected exactly one GA_OTA_ROOT_FP= line in the audit, found $PIN_LINES"; exit 1; }
LIVE_PIN="$(sed -nE 's/^GA_OTA_ROOT_FP="([^"]*)".*/\1/p' "$AUDIT")"
[[ "$LIVE_PIN" =~ ^([0-9A-F]{2}:){31}[0-9A-F]{2}$ ]] || {
  echo "FATAL: the live pin is not a SHA-256 fingerprint: '$LIVE_PIN'"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- fixture certificates ----------------------------------------------------
# `openssl ca -selfsign` because it takes explicit start/end dates on every
# OpenSSL 3.x (req -not_after only exists from 3.4 on; CI runs 3.0).
mkcert() { # mkcert <name> <CN> <ca:yes|no> <enddate YYMMDDHHMMSSZ>
  local n="$1" cn="$2" isca="$3" end="$4" d="$WORK/ca-$1"
  mkdir -p "$d/new"; : > "$d/index.txt"; echo 01 > "$d/serial"
  cat > "$d/cnf" <<EOF
[ ca ]
default_ca = c
[ c ]
dir = $d
database = $d/index.txt
new_certs_dir = $d/new
serial = $d/serial
default_md = sha256
policy = p
unique_subject = no
copy_extensions = none
[ p ]
commonName = supplied
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = $cn
[ ext_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
[ ext_leaf ]
basicConstraints = critical,CA:FALSE
EOF
  openssl req -new -newkey rsa:2048 -nodes -keyout "$d/key.pem" -out "$d/req.pem" \
    -config "$d/cnf" >/dev/null 2>&1 || return 1
  openssl ca -batch -selfsign -config "$d/cnf" -keyfile "$d/key.pem" -in "$d/req.pem" \
    -startdate 200101000000Z -enddate "$end" \
    -extensions "ext_$([[ $isca == yes ]] && echo ca || echo leaf)" \
    -out "$WORK/$n.pem" >/dev/null 2>&1 || return 1
  openssl x509 -in "$WORK/$n.pem" -out "$WORK/$n.pem" 2>/dev/null   # strip the text header
}
fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//'; }

FAR="$(date -u -d '+10 years' +%y%m%d%H%M%SZ)"
SOON="$(date -u -d '+100 days' +%y%m%d%H%M%SZ)"
mkcert root    "GA test OTA root"          yes "$FAR"   || { echo "FATAL: openssl could not mint fixture certs"; exit 1; }
mkcert other   "GA test second root"       yes "$FAR"
mkcert selfdev "HassOS Self-signed Development Certificate" no "$FAR"
mkcert noca    "GA test root without CA"   no  "$FAR"
mkcert expired "GA test expired root"      yes 210101000000Z
mkcert soon    "GA test root expiring"     yes "$SOON"
for c in root other selfdev noca expired soon; do [[ -s "$WORK/$c.pem" ]] || { echo "FATAL: fixture $c.pem not created"; exit 1; }; done

# A copy of the LIVE audit with only the pin changed. Asserted: one line, not zero.
pinned_copy() { # pinned_copy <out> <fingerprint>
  sed -E "s/^GA_OTA_ROOT_FP=\"[^\"]*\"/GA_OTA_ROOT_FP=\"$2\"/" "$AUDIT" > "$1"
  chmod +x "$1"
  if cmp -s "$1" "$AUDIT" && [[ "$2" != "$LIVE_PIN" ]]; then
    echo "FATAL: pin substitution changed nothing — the self-test would be testing the wrong pin"; exit 1
  fi
  [[ "$(diff "$AUDIT" "$1" | grep -c '^>')" -le 1 ]] || { echo "FATAL: pin substitution changed more than one line"; exit 1; }
}

# A build output whose keyring is the concatenation of the given certs, written
# the way install_rauc_certs() writes it (a plain copy, then `x509 -text`
# appends — i.e. human-readable text between the PEM blocks).
mkout() { # mkout <name> <cert>...
  local o="$WORK/out-$1"; shift
  mkdir -p "$o/target/etc/rauc"
  local first=1 c
  for c in "$@"; do
    if (( first )); then cat "$c" > "$o/target/etc/rauc/keyring.pem"; first=0
    else openssl x509 -in "$c" -text >> "$o/target/etc/rauc/keyring.pem"; fi
  done
  echo "$o"
}

# A repo root for KEYRING-06: the live tree's meta + signing scripts, with an
# optional line appended to rauc.sh (the residue under test).
mkrepo() { # mkrepo <name> [<line appended to rauc.sh>]
  local r="$WORK/repo-$1"
  mkdir -p "$r/buildroot-external/scripts" "$r/buildroot-external/ota"
  cp "$ROOT/buildroot-external/meta" "$r/buildroot-external/meta"
  cp "$ROOT/buildroot-external/scripts/rauc.sh" "$ROOT/buildroot-external/scripts/hdd-image.sh" "$r/buildroot-external/scripts/"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >> "$r/buildroot-external/scripts/rauc.sh"
  echo "$r"
}

# expect <label> <want-rc> <must-match-regex|-> <audit> <repo> <out>
expect() {
  local label="$1" want="$2" re="$3" audit="$4" repo="$5" out="$6" log rc
  ran=$((ran + 1))
  log="$WORK/log.$ran"
  REPO_ROOT="$repo" "$audit" "$out" >"$log" 2>&1
  rc=$?
  if [[ "$rc" != "$want" ]]; then
    bad "$label — exit $rc, want $want"; sed 's/^/        /' "$log" | grep -E 'FAIL|ERROR|WARN' | head -6
    return
  fi
  if [[ "$re" != "-" ]] && ! grep -qE -- "$re" "$log"; then
    bad "$label — exit $rc as expected, but NOT from the guard under test (no line matching: $re)"
    sed 's/^/        /' "$log" | grep -E 'FAIL|ERROR|WARN' | head -6
    return
  fi
  ok "$label"
}

FX_PIN="$(fp "$WORK/root.pem")"
PINNED="$WORK/audit-pinned.sh";      pinned_copy "$PINNED" "$FX_PIN"
PLACEHOLDER="$WORK/audit-placeholder.sh"; pinned_copy "$PLACEHOLDER" "REPLACE-WITH-THE-OTA-ROOT-FINGERPRINT"
LIVE_REPO="$ROOT"

echo "=== Gate self-test: RAUC keyring audit (ADR-0027 D9) ==="
echo "live pin ${LIVE_PIN:0:23}... read from $(basename "$AUDIT") — not copied"
echo

echo "pin value — must agree with the fingerprint recorded when the root was minted:"
ran=$((ran + 1))
if [[ -f "$DOC" ]] && grep -F "$LIVE_PIN" "$DOC" | grep -qi 'root'; then
  ok "docs/RAUC-KEYRING.md records the same root fingerprint as the live pin"
else
  bad "docs/RAUC-KEYRING.md does not record the live pin on a root line — two sources disagree"
fi
echo

echo "must-fail — the audit has to flag every one of these (and with the named guard):"
expect "live pin: a keyring holding a different root" 1 'FAIL.*KEYRING-03' \
  "$AUDIT" "$LIVE_REPO" "$(mkout wrongroot "$WORK/root.pem")"
expect "a second anchor next to the pinned root" 1 'FAIL.*KEYRING-02.*NOT the pinned OTA root' \
  "$PINNED" "$LIVE_REPO" "$(mkout second "$WORK/root.pem" "$WORK/other.pem")"
expect "a self-signed 'development' cert next to the root (tolerated before D9)" 1 'FAIL.*KEYRING-02.*HassOS Self-signed Development' \
  "$PINNED" "$LIVE_REPO" "$(mkout selfdev "$WORK/root.pem" "$WORK/selfdev.pem")"
expect "the pinned root twice (two blocks)" 1 'FAIL.*KEYRING-02.*2 certificate blocks' \
  "$PINNED" "$LIVE_REPO" "$(mkout dup "$WORK/root.pem" "$WORK/root.pem")"
_o="$(mkout garbage "$WORK/root.pem")"
printf -- '-----BEGIN CERTIFICATE-----\nnot-a-certificate\n-----END CERTIFICATE-----\n' >> "$_o/target/etc/rauc/keyring.pem"
expect "an unparseable block next to the root" 1 'FAIL.*KEYRING-02.*do not parse' \
  "$PINNED" "$LIVE_REPO" "$_o"
NOCA_PINNED="$WORK/audit-noca.sh"; pinned_copy "$NOCA_PINNED" "$(fp "$WORK/noca.pem")"
expect "the pinned root without CA:TRUE" 1 'FAIL.*KEYRING-03.*not marked CA:TRUE' \
  "$NOCA_PINNED" "$LIVE_REPO" "$(mkout noca "$WORK/noca.pem")"
EXP_PINNED="$WORK/audit-expired.sh"; pinned_copy "$EXP_PINNED" "$(fp "$WORK/expired.pem")"
expect "the pinned root, expired" 1 'FAIL.*KEYRING-05.*EXPIRED' \
  "$EXP_PINNED" "$LIVE_REPO" "$(mkout expired "$WORK/expired.pem")"
expect "rauc.sh reads signing material from the checkout again" 1 "FAIL.*KEYRING-06.*/build/key" \
  "$PINNED" "$(mkrepo fallback '    [ -f "/build/key.pem" ] && echo "/build/key.pem"')" "$(mkout r6a "$WORK/root.pem")"
# shellcheck disable=SC2016  # the residue is a literal line of shell, not expanded here
expect "rauc.sh selects a key by build mode again" 1 'FAIL.*KEYRING-06.*ga_is_prod' \
  "$PINNED" "$(mkrepo selector 'function ga_is_prod() { [ "${GA_ENV:-dev}" = "prod" ]; }')" "$(mkout r6b "$WORK/root.pem")"
# shellcheck disable=SC2016  # the residue is a literal line of shell, not expanded here
expect "rauc.sh points at a dev CA again" 1 'FAIL.*KEYRING-06.*dev-ca' \
  "$PINNED" "$(mkrepo devca '    echo "${BR2_EXTERNAL_HASSOS_PATH}/ota/dev-ca.pem"')" "$(mkout r6c "$WORK/root.pem")"
_r="$(mkrepo bridge)"; printf 'GA_LEGACY_CA_BRIDGE="false"\n' >> "$_r/buildroot-external/meta"
expect "the retired CA bridge flag is back in meta" 1 'FAIL.*KEYRING-06.*GA_LEGACY_CA_BRIDGE' \
  "$PINNED" "$_r" "$(mkout r6d "$WORK/root.pem")"
expect "a placeholder pin refuses to run (exit 2), never compares" 2 'not a SHA-256 fingerprint' \
  "$PLACEHOLDER" "$LIVE_REPO" "$(mkout ph "$WORK/root.pem")"
echo

echo "must-pass — flagging any of these would train people to skip the audit:"
expect "the pinned root alone, against the LIVE signing code (no residue)" 0 'OK.*KEYRING-06' \
  "$PINNED" "$LIVE_REPO" "$(mkout good "$WORK/root.pem")"
# The shape install_rauc_certs() produces when it appends: text around the PEM.
_o="$WORK/out-texty"; mkdir -p "$_o/target/etc/rauc"
openssl x509 -in "$WORK/root.pem" -text > "$_o/target/etc/rauc/keyring.pem"
expect "the pinned root written with 'x509 -text' (readable text around the PEM)" 0 'OK.*KEYRING-02' \
  "$PINNED" "$LIVE_REPO" "$_o"
SOON_PINNED="$WORK/audit-soon.sh"; pinned_copy "$SOON_PINNED" "$(fp "$WORK/soon.pem")"
expect "a root expiring in 100 days is a WARNING, not a failure" 0 'WARN.*KEYRING-05' \
  "$SOON_PINNED" "$LIVE_REPO" "$(mkout soon "$WORK/soon.pem")"
if [[ -s "$REAL_ROOT_PEM" ]]; then
  expect "LIVE pin, real public root certificate (unmodified audit)" 0 'OK.*KEYRING-03' \
    "$AUDIT" "$LIVE_REPO" "$(mkout real "$REAL_ROOT_PEM")"
else
  printf '  %snote%s  live-pin green case not run here: %s is not committed.\n' "$YEL" "$NC" "${REAL_ROOT_PEM#"$ROOT"/}"
  printf '        It runs on every bake instead (ga_build.sh --check-root, RAUC-KEYRING-01).\n'
fi
echo

echo "--check-root (ga_build.sh asks this before the build starts):"
_cr() { # _cr <label> <want> <audit> <pem>
  ran=$((ran + 1)); local rc
  "$3" --check-root "$4" >/dev/null 2>&1; rc=$?
  if [[ "$rc" == "$2" ]]; then ok "$1"; else bad "$1 — exit $rc, want $2"; fi
}
cat "$WORK/root.pem" "$WORK/other.pem" > "$WORK/two.pem"
_cr "live pin rejects a root that is not the pinned one"      1 "$AUDIT"  "$WORK/root.pem"
_cr "a file with two certificates is refused"                 1 "$PINNED" "$WORK/two.pem"
_cr "the pinned root alone is accepted"                       0 "$PINNED" "$WORK/root.pem"
_cr "a missing file cannot be checked (exit 2)"               2 "$PINNED" "$WORK/nope.pem"
echo

if (( ran < 20 )); then
  echo "ERROR: only $ran checks ran — the self-test lost cases, refusing to report a pass" >&2
  exit 2
fi
echo "${ran} checks, ${fails} failed"
(( fails == 0 )) || exit 1
echo "The keyring audit was shown to fire, with the named guard, on every known-bad keyring AND to stay quiet on known-good ones."
