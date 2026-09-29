#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the GA release floor for OS updates, both ways
# =============================================================================
# Drives the LIVE files, never a copy:
#   buildroot-external/rootfs-overlay/usr/lib/rauc/ga-release-floor   (handler)
#   buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install-older  (override)
#   buildroot-external/ota/manifest.raucm.gtpl + system.conf.gtpl     (templates,
#       rendered with the same tempio release the image builds with)
#   buildroot-external/scripts/rauc.sh ga_bundle_release()            (the value)
#   tests/ga_tests/run_build_tests.sh RFLOOR-01/02                    (build gate)
#   buildroot-external/rootfs-overlay/usr/sbin/ga-rauc-install        (label)
#
# Part A — handler verdicts against fixture manifests, running BOSv1.4.0-rc1
#          (and a few other running releases for the order edge cases).
# Part B — the operator override: honoured only as the documented path writes
#          it, ignored in every other shape.
# Part C — the build gate over fixture build outputs: a bundle without the
#          release, with the wrong release, a system.conf without the handler,
#          a missing handler must go red; a correct output must go green.
# Part D — ga-rauc-install's release label: BOSvX.Y.Z[-rcN] or nothing (the
#          prod slot); anything else refused before a download starts.
#
# Offline except for fetching the pinned tempio binary when it is not on PATH.
# Parts B2/B3 need root (sudo -n): skipped locally without it, FAILED in CI.
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OVL="$ROOT/buildroot-external/rootfs-overlay"
HANDLER="$OVL/usr/lib/rauc/ga-release-floor"
OVERRIDE="$OVL/usr/sbin/ga-rauc-install-older"
MF_TPL="$ROOT/buildroot-external/ota/manifest.raucm.gtpl"
SC_TPL="$ROOT/buildroot-external/ota/system.conf.gtpl"
RAUC_SH="$ROOT/buildroot-external/scripts/rauc.sh"
RUNNER="$ROOT/tests/ga_tests/run_build_tests.sh"
INSTALL="$OVL/usr/sbin/ga-rauc-install"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; YEL=''; NC=''; }
fails=0; ran=0; skipped=0; seq=0
ok()   { ran=$((ran+1)); printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
bad()  { ran=$((ran+1)); fails=$((fails+1)); printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; }
skip() { skipped=$((skipped+1)); printf '  %sSKIP%s  %s\n' "$YEL" "$NC" "$*"; }

for f in "$HANDLER" "$OVERRIDE" "$INSTALL" "$MF_TPL" "$SC_TPL" "$RAUC_SH" "$RUNNER"; do
  [[ -r "$f" ]] || { echo "FATAL: $f missing — nothing to test"; exit 1; }
done
[[ -x "$HANDLER" ]]  || { echo "FATAL: $HANDLER is not executable in the tree"; exit 1; }
[[ -x "$OVERRIDE" ]] || { echo "FATAL: $OVERRIDE is not executable in the tree"; exit 1; }

W="$(mktemp -d)"
cleanup() { sudo -n rm -rf "$W" 2>/dev/null || rm -rf "$W"; }
trap cleanup EXIT

# --- tempio (the renderer the build uses) ------------------------------------
# shellcheck source=tempio.sh
. "$HERE/tempio.sh"; tempio_fetch "$W"
_mk_ver="$(sed -n 's/^TEMPIO_VERSION = //p' "$ROOT/buildroot-external/package/tempio/tempio.mk")"
[[ "$_mk_ver" == "$TEMPIO_VERSION" ]] && ok "tempio ${TEMPIO_VERSION} = the version the image builds with" \
  || bad "tempio pin ${TEMPIO_VERSION} != tempio.mk '${_mk_ver}' — templates rendered by another renderer"

# --- fixtures ------------------------------------------------------------------
# mf <name> <release|-> [extra text]  -> dir holding manifest.raucm
# The manifest is the LIVE template rendered as hdd-image.sh renders it.
mf() {
  local d="$W/mf-$1"; mkdir -p "$d"
  if [[ "$2" == "-" ]]; then
    ota_compatible=haos-ihost ota_version=16.3.1.9 BOOTLOADER=uboot BOOT_SPL=true \
      render "$MF_TPL" > "$d/manifest.raucm"
  else
    ota_compatible=haos-ihost ota_version=16.3.1.9 ota_ga_release="$2" BOOTLOADER=uboot BOOT_SPL=true \
      render "$MF_TPL" > "$d/manifest.raucm"
  fi
  [[ -n "${3:-}" ]] && printf '%s\n' "$3" >> "$d/manifest.raucm"
  printf '%s' "$d"
}
# sysroot <name> <running-release|->  -> prefix dir with etc/ga-release
sysroot() {
  local d="$W/root-$1"; mkdir -p "$d/etc" "$d/run"
  [[ "$2" != "-" ]] && printf '%s\n' "$2" > "$d/etc/ga-release"
  printf '%s' "$d"
}
# verdict <sysroot> <bundle-dir>  -> allow|refuse ; handler output in $W/h.out
verdict() {
  if RAUC_BUNDLE_MOUNT_POINT="$2" "${HSH[@]}" "$HANDLER" "$1" >"$W/h.out" 2>&1; then echo allow; else echo refuse; fi
}
expect() {  # <want> <running> <bundle-release|-> <desc> [<why-regex>] [<extra manifest text>]
  local r b got; seq=$((seq+1)); r="$(sysroot "c$seq" "$2")"; b="$(mf "c$seq" "$3" "${6:-}")"
  got="$(verdict "$r" "$b")"
  if [[ "$got" != "$1" ]]; then bad "$4 — got $got, want $1: $(tail -1 "$W/h.out")"; return; fi
  if [[ -n "${5:-}" ]] && ! grep -Eq -- "$5" "$W/h.out"; then
    bad "$4 — $got for the WRONG reason: $(tail -1 "$W/h.out")"; return
  fi
  ok "$4 → $got"
}

run_part_a() {
  echo "--- A: handler verdicts (shell: ${HSH[*]}) ---"
  local R=BOSv1.4.0-rc1
  # The seven the work package names.
  expect refuse "$R" BOSv1.3.0-rc55 "running $R, bundle BOSv1.3.0-rc55"   'REFUSED: bundle BOSv1.3.0-rc55 is older'
  expect refuse "$R" -              "running $R, bundle without [meta.ga]" 'REFUSED: bundle carries no GA release'
  expect allow  "$R" BOSv1.4.0-rc1  "running $R, bundle BOSv1.4.0-rc1 (reinstall)" 'allowed'
  expect allow  "$R" BOSv1.4.0-rc2  "running $R, bundle BOSv1.4.0-rc2"     'allowed'
  expect allow  "$R" BOSv1.4.0      "running $R, bundle BOSv1.4.0 (final after its rc — sort -V gets this wrong)" 'allowed'
  expect refuse "$R" BOSv1.3.9      "running $R, bundle BOSv1.3.9"         'is older'
  # Order edge cases.
  expect refuse BOSv1.4.0 BOSv1.4.0-rc9  "running BOSv1.4.0, bundle BOSv1.4.0-rc9 (rc after its final is older)" 'is older'
  expect refuse "$R" BOSv1.4.0-dev7      "running $R, bundle BOSv1.4.0-dev7 (dev < rc)" 'is older'
  expect allow  BOSv1.9.0 BOSv1.10.0     "running BOSv1.9.0, bundle BOSv1.10.0 (numeric, not lexical)" 'allowed'
  expect refuse BOSv1.10.0 BOSv1.9.9     "running BOSv1.10.0, bundle BOSv1.9.9"  'is older'
  expect allow  BOSv1.4.0-rc9 BOSv1.4.0-rc10 "running rc9, bundle rc10 (numeric rc)" 'allowed'
  expect refuse BOSv1.4.0-rc10 BOSv1.4.0-rc9 "running rc10, bundle rc9"   'is older'
  expect allow  BOSv1.4.0-rc08 BOSv1.4.0-rc9 "running rc08, bundle rc9 (leading zero is not octal)" 'allowed'
  # Malformed / missing inputs fail closed.
  expect refuse "$R" BOSv1.4       "bundle release malformed (BOSv1.4)" 'malformed'
  expect refuse "$R" 'BOSv1.4.0-rc1;x' "bundle release with trailing junk" 'malformed'
  expect refuse -   BOSv1.4.0-rc2  "running release missing (/etc/ga-release absent)" 'missing or malformed'
  expect refuse garbage BOSv1.4.0-rc2 "running release malformed" 'missing or malformed'
  expect refuse "$R" - "release= only in another meta group" 'no GA release' $'[meta.other]\nrelease=BOSv9.9.9'
  expect refuse "$R" BOSv1.4.0-rc2 "two [meta.ga] release values" 'ambiguous' $'[meta.ga]\nrelease=BOSv9.9.9'
  # No bundle mounted at all.
  local r; r="$(sysroot nomount "$R")"
  if RAUC_BUNDLE_MOUNT_POINT="" "${HSH[@]}" "$HANDLER" "$r" >"$W/h.out" 2>&1; then
    bad "no RAUC_BUNDLE_MOUNT_POINT → allowed"
  else ok "no RAUC_BUNDLE_MOUNT_POINT → refuse"; fi
}

echo "=== GA release floor self-test ==="
HSH=(sh); run_part_a
# The device runs busybox ash with busybox applets. Prove the handler there too
# when busybox is available (CI installs it).
if command -v busybox >/dev/null; then
  BB="$W/bb"; mkdir -p "$BB"
  for a in sh stat date head tr id rm grep sed cat; do ln -sf "$(command -v busybox)" "$BB/$a"; done
  HSH=(env "PATH=$BB" "$BB/sh"); run_part_a
  HSH=(sh)
elif [[ -n "${CI:-}" ]]; then bad "busybox not available in CI — the device shell is unproven"
else skip "busybox not installed — handler not run under the device shell"; fi

# --- B: override ---------------------------------------------------------------
echo "--- B: operator override ---"
# token <sysroot> <content> [mode]  — as the documented tool writes it
token() { mkdir -p "$1/run/ga-rauc-floor"; chmod 700 "$1/run/ga-rauc-floor"
          printf '%s\n' "$2" > "$1/run/ga-rauc-floor/allow-older"; }
R=BOSv1.4.0-rc1
r="$(sysroot b1 "$R")"; b="$(mf b1 BOSv1.3.0-rc55)"; token "$r" BOSv1.3.0-rc55
[[ "$(verdict "$r" "$b")" == allow ]] && grep -q 'operator override' "$W/h.out" \
  && ok "token for exactly this release → allow (logged as override)" || bad "valid token not honoured: $(tail -1 "$W/h.out")"
[[ ! -e "$r/run/ga-rauc-floor/allow-older" ]] && ok "token consumed after use" || bad "token still present after use"
[[ "$(verdict "$r" "$b")" == refuse ]] && ok "second install without a new token → refuse" || bad "token was reusable"

r="$(sysroot b2 "$R")"; b="$(mf b2 -)"; token "$r" none
[[ "$(verdict "$r" "$b")" == allow ]] && ok "token 'none' → pre-floor bundle allowed" || bad "token 'none' not honoured: $(tail -1 "$W/h.out")"

r="$(sysroot b3 "$R")"; b="$(mf b3 BOSv1.3.0-rc55)"; token "$r" BOSv1.3.0-rc54
[[ "$(verdict "$r" "$b")" == refuse ]] && grep -q "token names 'BOSv1.3.0-rc54'" "$W/h.out" \
  && ok "token for another release → refuse" || bad "token for another release honoured: $(tail -1 "$W/h.out")"

r="$(sysroot b4 "$R")"; b="$(mf b4 BOSv1.3.0-rc55)"; token "$r" BOSv1.3.0-rc55
touch -d '-20 minutes' "$r/run/ga-rauc-floor/allow-older"
[[ "$(verdict "$r" "$b")" == refuse ]] && grep -q 'old (limit' "$W/h.out" \
  && ok "token older than 15 min → refuse" || bad "stale token honoured: $(tail -1 "$W/h.out")"

r="$(sysroot b5 "$R")"; b="$(mf b5 BOSv1.3.0-rc55)"; mkdir -p "$r/run/ga-rauc-floor"; chmod 700 "$r/run/ga-rauc-floor"
printf 'BOSv1.3.0-rc55\n' > "$W/elsewhere"; ln -s "$W/elsewhere" "$r/run/ga-rauc-floor/allow-older"
[[ "$(verdict "$r" "$b")" == refuse ]] && grep -q 'not a regular file' "$W/h.out" \
  && ok "token as a symlink → refuse" || bad "symlinked token honoured: $(tail -1 "$W/h.out")"

r="$(sysroot b6 "$R")"; b="$(mf b6 BOSv1.3.0-rc55)"; token "$r" BOSv1.3.0-rc55; chmod 755 "$r/run/ga-rauc-floor"
[[ "$(verdict "$r" "$b")" == refuse ]] && grep -q 'mode 700' "$W/h.out" \
  && ok "token dir not 0700 → refuse" || bad "token in a group/world-readable dir honoured: $(tail -1 "$W/h.out")"

r="$(sysroot b7 "$R")"; b="$(mf b7 BOSv1.3.0-rc55)"; token "$r" BOSv1.3.0-rc55
ln "$r/run/ga-rauc-floor/allow-older" "$W/hardlink"
[[ "$(verdict "$r" "$b")" == refuse ]] && grep -q 'one link' "$W/h.out" \
  && ok "token with a second hard link → refuse" || bad "hard-linked token honoured: $(tail -1 "$W/h.out")"

# The /share bridge and the environment are not override channels.
r="$(sysroot b8 "$R")"; b="$(mf b8 BOSv1.3.0-rc55)"
mkdir -p "$r/mnt/data/supervisor/share/ga-rauc-floor"; printf 'BOSv1.3.0-rc55\n' > "$r/mnt/data/supervisor/share/ga-rauc-floor/allow-older"
printf 'BOSv1.3.0-rc55\n' > "$r/mnt/data/supervisor/share/ga-rauc-install-older"
[[ "$(verdict "$r" "$b")" == refuse ]] && ok "a token planted under /share → refuse" || bad "/share token honoured"
if RAUC_BUNDLE_MOUNT_POINT="$b" GA_RAUC_FLOOR_ROOT="$r" GA_ALLOW_OLDER=1 RAUC_ALLOW_OLDER=1 FORCE=1 \
     sh "$HANDLER" "$r" >"$W/h.out" 2>&1; then bad "environment variables lifted the floor"
else ok "environment variables do not lift the floor"; fi
# The handler must not read /share or an environment override at all.
if grep -nE '/share|/mnt/data|GA_RAUC_FLOOR_ROOT|ALLOW_OLDER' "$HANDLER" | grep -v '^[0-9]*:#' | grep -q .; then
  bad "handler code references /share, /mnt/data or an override variable"
else ok "handler code reads neither /share nor an override variable"; fi

# B2/B3: the documented tool end to end — root + a terminal, stubbed `rauc`
# whose install runs the LIVE handler the way rauc.service would.
have_root=false; sudo -n true 2>/dev/null && have_root=true
if $have_root && command -v script >/dev/null; then
  STUB="$W/stub"; mkdir -p "$STUB"
  cat > "$STUB/rauc" <<EOF
#!/bin/sh
case "\$1" in
  info) printf "RAUC_MF_COMPATIBLE=haos-ihost\nRAUC_MF_VERSION=16.3.1.9\n"
        r="\$(sed -n 's/^release=//p' "\$3/manifest.raucm")"; [ -n "\$r" ] && echo "RAUC_META_GA_RELEASE=\$r"; exit 0 ;;
  install) RAUC_BUNDLE_MOUNT_POINT="\$2" exec sh "$HANDLER" "\$GA_RAUC_FLOOR_ROOT" ;;
esac
exit 9
EOF
  chmod +x "$STUB/rauc"
  run_tool() {  # <sysroot> <bundle-dir> <typed answer> ; prints rc, output in $W/t.out
    sudo -n env "PATH=$STUB:$PATH" "GA_RAUC_FLOOR_ROOT=$1" \
      script -qec "sh '$OVERRIDE' '$2'" /dev/null >"$W/t.out" 2>&1 <<<"$3"
    echo $?
  }
  r="$(sysroot t1 "$R")"; b="$(mf t1 BOSv1.3.0-rc55)"
  rc="$(run_tool "$r" "$b" BOSv1.3.0-rc55)"
  if [[ "$rc" == 0 ]] && grep -q 'installing anyway on an operator override' "$W/t.out" \
     && ! sudo -n test -e "$r/run/ga-rauc-floor/allow-older"; then
    ok "ga-rauc-install-older as root at a terminal → handler allows, token gone"
  else bad "documented override path did not install (rc=$rc): $(tr -d '\r' < "$W/t.out" | tail -3 | tr '\n' ' ')"; fi
  if [[ "$(sudo -n stat -c '%a %u' "$r/run/ga-rauc-floor")" == "700 0" ]]; then ok "tool creates the token dir 0700 root"
  else bad "token dir is $(sudo -n stat -c '%a %u' "$r/run/ga-rauc-floor")"; fi

  r="$(sysroot t2 "$R")"; b="$(mf t2 BOSv1.3.0-rc55)"
  rc="$(run_tool "$r" "$b" BOSv1.3.0-rc54)"
  [[ "$rc" != 0 ]] && grep -q 'not confirmed' "$W/t.out" \
    && ok "operator types the wrong release → nothing installed" || bad "mistyped confirmation installed (rc=$rc)"

  r="$(sysroot t3 "$R")"; b="$(mf t3 BOSv1.3.0-rc55)"
  if sudo -n env "PATH=$STUB:$PATH" "GA_RAUC_FLOOR_ROOT=$r" sh "$OVERRIDE" "$b" </dev/null >"$W/t.out" 2>&1; then
    bad "tool ran without a terminal"
  else grep -q 'needs an operator at a terminal' "$W/t.out" && ok "no terminal (automation) → refused" \
         || bad "no-terminal refusal for the wrong reason: $(tail -1 "$W/t.out")"; fi

  # A token owned by someone else (e.g. written by a non-root process).
  r="$(sysroot t4 "$R")"; b="$(mf t4 BOSv1.3.0-rc55)"; token "$r" BOSv1.3.0-rc55
  sudo -n chown 0:0 "$r/run/ga-rauc-floor/allow-older"
  [[ "$(verdict "$r" "$b")" == refuse ]] && grep -q 'owned by uid' "$W/h.out" \
    && ok "token owned by another uid → refuse" || bad "foreign-owned token honoured: $(tail -1 "$W/h.out")"
else
  if [[ -n "${CI:-}" ]]; then bad "no passwordless sudo/script in CI — the documented override path is unproven"
  else skip "no passwordless sudo — documented override tool (B2/B3) not run"; fi
fi
if sh "$OVERRIDE" /nonexistent </dev/null >"$W/t.out" 2>&1; then bad "tool ran as non-root"
elif [[ "$(id -u)" != 0 ]]; then grep -q 'must run as root' "$W/t.out" && ok "tool as non-root → refused" || bad "non-root refusal wrong: $(tail -1 "$W/t.out")"; fi

# --- C: build gate -------------------------------------------------------------
echo "--- C: build gate RFLOOR-01/02 (live run_build_tests.sh over fixture outputs) ---"
MKSQ="$(command -v mksquashfs || true)"
if [[ -z "$MKSQ" ]]; then bad "mksquashfs missing — cannot make fixture bundles"; else
# out <name> <target-release> <manifest-release|-> <handler: yes|noexec|no> <sysconf: live|nohandler>
out() {
  local d="$W/out-$1" t; t="$d/target"; mkdir -p "$t/etc/rauc" "$t/usr/lib/rauc" "$d/images" "$d/c"
  printf '%s\n' "$2" > "$t/etc/ga-release"
  ota_compatible=haos-ihost BOOTLOADER=uboot BOOT_SPL=true render "$SC_TPL" > "$t/etc/rauc/system.conf"
  [[ "$5" == nohandler ]] && sed -i '/^pre-install=/d' "$t/etc/rauc/system.conf"
  case "$4" in
    yes)    install -m 0755 "$HANDLER" "$t/usr/lib/rauc/ga-release-floor" ;;
    noexec) install -m 0644 "$HANDLER" "$t/usr/lib/rauc/ga-release-floor" ;;
  esac
  # The release value exactly as the build computes it: the live rauc.sh
  # function over this target tree, unless the case forces another value.
  local rel="$3"
  if [[ "$rel" == "=" ]]; then rel="$(TARGET_DIR="$t" bash -c ". '$RAUC_SH'; ga_bundle_release")" || rel="-"; fi
  cp "$(mf "o$1" "$rel")/manifest.raucm" "$d/c/manifest.raucm"
  : > "$d/images/rootfs.erofs"; sleep 0.01
  "$MKSQ" "$d/c" "$d/images/haos_ihost-16.3.1.9.raucb" -quiet -noappend -no-progress >/dev/null 2>&1
  printf '%s' "$d"
}
gate() {  # <want PASS|FAIL> <id> <out-dir> <desc> [<why-regex>]
  local line; line="$(bash "$RUNNER" "$3" 2>&1 | grep -E "  (PASS|FAIL|SKIP)  $2:" | head -1)"
  local got=ABSENT; case "$line" in *"  PASS  "*) got=PASS ;; *"  FAIL  "*) got=FAIL ;; *"  SKIP  "*) got=SKIP ;; esac
  if [[ "$got" != "$1" ]]; then bad "$2 $4 — got $got, want $1: ${line:-<no $2 line>}"; return; fi
  if [[ -n "${5:-}" ]] && ! grep -Eq -- "$5" <<<"$line"; then bad "$2 $4 — $got for the WRONG reason: $line"; return; fi
  ok "$2 $got — $4"
}
o="$(out good BOSv1.4.0-rc2 = yes live)"
gate PASS RFLOOR-01 "$o" "bundle manifest carries the image's own release"
gate PASS RFLOOR-02 "$o" "system.conf declares the handler, handler shipped executable"
o="$(out nometa BOSv1.4.0-rc2 - yes live)"
gate FAIL RFLOOR-01 "$o" "bundle manifest without [meta.ga]" 'no \[meta.ga\] release'
o="$(out wrongrel BOSv1.4.0-rc2 BOSv1.4.0-rc1 yes live)"
gate FAIL RFLOOR-01 "$o" "bundle release differs from /etc/ga-release" 'differs'
o="$(out nohandler BOSv1.4.0-rc2 = yes nohandler)"
gate FAIL RFLOOR-02 "$o" "system.conf without pre-install" 'pre-install'
o="$(out nofile BOSv1.4.0-rc2 = no live)"
gate FAIL RFLOOR-02 "$o" "handler missing from the image" 'not executable|missing'
o="$(out noexec BOSv1.4.0-rc2 = noexec live)"
gate FAIL RFLOOR-02 "$o" "handler not executable" 'not executable'
o="$(out nobundle BOSv1.4.0-rc2 = yes live)"; rm -f "$o"/images/*.raucb
gate FAIL RFLOOR-01 "$o" "build output with a rootfs but no bundle — zero bundles is a failure" 'no bundle'
fi

# --- D: ga-rauc-install label ------------------------------------------------
echo "--- D: ga-rauc-install ga_release label ---"
# Stubs for the environment only: mkdir (the staging dir is /mnt/data/tmp) and
# curl (records the URL, then fails the download). The label check and the URL
# construction under test run unchanged.
DS="$W/dstub"; mkdir -p "$DS"
printf '#!/bin/sh\nexit 0\n' > "$DS/mkdir"
printf '#!/bin/sh\nfor a; do case "$a" in https://*) echo "$a" >> "%s/curl.log";; esac; done\nexit 22\n' "$W" > "$DS/curl"
chmod +x "$DS/mkdir" "$DS/curl"
label() {  # <want: ok|refuse> <label> <desc> [<expected first URL>]
  rm -f "$W/curl.log"
  local rc=0; PATH="$DS:$PATH" sh "$INSTALL" 16.3.1.9 "$2" >"$W/d.out" 2>&1 || rc=$?
  if [[ "$1" == refuse ]]; then
    if [[ "$rc" == 2 ]] && grep -q 'refusing ga_release' "$W/d.out" && [[ ! -s "$W/curl.log" ]]; then ok "label $3 → refused, nothing downloaded"
    else bad "label $3 → rc=$rc, downloads=$(cat "$W/curl.log" 2>/dev/null | tr '\n' ' '): $(tail -1 "$W/d.out")"; fi
  else
    local first; first="$(head -1 "$W/curl.log" 2>/dev/null)"
    if [[ "$rc" == 3 && "$first" == "$4" ]]; then ok "label $3 → fetches $4"
    else bad "label $3 → rc=$rc, first URL '${first}', want '$4': $(tail -1 "$W/d.out")"; fi
  fi
}
B=https://ota.greenautarky.com/releases/16.3.1.9
label ok     ""             "(none: prod flat slot)" "$B/haos_ihost-16.3.1.9.raucb"
label ok     BOSv1.4.0-rc2  BOSv1.4.0-rc2            "$B/BOSv1.4.0-rc2/haos_ihost-16.3.1.9.raucb"
label ok     BOSv1.4.0      BOSv1.4.0                "$B/BOSv1.4.0/haos_ihost-16.3.1.9.raucb"
label refuse BOSv1.4.0-dev1 BOSv1.4.0-dev1
label refuse BOSv1.4.0-rc2x BOSv1.4.0-rc2x
label refuse BOSv1.4-rc1    BOSv1.4-rc1
label refuse bosv1.4.0-rc1  "bosv1.4.0-rc1 (case)"
label refuse ../../x        "../../x"
label refuse "BOSv1.4.0-rc1/../BOSv1.2.19-rc1" "with a path"
label refuse $'BOSv1.4.0-rc1\nBOSv1.2.19-rc1' "two lines"
label refuse x              x

echo
echo "=== ${ran} checks: $((ran - fails)) ok, ${fails} failed, ${skipped} skipped ==="
(( ran >= 55 )) || { echo "FAIL: only ${ran} checks ran — the self-test inspected too little"; exit 1; }
(( fails == 0 ))
