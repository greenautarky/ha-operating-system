#!/usr/bin/env bash
# evidence_order/selftest.sh — release evidence is collected AFTER every file it files.
#
# WHY
#   collect-release-evidence.sh REQUIRES images/configs/MANIFEST.txt (written by
#   archive_build_configs) and images/sbom-containers.json (written by generate_sbom),
#   and EXPECTS sbom-cyclonedx.json and LICENSE-SUMMARY.txt. It was called from INSIDE
#   archive_build_configs, i.e. before generate_sbom ran:
#     BOSv1.6.0-rc4  (2026-11-07)  "required evidence missing or empty: MANIFEST.txt"
#     BOSv1.6.0-rc12 (2026-11-11)  "... missing or empty: sbom-containers.json"
#     BOSv1.5.4-rc1  (2026-11-11)  "... missing or empty: sbom-containers.json MANIFEST.txt"
#   Every bake was therefore marked "cannot be promoted". The first fix (#995) only
#   reordered inside archive_build_configs and the selftest only judged MANIFEST +
#   lockfile, so it stayed green while sbom-containers.json was still produced later.
#
# RULE (whole-script, top-level call order)
#   the top-level invocation of collect_build_evidence comes after the top-level
#   invocations of archive_build_configs, archive_legal_info, generate_sbom and
#   assert_prod_sbom; "$_ev_script" is run ONLY inside collect_build_evidence; and the
#   files it needs are still produced by the functions the order was judged on
#   (MANIFEST.txt in archive_build_configs, sbom-containers.json in generate_sbom).
#
# The SAME function judges the fixtures and the live file. A marker that cannot be
# found is "could not check" (exit 2), never a pass. Exit 0 green, 1 verdict failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/tests/gates/evidence_order"
LIVE="${EVIDENCE_ORDER_LIVE:-$ROOT/scripts/ga_build.sh}"

# verdict <file> -> prints ok | bad:<why> | unknown:<what>
verdict() {
  awk '
    /^[a-z_]+\(\) *\{/ { fn=$1; sub(/\(\).*/, "", fn) }
    /^[a-z_]+\(\) *\{.*\}[[:space:]]*$/ { fn="" }   # one-line function
    /^\}/ { fn="" }
    fn=="archive_build_configs" && /\} > "\$manifest"/ { mf=1 }
    fn=="generate_sbom" && /containers_file="\$\{OUT\}\/images\/sbom-containers\.json"/ { sb=1 }
    /"\$_ev_script" "\$OUT"/ { if (fn=="collect_build_evidence") evfn=1; else if (!stray) stray=(fn==""?"top-level":fn) }
    fn=="" && /^archive_build_configs[[:space:]]*$/ && !a {a=NR}
    fn=="" && /^archive_legal_info[[:space:]]*$/    && !l {l=NR}
    fn=="" && /^generate_sbom([[:space:]]|$)/       && !g {g=NR}
    fn=="" && /^assert_prod_sbom([[:space:]]|$)/    && !s {s=NR}
    fn=="" && /^collect_build_evidence[[:space:]]*$/ && !e {e=NR}
    END {
      if (!mf)   {print "unknown:MANIFEST write in archive_build_configs"; exit}
      if (!sb)   {print "unknown:sbom-containers.json in generate_sbom"; exit}
      if (!evfn && !stray) {print "unknown:\"$_ev_script\" call"; exit}
      if (!a || !l || !g || !s) {print "unknown:top-level call of archive_build_configs/archive_legal_info/generate_sbom/assert_prod_sbom"; exit}
      if (stray) {print "bad:evidence collector run inside " stray " (must be inside collect_build_evidence)"; exit}
      if (!e)    {print "bad:collect_build_evidence is never invoked at top level"; exit}
      if (e<a || e<l || e<g || e<s) {print "bad:collect_build_evidence (line " e ") runs before a generator (archive_build_configs " a ", archive_legal_info " l ", generate_sbom " g ", assert_prod_sbom " s ")"; exit}
      print "ok"
    }' "$1"
}

fails=0 ran=0
check() { # <file> <expect ok|bad> <label>
  local v; v="$(verdict "$1")"; ran=$((ran+1))
  case "$v" in unknown:*) echo "ERROR (could not check): $3: ${v#unknown:} not found in $1" >&2; exit 2 ;; esac
  if [[ "${v%%:*}" == "$2" ]]; then echo "  ok    $3 ($v)"; else echo "  FAIL  $3: expected $2, got $v"; fails=$((fails+1)); fi
}
for f in "$HERE"/must-fail/*.sh; do check "$f" bad "must-fail $(basename "$f")"; done
for f in "$HERE"/must-pass/*.sh; do check "$f" ok "must-pass $(basename "$f")"; done
check "$LIVE" ok "live $LIVE"
[[ $ran -ge 5 ]] || { echo "ERROR (could not check): only $ran case(s) ran" >&2; exit 2; }
echo "$ran cases ran, $fails failed"
[[ $fails -eq 0 ]]
