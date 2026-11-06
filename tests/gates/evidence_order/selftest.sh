#!/usr/bin/env bash
# evidence_order/selftest.sh — release evidence is collected AFTER the files it files.
#
# WHY
#   archive_build_configs() in scripts/ga_build.sh collected the release evidence
#   (collect-release-evidence.sh, which REQUIRES images/configs/MANIFEST.txt) before
#   it wrote MANIFEST.txt and the container lockfile. On a clean tree the BOSv1.6.0-rc4
#   bake (2026-11-07) filed no MANIFEST; on an incremental tree every earlier bake
#   filed the PREVIOUS build's MANIFEST as its own evidence.
#
# RULE (inside archive_build_configs)
#   the line that runs "$_ev_script" comes after the MANIFEST.txt write
#   (`} > "$manifest"`) and after the container lockfile path is set.
#
# The SAME function judges the fixtures and the live file. A marker that cannot be
# found is "could not check" (exit 2), never a pass. Exit 0 green, 1 verdict failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/evidence_order"

# verdict <file> -> prints ok|bad|unknown:<what>
verdict() {
  awk '
    /^archive_build_configs\(\) *\{/ {inf=1}
    inf && /^\}/ {inf=0}
    inf && /\} > "\$manifest"/          && !m {m=NR}
    inf && /container_lock="\$\{cfg_dir\}\/container-images\.lock"/ && !l {l=NR}
    inf && /"\$_ev_script" "\$OUT"/     && !e {e=NR}
    END {
      if (!m) {print "unknown:MANIFEST write"; exit}
      if (!l) {print "unknown:container lockfile"; exit}
      if (!e) {print "unknown:evidence call"; exit}
      print ((e>m && e>l) ? "ok" : "bad")
    }' "$1"
}

fails=0 ran=0
check() { # <file> <expect ok|bad> <label>
  local v; v="$(verdict "$1")"; ran=$((ran+1))
  case "$v" in unknown:*) echo "ERROR (could not check): $3: ${v#unknown:} not found in $1" >&2; exit 2 ;; esac
  if [[ "$v" == "$2" ]]; then echo "  ok    $3 ($v)"; else echo "  FAIL  $3: expected $2, got $v"; fails=$((fails+1)); fi
}
for f in "$HERE"/must-fail/*.sh; do check "$f" bad "must-fail $(basename "$f")"; done
for f in "$HERE"/must-pass/*.sh; do check "$f" ok "must-pass $(basename "$f")"; done
check "$ROOT/scripts/ga_build.sh" ok "live scripts/ga_build.sh"
[[ $ran -ge 3 ]] || { echo "ERROR (could not check): only $ran case(s) ran" >&2; exit 2; }
echo "$ran cases ran, $fails failed"
[[ $fails -eq 0 ]]
