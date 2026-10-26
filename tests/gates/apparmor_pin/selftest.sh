#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the Supervisor AppArmor profile is baked, pinned, and loaded
# from the baked copy (Odoo #1281, AA1 + AA2)
# =============================================================================
# Drives the LIVE pieces, never copies of their rules:
#   buildroot-external/scripts/verify-apparmor-profile.sh   the one pin rule
#   buildroot-external/scripts/post-build.d/89-apparmor-profile.sh
#   tests/ga_tests/run_build_tests.sh AA-PIN-01..03          the image gate
#   haos files as the build sees them (scripts/apply-haos-patches.sh --cat /
#   --export): create-data-partition.sh, hassio.mk, haos-apparmor
#
#   must-fail: a profile whose bytes differ from the pin (one rule added), no
#              profile, no pin file, two pins, a malformed pin line -> the
#              verifier refuses with ITS reason; the hook refuses and leaves no
#              profile in the image (also not a stale one); AA-PIN-01 is red on
#              an image with a changed profile, AA-PIN-02 on a haos-apparmor
#              that downloads or loads the data copy, AA-PIN-03 without the
#              Supervisor drop-in.
#   must-pass: the repo's profile against the repo's pin; the hook installs it
#              (0644, same bytes); AA-PIN-01..03 green on that image tree.
#   static:    the data partition pre-seed calls the verifier and downloads
#              nothing; hassio.mk hands it the GA layer; the full pin appears
#              in exactly one tracked file.
# Zero cases run = FAIL. Offline, no build, a few seconds. Needs haos/ checked
# out (CI gate-selftest does it).
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
VERIFY="$ROOT/buildroot-external/scripts/verify-apparmor-profile.sh"
HOOK="$ROOT/buildroot-external/scripts/post-build.d/89-apparmor-profile.sh"
PROFILE="$ROOT/buildroot-external/apparmor/hassio-supervisor"
PIN="$ROOT/buildroot-external/apparmor/hassio-supervisor.sha256"
RUNNER="$ROOT/tests/ga_tests/run_build_tests.sh"
PATCHES="$ROOT/scripts/apply-haos-patches.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }
for f in "$VERIFY" "$HOOK" "$PROFILE" "$PIN" "$RUNNER" "$PATCHES"; do
  [[ -r "$f" ]] || { echo "FATAL: $f missing"; exit 1; }
done
[[ -x "$HOOK" ]] || { echo "FATAL: $HOOK is not executable (post-build.sh refuses it)"; exit 1; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# expect <refuse|accept> <desc> <why-regex|-> -- <cmd...>
# A refusal counts only for the RIGHT reason: <why> must be in the output.
expect() {
  local want="$1" desc="$2" why="$3"; shift 4
  ran=$((ran + 1)); local rc=0; "$@" >"$W/out" 2>&1 || rc=$?
  if [[ "$want" == refuse ]]; then
    if (( rc == 0 )); then bad "$desc — ACCEPTED (rc=0)"; return; fi
    grep -qE -- "$why" "$W/out" || { bad "$desc — refused, but not for '$why': $(head -1 "$W/out")"; return; }
  else
    (( rc == 0 )) || { bad "$desc — refused (rc=$rc): $(head -1 "$W/out")"; return; }
  fi
  ok "$desc"
}
verify_with() { GA_APPARMOR_PIN_FILE="$1" "$VERIFY" "$2"; }

# --- fixtures, generated from the LIVE profile --------------------------------
TAMPERED="$W/tampered"; sed 's/^  capability chown,$/  capability chown,\n  capability sys_admin,/' "$PROFILE" > "$TAMPERED"
cmp -s "$PROFILE" "$TAMPERED" && { echo "FATAL: tampered fixture equals the profile (sed did not apply)"; exit 1; }
TWO="$W/two.sha256"; { cat "$PIN"; grep -vE '^[[:space:]]*(#|$)' "$PIN"; } > "$TWO"
MALFORMED="$W/malformed.sha256"; grep -vE '^[[:space:]]*(#|$)' "$PIN" | tr 'a-f' 'A-F' > "$MALFORMED"

echo "── must-fail: the verifier refuses ──"
expect refuse "profile bytes differ from the pin (one rule added)" 'sha256 mismatch' -- verify_with "$PIN" "$TAMPERED"
expect refuse "profile missing"                                    'profile .* not found' -- verify_with "$PIN" "$W/nope"
expect refuse "pin file missing"                                   'pin file .* not found' -- verify_with "$W/nope.sha256" "$PROFILE"
expect refuse "two pin lines"                                      'exactly one pin line' -- verify_with "$TWO" "$PROFILE"
expect refuse "malformed pin line (upper-case hex)"                'is not' -- verify_with "$MALFORMED" "$PROFILE"

echo "── must-fail: the post-build hook refuses and leaves no profile ──"
T1="$W/img-bad/target"; mkdir -p "$T1/usr/share/ga-apparmor"; echo stale > "$T1/usr/share/ga-apparmor/hassio-supervisor"
expect refuse "hook: source profile differs from the pin" 'sha256 mismatch' -- env GA_APPARMOR_PROFILE_SRC="$TAMPERED" "$HOOK" "$T1"
ran=$((ran + 1)); [[ -e "$T1/usr/share/ga-apparmor/hassio-supervisor" ]] && bad "hook: refused, but a profile (stale) is left in the image" || ok "hook: refused, no profile left in the image (stale one removed)"
expect refuse "hook: no TARGET_DIR" 'TARGET_DIR' -- "$HOOK" "$W/does-not-exist"

echo "── must-pass ──"
expect accept "the repo profile matches the repo pin" - -- "$VERIFY" "$PROFILE"
T2="$W/img-good/target"; mkdir -p "$T2"
expect accept "hook installs the pinned profile" - -- "$HOOK" "$T2"
ran=$((ran + 1))
if cmp -s "$PROFILE" "$T2/usr/share/ga-apparmor/hassio-supervisor" && [[ "$(stat -c %a "$T2/usr/share/ga-apparmor/hassio-supervisor")" == 644 ]]; then
  ok "hook: image copy = source bytes, mode 0644"
else
  bad "hook: image copy missing, different, or not 0644"
fi

# --- the image gate, AA-PIN-01..03 --------------------------------------------
# Image tree = hook output + haos-apparmor as the build sees it + the drop-in.
"$PATCHES" --export "$W/haos" buildroot-external/rootfs-overlay/usr/libexec/haos-apparmor buildroot-external/rootfs-overlay/usr/lib/systemd/system/haos-supervisor.service >/dev/null 2>&1 \
  || { echo "FATAL: apply-haos-patches.sh --export failed (haos/ checked out?)"; exit 1; }
LIVE_AA="$W/haos/buildroot-external/rootfs-overlay/usr/libexec/haos-apparmor"
LIVE_SUP="$W/haos/buildroot-external/rootfs-overlay/usr/lib/systemd/system/haos-supervisor.service"
[[ -s "$LIVE_SUP" ]] || { echo "FATAL: upstream haos-supervisor.service not exported"; exit 1; }
mk_image() { # <name> -> OUT dir of a complete, good image tree
  local d="$W/gate-$1"; mkdir -p "$d/target/usr/libexec" "$d/target/usr/lib/systemd/system/haos-supervisor.service.d"
  cp -a "$T2/usr" "$d/target/" ; cp "$LIVE_AA" "$d/target/usr/libexec/haos-apparmor"
  cp "$LIVE_SUP" "$d/target/usr/lib/systemd/system/"; printf '%s' "$d"; }
verdict() { # <OUT> <id>
  local line; line="$(GA_SRC_ROOT="$ROOT" bash "$RUNNER" "$1" 2>&1 | grep -E "  (PASS|FAIL|SKIP)  $2:" | head -1)"
  case "$line" in *"  PASS  "*) echo PASS ;; *"  FAIL  "*) echo FAIL ;; *"  SKIP  "*) echo SKIP ;; *) echo ABSENT ;; esac
}
expect_gate() { ran=$((ran + 1)); local got; got="$(verdict "$2" "$3")"
  [[ "$got" == "$1" ]] && ok "$3 $1 — $4" || bad "$3 → got $got, want $1 — $4"; }

G="$(mk_image good)"
for id in AA-PIN-01 AA-PIN-02 AA-PIN-03; do expect_gate PASS "$G" "$id" "the image the hook + patch set produce"; done

B1="$(mk_image changed)"; cp "$TAMPERED" "$B1/target/usr/share/ga-apparmor/hassio-supervisor"
expect_gate FAIL "$B1" AA-PIN-01 "image profile differs from the pin"
B2="$(mk_image noprofile)"; rm -f "$B2/target/usr/share/ga-apparmor/hassio-supervisor"
expect_gate FAIL "$B2" AA-PIN-01 "image has no baked profile"
B3="$(mk_image download)"; printf 'curl -fSsL -o "${PROFILES_DIR}/hassio-supervisor" https://example.invalid/apparmor.txt\n' >> "$B3/target/usr/libexec/haos-apparmor"
expect_gate FAIL "$B3" AA-PIN-02 "haos-apparmor downloads a profile"
B4="$(mk_image datacopy)"; sed -i 's|-L "${CACHE_DIR}" "${BAKED_PROFILE}"; then|-L "${CACHE_DIR}" "${PROFILES_DIR}/hassio-supervisor"; then|' "$B4/target/usr/libexec/haos-apparmor"
cmp -s "$LIVE_AA" "$B4/target/usr/libexec/haos-apparmor" && { echo "FATAL: data-copy mutant did not apply"; exit 1; }
expect_gate FAIL "$B4" AA-PIN-02 "haos-apparmor loads the data copy instead of the baked one"
B5="$(mk_image harddep)"; printf '[Unit]\nRequires=haos-apparmor.service\n' > "$B5/target/usr/lib/systemd/system/haos-supervisor.service.d/x.conf"
expect_gate FAIL "$B5" AA-PIN-03 "a drop-in binds the Supervisor hard to haos-apparmor"
B6="$(mk_image nowants)"; sed -i 's/ haos-apparmor\.service//' "$B6/target/usr/lib/systemd/system/haos-supervisor.service"
expect_gate FAIL "$B6" AA-PIN-03 "the Supervisor unit no longer wants/orders after haos-apparmor"

echo "── static: the data partition pre-seed and the one pin ──"
CDP="$("$PATCHES" --cat buildroot-external/package/hassio/create-data-partition.sh 2>/dev/null)"
MK="$("$PATCHES" --cat buildroot-external/package/hassio/hassio.mk 2>/dev/null)"
ran=$((ran + 1)); [[ -n "$CDP" && -n "$MK" ]] && ok "create-data-partition.sh + hassio.mk read as the build sees them" || bad "could not read create-data-partition.sh / hassio.mk via apply-haos-patches.sh --cat"
ran=$((ran + 1)); grep -q 'verify-apparmor-profile.sh" "${ga_apparmor_profile}"' <<<"$CDP" && ok "pre-seed calls the verifier" || bad "pre-seed does not call verify-apparmor-profile.sh"
ran=$((ran + 1)); grep -qE 'curl|APPARMOR_URL' <<<"$CDP" && bad "pre-seed still downloads (curl / APPARMOR_URL)" || ok "pre-seed downloads nothing"
ran=$((ran + 1)); grep -q 'install -m 0644 "${ga_apparmor_profile}" "${data_dir}/supervisor/apparmor/hassio-supervisor"' <<<"$CDP" && ok "pre-seed installs the verified profile" || bad "pre-seed does not install the verified profile"
ran=$((ran + 1)); grep -q 'create-data-partition.sh .*"$(BR2_EXTERNAL_GA_HAOS_PATH)"$' <<<"$MK" && ok "hassio.mk passes the GA layer to the pre-seed" || bad "hassio.mk does not pass \$(BR2_EXTERNAL_GA_HAOS_PATH)"
# The real pre-seed, run up to its verification: a GA layer whose profile
# differs from the pin must stop it before data.ext4 is created. sudo, docker,
# mkfs.ext4 and truncate are stubbed to fail, so a pre-seed that did NOT stop
# could not touch this machine.
"$PATCHES" --export "$W/haos" buildroot-external/package/hassio/create-data-partition.sh >/dev/null 2>&1
CDP_SH="$W/haos/buildroot-external/package/hassio/create-data-partition.sh"
mkdir -p "$W/stub" "$W/galayer/apparmor" "$W/galayer/scripts" "$W/cdp-build" "$W/cdp-dst"
for b in sudo docker mkfs.ext4 truncate; do printf '#!/bin/sh\necho "STUB %s must not run" >&2; exit 1\n' "$b" > "$W/stub/$b"; chmod +x "$W/stub/$b"; done
cp "$PIN" "$W/galayer/apparmor/hassio-supervisor.sha256"; cp "$TAMPERED" "$W/galayer/apparmor/hassio-supervisor"
ln -s "$VERIFY" "$W/galayer/scripts/verify-apparmor-profile.sh"
expect refuse "pre-seed (create-data-partition.sh): GA profile differs from the pin" 'sha256 mismatch' -- \
  env PATH="$W/stub:$PATH" bash "$CDP_SH" "$W/cdp-build" "$W/cdp-dst" stable 0 1M "$W/galayer"
ran=$((ran + 1)); grep -q 'STUB' "$W/out" && bad "pre-seed went past the verification" || ok "pre-seed stopped before creating data.ext4"
cp "$PROFILE" "$W/galayer/apparmor/hassio-supervisor"
ran=$((ran + 1)); env PATH="$W/stub:$PATH" bash "$CDP_SH" "$W/cdp-build" "$W/cdp-dst" stable 0 1M "$W/galayer" >"$W/out" 2>&1
if grep -q 'apparmor-profile: ok' "$W/out" && grep -q 'STUB' "$W/out"; then ok "pre-seed with the pinned profile passes the verification (then reaches the stubbed tools)"
else bad "pre-seed with the pinned profile did not pass the verification: $(head -1 "$W/out")"; fi
expect refuse "pre-seed without the GA layer argument" 'GA layer path missing' -- \
  env PATH="$W/stub:$PATH" bash "$CDP_SH" "$W/cdp-build" "$W/cdp-dst" stable 0 1M
HASH="$(grep -vE '^[[:space:]]*(#|$)' "$PIN" | cut -d' ' -f1)"
ran=$((ran + 1))
mapfile -t holders < <(git -C "$ROOT" grep -l -F "$HASH" -- . 2>/dev/null)
if [[ "${#holders[@]}" -eq 1 && "${holders[0]}" == "buildroot-external/apparmor/hassio-supervisor.sha256" ]]; then
  ok "the full pin appears in exactly one tracked file"
else
  bad "the full pin must live in hassio-supervisor.sha256 only; found in: ${holders[*]:-<none>}"
fi

echo
(( ran > 0 )) || { echo "FAIL: zero cases ran"; exit 1; }
if (( fails )); then echo "${fails} of ${ran} cases FAILED"; exit 1; fi
echo "all ${ran} cases passed"
