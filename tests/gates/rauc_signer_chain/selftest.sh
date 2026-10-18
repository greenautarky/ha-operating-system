#!/usr/bin/env bash
# Self-test: the build must stop, at the point the keyring is written, when the
# RAUC signing certificate does not chain to the OTA root (parity G5).
#
# Drives the LIVE install_rauc_certs() of upstream rauc.sh + GA patch 0110, as
# the build sees it (scripts/apply-haos-patches.sh --export), over fixture
# certificates minted here (openssl only, offline):
#   must-pass: a signing cert issued by the root -> returns, keyring = exactly
#              the root (one anchor)
#   must-fail: a self-signed signing cert; a cert issued by ANOTHER root; an
#              expired leaf is NOT this guard's business (not asserted here);
#              each must exit non-zero, name the cause on stderr, and leave NO
#              keyring.pem behind (nothing a later step could ship)
#   plus a mutant: the pre-fix behaviour (append instead of fail) is rebuilt
#              from the live function and MUST be caught by the same cases.
# The function under test is never re-declared here; if the export or the
# function extraction finds nothing, this FAILS.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
command -v openssl >/dev/null || { echo "FAIL: openssl required"; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
bad=0 n=0

"$repo/scripts/apply-haos-patches.sh" --export "$tmp/exp" buildroot-external/scripts/rauc.sh >/dev/null \
  || { echo "FAIL: cannot export the live rauc.sh (is haos/ checked out?)"; exit 1; }
live="$tmp/exp/buildroot-external/scripts/rauc.sh"
grep -q '^function install_rauc_certs' "$live" || { echo "FAIL: install_rauc_certs not found in the live rauc.sh"; exit 1; }

# --- fixture PKI
mkca() { # mkca <name> : self-signed CA in $tmp/pki/<name>.{key,pem}
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/pki/$1.key" -out "$tmp/pki/$1.pem" \
    -days 3650 -subj "/CN=fixture $1" -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
}
mkleaf() { # mkleaf <name> <issuer-ca-name|self>
  openssl req -newkey rsa:2048 -nodes -keyout "$tmp/pki/$1.key" -out "$tmp/pki/$1.csr" -subj "/CN=fixture signer $1" >/dev/null 2>&1
  if [ "$2" = self ]; then
    openssl req -x509 -key "$tmp/pki/$1.key" -in "$tmp/pki/$1.csr" -out "$tmp/pki/$1.pem" -days 3650 \
      -subj "/CN=fixture signer $1" -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
  else
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' >"$tmp/pki/$1.ext"
    openssl x509 -req -in "$tmp/pki/$1.csr" -CA "$tmp/pki/$2.pem" -CAkey "$tmp/pki/$2.key" -CAcreateserial \
      -out "$tmp/pki/$1.pem" -days 3650 -extfile "$tmp/pki/$1.ext" >/dev/null 2>&1
  fi
}
mkdir -p "$tmp/pki"
mkca root; mkca other; mkleaf good root; mkleaf selfsigned self; mkleaf foreign other
for f in root good selfsigned foreign; do [ -s "$tmp/pki/$f.pem" ] || { echo "FAIL: fixture $f not minted"; exit 1; }; done

# run <rauc.sh> <signer> : prints "rc|stderr-one-line" ; leaves $tmp/run/target/etc/rauc/keyring.pem
run() {
  rm -rf "$tmp/run"; mkdir -p "$tmp/run/target/etc/rauc" "$tmp/run/secrets"
  cp "$tmp/pki/$2.pem" "$tmp/run/secrets/cert.pem"; cp "$tmp/pki/$2.key" "$tmp/run/secrets/key.pem"
  ( export TARGET_DIR="$tmp/run/target" GA_SECRETS_DIR="$tmp/run/secrets" GA_OTA_ROOT_CA="$tmp/pki/root.pem" BR2_EXTERNAL_GA_HAOS_PATH="$tmp/run" BR2_EXTERNAL_HAOS_PATH="$tmp/run"
    set -e; . "$1"; install_rauc_certs ) >"$tmp/run/out" 2>"$tmp/run/err"
  echo "$?"
}
anchors() { grep -c 'BEGIN CERTIFICATE' "$tmp/run/target/etc/rauc/keyring.pem" 2>/dev/null || echo 0; }
check() { # label want-rc(0|nonzero) want-anchors(N|none) stderr-substring
  n=$((n+1))
  local rc="$RC" a ok=1
  a="$(anchors)"; [ -e "$tmp/run/target/etc/rauc/keyring.pem" ] || a=none
  if [ "$2" = 0 ]; then [ "$rc" = 0 ] || ok=0; else [ "$rc" != 0 ] || ok=0; fi
  [ "$a" = "$3" ] || ok=0
  [ -z "$4" ] || grep -qF -- "$4" "$tmp/run/err" || ok=0
  if [ "$ok" = 1 ]; then echo "  ok    $1 (rc=$rc, anchors=$a)"; else echo "  FAIL  $1 rc=$rc anchors=$a want rc~$2 anchors=$3 '$4' :: $(tr '\n' ' ' <"$tmp/run/err" | cut -c1-200)"; bad=1; fi
}

RC="$(run "$live" good)";       check "must-pass/chained-signer" 0 1 ""
RC="$(run "$live" selfsigned)"; check "must-fail/self-signed-signer" nonzero none "does not chain"
RC="$(run "$live" foreign)";    check "must-fail/signer-from-another-root" nonzero none "does not chain"

# Mutant = the pre-fix behaviour, derived from the LIVE function (append instead of fail).
mut="$tmp/rauc-mutant.sh"
python3 - "$live" "$mut" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
# replace the failure branch (4 lines) of the chain check with the old append
new,k=re.subn(r'(if ! openssl verify -CAfile "\$\{base_ca\}" -no-CApath "\$\{cert\}"; then\n)(?:.*\n){4}(\s*fi)',
              r'\1        openssl x509 -in "${cert}" -text >> "${TARGET_DIR}/etc/rauc/keyring.pem"\n\2', s, count=1)
open(sys.argv[2],'w').write(new)
sys.exit(0 if k==1 else 3)
PY
[ $? -eq 0 ] || { echo "FAIL: could not derive the mutant from the live function"; exit 1; }
n=$((n+1)); RC="$(run "$mut" selfsigned)"; a="$(anchors)"
if [ "$RC" = 0 ] && [ "$a" = 2 ]; then echo "  ok    mutant/append-instead-of-fail is distinguishable (rc=0, anchors=2: the cases above would be red)"
else echo "  FAIL  mutant did not behave as the pre-fix code (rc=$RC anchors=$a) - the must-fail cases prove nothing"; bad=1; fi

[ "$n" -ge 4 ] || { echo "FAIL: only $n cases ran"; exit 1; }
echo "$n cases ran"
exit "$bad"
