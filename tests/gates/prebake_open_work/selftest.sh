#!/usr/bin/env bash
# Fixtures for scripts/preflight-open-work.sh — the gate that says what a bake
# will NOT contain.
#
# A red proof pasted into a review is evidence once, about one version, and
# nothing re-checks it when the gate is edited a month later. So the gate ships
# with two sets and CI runs both:
#
#   MUST FLAG      an open PR that changes the pins; pins out of step with the store
#   MUST NOT FLAG  drafts, dependabot, PRs that touch nothing the image contains,
#                  and a clean tree — a gate that flags everything gets overridden
#                  by reflex, which is a slower way of having no gate
#
# And two that are neither: the query failing must exit 2, never "nothing open".
# "No open PRs" and "I could not ask" look identical in a summary and mean
# opposite things.
#
# It drives the REAL script with a stub `gh` on PATH and a stub repin tool beside
# it. Nothing inside the script is mocked.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SCRIPT="$ROOT/scripts/preflight-open-work.sh"
PASS=0; FAIL=0
ck() { # ck <id> <desc> <expected-rc> <actual-rc> [<must-contain>] [<output>]
  local id="$1" d="$2" exp="$3" got="$4" needle="${5:-}" out="${6:-}"
  local ok=1
  [[ "$got" == "$exp" ]] || ok=0
  [[ -z "$needle" ]] || grep -q -- "$needle" <<<"$out" || ok=0
  if [[ $ok == 1 ]]; then echo "  PASS  $id: $d"; PASS=$((PASS+1));
  else echo "  FAIL  $id: $d  (rc erwartet $exp, war $got${needle:+; suchte '$needle'})"; FAIL=$((FAIL+1)); fi
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT fehlt"; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/scripts"
cp "$SCRIPT" "$W/scripts/"

# stub gh: answers `pr list` from $GH_PRS, or fails when $GH_FAIL is set
cat > "$W/bin/gh" <<'STUB'
#!/bin/sh
[ -n "${GH_FAIL:-}" ] && exit 1
printf '%s' "${GH_PRS:-[]}"
STUB
chmod +x "$W/bin/gh"
command -v jq >/dev/null 2>&1 || { echo "jq fehlt — kann nicht laufen"; exit 2; }

# stub repin: exit code from $REPIN_RC
cat > "$W/scripts/repin-addons.py" <<'STUB'
#!/usr/bin/env python3
import os, sys
print("inspected 8 pins against 10 store entries")
sys.exit(int(os.environ.get("REPIN_RC", "0")))
STUB
chmod +x "$W/scripts/repin-addons.py"

run() { GH_PRS="${1:-[]}" GH_FAIL="${2:-}" REPIN_RC="${3:-0}" \
        PATH="$W/bin:$PATH" bash "$W/scripts/preflight-open-work.sh" ${4:-} 2>&1; }

PIN='[{"number":611,"title":"pin ga_manager 0.199.0","isDraft":false,"author":{"login":"thomas-greenautarky"},"files":[{"path":"buildroot-external/package/hassio/addon-images.json"}]}]'
DOCS='[{"number":700,"title":"docs only","isDraft":false,"author":{"login":"thomas-greenautarky"},"files":[{"path":"README.md"}]}]'
DRAFT='[{"number":701,"title":"draft pin","isDraft":true,"author":{"login":"thomas-greenautarky"},"files":[{"path":"buildroot-external/package/hassio/addon-images.json"}]}]'
BOT='[{"number":702,"title":"bump","isDraft":false,"author":{"login":"app/dependabot"},"files":[{"path":"buildroot-external/package/hassio/version.yaml"}]}]'

echo "=== pre-bake open-work gate ==="
o=$(run "$PIN");    ck PBO-01 "MUST FLAG: an open PR that changes a pin file" 1 $? "#611" "$o"
o=$(run "$DOCS");   ck PBO-02 "MUST NOT FLAG: a PR that touches nothing the image contains" 0 $? "" "$o"
o=$(run "$DRAFT");  ck PBO-03 "MUST NOT FLAG: a DRAFT pin change is not a decision yet" 0 $? "" "$o"
o=$(run "$BOT");    ck PBO-04 "MUST NOT FLAG: dependabot is not a pin decision" 0 $? "" "$o"
o=$(run "" "1");    ck PBO-05 "FAIL CLOSED: the query failing is exit 2, not 'nothing open'" 2 $? "could not list" "$o"
o=$(run "not json"); ck PBO-06 "FAIL CLOSED: an unparseable answer is exit 2" 2 $? "not a list" "$o"
o=$(run "[]" "" "1"); ck PBO-07 "MUST FLAG: pins out of step with the published store" 1 $? "published store" "$o"
o=$(run "[]");      ck PBO-08 "MUST NOT FLAG: clean tree, clean pins -> green" 0 $? "nothing open" "$o"
o=$(run "$PIN" "" "1" "--acknowledge"); ck PBO-09 "--acknowledge bakes anyway, and SAYS so" 0 $? "ACKNOWLEDGED" "$o"
o=$(run "[]");      ck PBO-10 "it reports HOW MANY it measured, not just a colour" 0 $? "measured" "$o"

echo
echo "--- prebake_open_work: $PASS passed, $FAIL failed ---"
[[ $FAIL -eq 0 ]]
