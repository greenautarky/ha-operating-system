#!/bin/sh
# selftest.sh — scripts/lib/vccio5-key.sh (Odoo #1900), host side, no root, no card.
# Drives the LIVE vcc_seed_dir on scratch boot directories:
#   must-pass  #1900 image -> exactly one ga_vccio5=3v3 line; idempotent; other
#              lines kept; a stale ga_vccio5=1v8 replaced; a missing file created
#   must-flag  pre-#1900 image (no 3.3 V DTB) refused without the jump-test flag
#   allow      pre-#1900 image + allow -> rc 3, nothing written
# FAILS if the library or its function cannot be found (never skips).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../../../scripts/lib/vccio5-key.sh"
[ -r "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
. "$LIB"
type vcc_seed_dir >/dev/null 2>&1 || { echo "FATAL: vcc_seed_dir not defined by $LIB"; exit 1; }

T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "  ok    $*"; }
bad() { n=$((n+1)); fails=$((fails+1)); echo "  FAIL  $*"; }
cnt() { tr -d '\r' < "$1/haos-config.txt" 2>/dev/null | grep -cx "$VCC_KEY"; }

mkdir "$T/a"; : > "$T/a/$VCC_VARIANT"; : > "$T/a/haos-config.txt"
vcc_seed_dir "$T/a" 0 >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cnt "$T/a")" = 1 ] && ok "#1900 image, empty haos-config.txt -> one key line" || bad "seed #1900 image (rc=$rc, lines=$(cnt "$T/a"))"
vcc_seed_dir "$T/a" 0 >/dev/null
[ "$(cnt "$T/a")" = 1 ] && ok "idempotent: second run keeps exactly one line" || bad "second run left $(cnt "$T/a") lines"

mkdir "$T/b"; : > "$T/b/$VCC_VARIANT"; printf 'overlays=foo\r\nga_vccio5=1v8\r\n' > "$T/b/haos-config.txt"
vcc_seed_dir "$T/b" 0 >/dev/null
[ "$(tr -d '\r' < "$T/b/haos-config.txt")" = "$(printf 'overlays=foo\n%s' "$VCC_KEY")" ] \
  && ok "other lines kept, stale ga_vccio5=1v8 replaced" || bad "content: $(cat "$T/b/haos-config.txt")"

mkdir "$T/c"; : > "$T/c/$VCC_VARIANT"
vcc_seed_dir "$T/c" 0 >/dev/null; [ "$(cnt "$T/c")" = 1 ] && ok "missing haos-config.txt is created with the key" || bad "missing file case"

mkdir "$T/d"; : > "$T/d/haos-config.txt"
out=$(vcc_seed_dir "$T/d" 0); rc=$?
[ "$rc" = 1 ] && [ "$(cnt "$T/d")" = 0 ] && ok "pre-#1900 image REFUSED without the jump-test flag" || bad "pre-#1900 refusal (rc=$rc)"
case "$out" in *LEGACY*) ok "the refusal names the legacy 1.8 V setting" ;; *) bad "refusal text: $out" ;; esac
vcc_seed_dir "$T/d" 1 >/dev/null; rc=$?
[ "$rc" = 3 ] && [ "$(cnt "$T/d")" = 0 ] && ok "pre-#1900 + allow -> rc 3, nothing written" || bad "allow case (rc=$rc)"

vcc_seed_dir "$T/nope" 0 >/dev/null; rc=$?
[ "$rc" = 1 ] && ok "a missing boot dir fails" || bad "missing dir rc=$rc"

grep -q 'vcc_seed_dir' "$HERE/../../../scripts/verify-sd.sh" && ok "verify-sd.sh calls vcc_seed_dir" || bad "verify-sd.sh does not call vcc_seed_dir (the flash path would skip the key)"

# verify-sd.sh runs under set -euo pipefail: a plain `x="$(vcc_seed_dir ..)"; rc=$?`
# would abort the script SILENTLY on a refused image (measured 2026-11-11). The
# call must capture the rc with `|| _vcc_rc=$?`.
grep -q '_vcc_out="$(vcc_seed_dir .*)" || _vcc_rc=$?' "$HERE/../../../scripts/verify-sd.sh" \
  && ok "verify-sd.sh captures the rc set -e safe (|| _vcc_rc=\$?)" || bad "verify-sd.sh calls vcc_seed_dir without '|| _vcc_rc=\$?' (set -e would abort silently)"

echo "vccio5_key: $((n-fails))/$n ok"
[ "$fails" = 0 ]
