#!/usr/bin/env bash
# Self-test: push-ota.sh --server stages the board-specific name (Odoo #1640).
# Drives the LIVE scripts/push-ota.sh (override: PUSH_OTA=<path>, used for the
# red proof against the pre-change script) with --dry-run over synthetic
# verity-shaped bundles (squashfs holding manifest.raucm, like a real .raucb).
# Expected server paths are pinned constants, not derived from the script.
# --dry-run never contacts a server.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PUSH="${PUSH_OTA:-$HERE/../../../scripts/push-ota.sh}"
[[ -f "$PUSH" ]] || { echo "ERROR: $PUSH not found" >&2; exit 2; }
command -v mksquashfs >/dev/null && command -v unsquashfs >/dev/null || { echo "ERROR: squashfs-tools missing — nothing proven" >&2; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

mk() {  # <name> <manifest-text or ->  -> bundle path
  local d="$W/$1.d"; mkdir -p "$d"
  [[ "$2" == "-" ]] && : > "$d/other" || printf '%s\n' "$2" > "$d/manifest.raucm"
  mksquashfs "$d" "$W/$1.raucb" -quiet -noappend -no-progress >/dev/null 2>&1
  echo "$W/$1.raucb"
}
IH="$(mk ihost    $'[update]\ncompatible=haos-ihost\nversion=16.3.1.9\n')"
DS="$(mk dsgw     $'[update]\ncompatible=haos-dsgw210\nversion=16.3.1.9\n')"
NM="$(mk nomf     -)"
UK="$(mk unknown  $'[update]\ncompatible=haos-rpi5-64\nversion=16.3.1.9\n')"

# case <id> <want-target-regex|REFUSE> <bundle> [extra args]
run() {
  local id="$1" want="$2" b="$3"; shift 3
  local out rc
  out="$(OTA_SSH_HOST=h OTA_SERVER_PATH=/r bash "$PUSH" --server --dry-run --raucb "$b" --version 16.3.1.9 "$@" 2>&1)"; rc=$?
  if [[ "$want" == REFUSE ]]; then
    if (( rc != 0 )) && ! grep -q '^Target:' <<<"$out"; then ok "$id (refused rc=$rc)"; else bad "$id — expected refusal, rc=$rc: $(grep -m1 -E 'Target:|ERROR' <<<"$out")"; fi
  else
    if (( rc == 0 )) && grep -qxF "Target: h:$want" <<<"$out"; then ok "$id -> $want"; else bad "$id — want 'Target: h:$want', rc=$rc got: $(grep -m1 -E 'Target:|ERROR' <<<"$out")"; fi
  fi
}
echo "=== push-ota.sh --server board naming ==="
run PO-01-ihost              /r/16.3.1.9/haos_ihost-16.3.1.9.raucb   "$IH"
run PO-02-dsgw210            /r/16.3.1.9/haos_dsgw210-16.3.1.9.raucb "$DS"
run PO-03-ihost-board-ok     /r/16.3.1.9/haos_ihost-16.3.1.9.raucb   "$IH" --board ihost
run PO-04-dsgw-board-ok      /r/16.3.1.9/haos_dsgw210-16.3.1.9.raucb "$DS" --board dsgw210
run PO-05-dsgw-canary        /r/16.3.1.9/BOSv1.6.0-rc5/haos_dsgw210-16.3.1.9.raucb "$DS" --ga-release BOSv1.6.0-rc5
run PO-06-ihost-canary       /r/16.3.1.9/BOSv1.6.0-rc5/haos_ihost-16.3.1.9.raucb "$IH" --ga-release BOSv1.6.0-rc5
run PO-07-mismatch-dsgw-as-ihost REFUSE "$DS" --board ihost
run PO-08-mismatch-ihost-as-dsgw REFUSE "$IH" --board dsgw210
run PO-09-no-manifest        REFUSE "$NM"
run PO-10-no-manifest-board-flag REFUSE "$NM" --board ihost
run PO-11-unknown-compatible REFUSE "$UK"
echo
echo "${pass} ok, ${fail} failed"
(( pass + fail == 11 )) || { echo "ERROR: expected 11 cases" >&2; exit 2; }
(( fail == 0 ))
