#!/bin/sh
# selftest.sh — scripts/lib/vccio5-key.sh (Odoo #1900/#1944), host side, no root, no card.
# Drives the LIVE functions on scratch boot directories:
#   must-pass  3v3 on a #1900 image -> exactly one ga_vccio5=3v3 line; idempotent;
#              other lines kept; a stale line replaced; a missing file created;
#              1v8 writes an explicit line on ANY image (old or new)
#   must-flag  3v3 on a pre-#1900 image; no mode / a wrong mode (NO default);
#              --flash without --vccio5 (vcc_mode_verdict)
# and checks that verify-sd.sh refuses BEFORE its first dd and calls the seed
# set -e safe. FAILS if the library or its functions cannot be found (never skips).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../../../scripts/lib/vccio5-key.sh"
VSD="$HERE/../../../scripts/verify-sd.sh"
[ -r "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }
[ -r "$VSD" ] || { echo "FATAL: $VSD missing"; exit 1; }
. "$LIB"
type vcc_seed_dir >/dev/null 2>&1 || { echo "FATAL: vcc_seed_dir not defined by $LIB"; exit 1; }
type vcc_mode_verdict >/dev/null 2>&1 || { echo "FATAL: vcc_mode_verdict not defined by $LIB"; exit 1; }

T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
fails=0; n=0
ok()  { n=$((n+1)); echo "  ok    $*"; }
bad() { n=$((n+1)); fails=$((fails+1)); echo "  FAIL  $*"; }
cfg() { tr -d '\r' < "$1/haos-config.txt" 2>/dev/null; }
cnt() { cfg "$1" | grep -cx "ga_vccio5=$2"; }

# ── 3v3 ──
mkdir "$T/a"; : > "$T/a/$VCC_VARIANT"; : > "$T/a/haos-config.txt"
vcc_seed_dir "$T/a" 3v3 >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cnt "$T/a" 3v3)" = 1 ] && ok "3v3 on a #1900 image, empty haos-config.txt -> one key line" || bad "seed #1900 image (rc=$rc, lines=$(cnt "$T/a" 3v3))"
vcc_seed_dir "$T/a" 3v3 >/dev/null
[ "$(cnt "$T/a" 3v3)" = 1 ] && ok "idempotent: second run keeps exactly one line" || bad "second run left $(cnt "$T/a" 3v3) lines"

mkdir "$T/b"; : > "$T/b/$VCC_VARIANT"; printf 'overlays=foo\r\nga_vccio5=1v8\r\n' > "$T/b/haos-config.txt"
vcc_seed_dir "$T/b" 3v3 >/dev/null
[ "$(cfg "$T/b")" = "$(printf 'overlays=foo\nga_vccio5=3v3')" ] && ok "other lines kept, stale ga_vccio5=1v8 replaced" || bad "content: $(cat "$T/b/haos-config.txt")"

mkdir "$T/c"; : > "$T/c/$VCC_VARIANT"
vcc_seed_dir "$T/c" 3v3 >/dev/null; [ "$(cnt "$T/c" 3v3)" = 1 ] && ok "missing haos-config.txt is created with the key" || bad "missing file case"

mkdir "$T/d"; printf 'x=1\n' > "$T/d/haos-config.txt"
out=$(vcc_seed_dir "$T/d" 3v3); rc=$?
[ "$rc" = 1 ] && [ "$(cfg "$T/d")" = "x=1" ] && ok "3v3 on a pre-#1900 image REFUSED, card untouched" || bad "pre-#1900 refusal (rc=$rc, cfg=$(cfg "$T/d"))"
case "$out" in *LEGACY*) ok "the refusal names the legacy 1.8 V setting" ;; *) bad "refusal text: $out" ;; esac

# ── 1v8: explicit, on any image ──
vcc_seed_dir "$T/d" 1v8 >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cfg "$T/d")" = "$(printf 'x=1\nga_vccio5=1v8')" ] && ok "1v8 on a pre-#1900 image (jump test): explicit line written" || bad "1v8 on old image (rc=$rc, cfg=$(cfg "$T/d"))"
mkdir "$T/e"; : > "$T/e/$VCC_VARIANT"; printf 'ga_vccio5=3v3\n' > "$T/e/haos-config.txt"
vcc_seed_dir "$T/e" 1v8 >/dev/null
[ "$(cfg "$T/e")" = "ga_vccio5=1v8" ] && ok "1v8 replaces a 3v3 line, never keeps both" || bad "1v8 over 3v3: $(cfg "$T/e")"

# ── NO default: no mode / a wrong mode writes nothing ──
for m in "" 3.3 3V3 default; do
  mkdir -p "$T/f"; : > "$T/f/$VCC_VARIANT"; printf 'x=1\n' > "$T/f/haos-config.txt"
  vcc_seed_dir "$T/f" "$m" >/dev/null; rc=$?
  [ "$rc" = 1 ] && [ "$(cfg "$T/f")" = "x=1" ] && ok "mode '${m:-<none>}' refused, card untouched" || bad "mode '${m:-<none>}' (rc=$rc, cfg=$(cfg "$T/f"))"
done

vcc_seed_dir "$T/nope" 3v3 >/dev/null; rc=$?
[ "$rc" = 1 ] && ok "a missing boot dir fails" || bad "missing dir rc=$rc"

# ── vcc_mode_verdict: the argument check verify-sd.sh runs before anything else ──
[ -z "$(vcc_mode_verdict true 3v3)" ] && [ -z "$(vcc_mode_verdict true 1v8)" ] && ok "--flash with 3v3 / 1v8 passes" || bad "--flash with a valid mode refused"
case "$(vcc_mode_verdict true "")" in *"--vccio5 3v3|1v8 is required"*) ok "--flash without --vccio5 refused (no default)" ;; *) bad "--flash without --vccio5 not refused" ;; esac
case "$(vcc_mode_verdict true 3.3)" in *"is not 3v3|1v8"*) ok "--flash with a wrong value refused" ;; *) bad "wrong value not refused" ;; esac
[ -z "$(vcc_mode_verdict false "")" ] && ok "no --flash (--sha/--diff): no --vccio5 needed" || bad "a non-flash run was refused"

# ── verify-sd.sh wiring (it re-execs under sudo, so CI checks its structure) ──
vline=$(grep -n 'vcc_mode_verdict "$DO_FLASH" "$VCCIO5"' "$VSD" | head -1 | cut -d: -f1)
eline=$(grep -n '\[\[ -z "$_vcc_refusal" \]\] || {.*exit 1; }' "$VSD" | head -1 | cut -d: -f1)
dline=$(grep -nE '(^|[^a-z_])dd (if|of)=' "$VSD" | head -1 | cut -d: -f1)
if [ -n "$vline" ] && [ -n "$eline" ] && [ -n "$dline" ] && [ "$vline" -lt "$eline" ] && [ "$eline" -lt "$dline" ]; then
  ok "verify-sd.sh checks --vccio5 (line $vline) and exits (line $eline) before its first dd (line $dline)"
else bad "verify-sd.sh: --vccio5 check missing or not before the first dd (verdict=$vline exit=$eline dd=$dline)"; fi
grep -q 'vcc_seed_dir "$_vcc_mnt" "$VCCIO5"' "$VSD" && ok "verify-sd.sh seeds the CHOSEN mode" || bad "verify-sd.sh does not pass \$VCCIO5 to vcc_seed_dir"
grep -q 'allow-pre-1900' "$VSD" && bad "verify-sd.sh still knows the retired --allow-pre-1900-image" || ok "--allow-pre-1900-image is retired"

# verify-sd.sh runs under set -euo pipefail: a plain `x="$(vcc_seed_dir ..)"; rc=$?`
# would abort the script SILENTLY on a refused image (measured 2026-11-11). The
# call must capture the rc with `|| _vcc_rc=$?`.
grep -q '_vcc_out="$(vcc_seed_dir .*)" || _vcc_rc=$?' "$VSD" \
  && ok "verify-sd.sh captures the rc set -e safe (|| _vcc_rc=\$?)" || bad "verify-sd.sh calls vcc_seed_dir without '|| _vcc_rc=\$?' (set -e would abort silently)"

echo "vccio5_key: $((n-fails))/$n ok"
[ "$fails" = 0 ]
