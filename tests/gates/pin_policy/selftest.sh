#!/usr/bin/env bash
# =============================================================================
# selftest.sh — ONE pin policy (scripts/lib/pin_policy.py), and both consumers
# reach the SAME verdict on it (rule 61).
# =============================================================================
# BOSv1.6.1-rc3 bake (ga-ops run 45225913542) was blocked because
# check-images.sh honoured a declared store_ahead and repin-addons.py --check
# did not. Every case below runs BOTH live consumers over the same scratch tree
# and store, and asserts the verdict of each:
#   must-pass: a valid declaration (pin newer, with a reason and an end date in range)
#   must-fail: expired; no reason; until > 30 days; malformed date; pin BEHIND
#              the store with a store_ahead; pin ahead WITHOUT a store_ahead
# Plus the module's own rules (is_prerelease, ordering) via its CLI, and a
# guard that no consumer re-declares the rules.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
POL="$ROOT/scripts/lib/pin_policy.py"
REPIN="$ROOT/scripts/repin-addons.py"
GATE="$ROOT/scripts/check-images.sh"
fails=0; ran=0
ok()  { ran=$((ran+1)); printf '  ok    %s\n' "$*"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf '  FAIL  %s\n' "$*"; }
for f in "$POL" "$REPIN" "$GATE"; do [[ -f "$f" ]] || { echo "FATAL: $f missing"; exit 2; }; done
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
IMAGE="ghcr.io/greenautarky/ga_influxdbv1-{arch}"
TODAY=2026-11-23
cat > "$WORK/stable.json" <<'JSON'
{"supervisor":"0","core":"0","cli":"0","dns":"0","audio":"0","multicast":"0","observer":"0",
 "images":{"supervisor":"localhost:1/none-{arch}","core":"localhost:1/none-{arch}-{machine}",
           "cli":"localhost:1/none-{arch}","dns":"localhost:1/none-{arch}",
           "audio":"localhost:1/none-{arch}","multicast":"localhost:1/none-{arch}",
           "observer":"localhost:1/none-{arch}"}}
JSON

make_case() { # make_case <pin> <store> <store_ahead-json-or-empty>
  mkdir -p "$WORK/repo/buildroot-external/package/hassio"
  local sa=""; [[ -n "$3" ]] && sa=", \"store_ahead\": $3"
  printf '{"addons":{"ga_influxdbv1":{"image":"%s","version":"%s"%s}}}\n' "$IMAGE" "$1" "$sa" \
    > "$WORK/repo/buildroot-external/package/hassio/addon-images.json"
  rm -rf "$WORK/store"; mkdir -p "$WORK/store/influxdb"
  printf 'name: "InfluxDB"\nversion: "%s"\nslug: "ga_influxdbv1"\nimage: %s\n' "$2" "$IMAGE" > "$WORK/store/influxdb/config.yaml"
  git -C "$WORK/store" init -q -b main
  git -C "$WORK/store" -c user.email=t@e -c user.name=t add -A
  git -C "$WORK/store" -c user.email=t@e -c user.name=t commit -qm store
}
verdicts() { # -> sets rrc (repin --check rc), gdrift (gate's "out of lockstep: N")
  rout="$(GA_TODAY=$TODAY REPO_ROOT="$WORK/repo" python3 "$REPIN" --check --store "$WORK/store" 2>&1)"; rrc=$?
  gout="$(GA_TODAY=$TODAY REPO_ROOT="$WORK/repo" VIBE_ADDONS_REPO_URL="$WORK/store" VIBE_ADDONS_REPO_REF=main \
          "$GATE" "$WORK/stable.json" 2>&1 || true)"
  gdrift="$(grep -oE 'out of lockstep: [0-9]+' <<<"$gout" | grep -oE '[0-9]+$' | head -1)"
}
SA() { printf '{"reason":"%s","until":"%s"}' "$1" "$2"; }

echo "== must-pass: a valid store_ahead is NOT drift in either consumer =="
make_case 0.0.25 0.0.23 "$(SA 'rc3 by Manager decision' 2026-12-10)"; verdicts
[[ "$rrc" == 0 ]] && grep -q 'AHEAD-OF-STORE ga_influxdbv1' <<<"$rout" && ok "repin --check: valid store_ahead -> 0, AHEAD-OF-STORE" \
  || bad "repin --check rejects a valid store_ahead (rc=$rrc): $(grep -E 'DRIFT|FAIL' <<<"$rout" | head -2)"
[[ "$gdrift" == 0 ]] && ok "check-images.sh: valid store_ahead -> out of lockstep: 0" || bad "check-images.sh: out of lockstep: ${gdrift:-?}"

echo "== must-fail: both consumers count it as drift =="
case_fail() { # case_fail <name> <pin> <store> <sa-json-or-empty> <repin-out-must-contain>
  make_case "$2" "$3" "$4"; verdicts
  [[ "$rrc" != 0 ]] && grep -q "DRIFT ga_influxdbv1" <<<"$rout" && grep -q -- "$5" <<<"$rout" \
    && ok "repin --check: $1 -> drift" || bad "repin --check: $1 not drift (rc=$rrc): $(tail -2 <<<"$rout")"
  [[ "${gdrift:-0}" -ge 1 ]] && ok "check-images.sh: $1 -> out of lockstep: $gdrift" || bad "check-images.sh: $1 not counted (${gdrift:-?})"
}
case_fail "expired store_ahead"          0.0.25 0.0.23 "$(SA 'x' 2026-11-01)" "expired on 2026-11-01"
case_fail "store_ahead without a reason" 0.0.25 0.0.23 "$(SA '' 2026-12-10)" "has no reason"
case_fail "store_ahead > 30 days"        0.0.25 0.0.23 "$(SA 'x' 2027-02-01)" "more than 30 days"
case_fail "malformed until"              0.0.25 0.0.23 "$(SA 'x' 10.12.2026)" "not YYYY-MM-DD"
case_fail "pin BEHIND store w/ store_ahead" 0.0.23 0.0.25 "$(SA 'x' 2026-12-10)" "not newer than the store"
case_fail "pin ahead WITHOUT store_ahead" 0.0.25 0.0.23 "" "pinned 0.0.25 -> store 0.0.23"

echo "== the module's own rules (live CLI) =="
for v in 1.3.0-ga.1 2.0.0-rc.1; do python3 "$POL" is-prerelease "$v" && ok "is_prerelease $v" || bad "$v not a pre-release"; done
for v in 2.12.1-11 2.12.1 0.0.25; do python3 "$POL" is-prerelease "$v" && bad "$v taken as pre-release" || ok "release $v"; done
python3 -c "import sys; sys.path.insert(0,'$ROOT/scripts/lib'); import pin_policy as p
seq=['2.12.1','2.12.1-11','2.12.1-12','2.12.2']
assert all(p.is_newer(b,a) for a,b in zip(seq,seq[1:])), 'order'
assert not p.is_newer('0.0.23','0.0.25')" && ok "ordering 2.12.1 < -11 < -12 < 2.12.2" || bad "ordering wrong"

echo "== one definition: no consumer re-declares the rules =="
n="$(grep -lE '^def _is_prerelease|suffix\) and any\(ch\.isalpha' "$ROOT"/scripts/*.py 2>/dev/null | wc -l)"
[[ "$n" == 0 ]] && ok "no python consumer defines its own _is_prerelease" || bad "$n python consumer(s) still define _is_prerelease"
grep -qE "grep -q '\[A-Za-z\]'|_sa_until\" < \"\\\$_today\"|\[\[ \"\\\$_sa_until\" [<>]" "$GATE" && bad "check-images.sh still decides the rules itself" || ok "check-images.sh delegates the verdicts to pin_policy.py"

echo
echo "pin policy selftest: ${ran} checks, ${fails} failed"
[[ "$ran" -ge 22 ]] || { echo "FATAL: only ${ran} checks ran"; exit 2; }
[[ "$fails" -eq 0 ]]
