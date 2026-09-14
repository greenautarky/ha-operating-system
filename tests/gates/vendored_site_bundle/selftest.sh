#!/usr/bin/env bash
# =============================================================================
# selftest.sh — the vendored-wizard gate must go red on the shipped defect and
#               stay quiet on a correct bundle.
# =============================================================================
# The gate under test replaced nothing: this seam had no check at all. A release
# shipped a wizard bundle built from a pre-rename tree — it asked for the
# component's retired static mount and its retired REST namespace, so every
# asset and every API call 404'd and a freshly flashed device rendered a blank
# page. The same artifact carried the frontend build's placeholder version, and
# an earlier one shipped two entry bundles per flavour. The build was green
# throughout.
#
# So all three go in as must-fail fixtures, plus every way the check can end up
# inspecting nothing — that last family is the one that let this ship, and a
# gate that reports success over zero files is worse than no gate.
#
# must-pass is not padding. The wizard legitimately calls stock Home Assistant
# endpoints (/api/image, /api/hassio, /api/websocket), the component legitimately
# serves a SECOND namespace of its own, LICENSE sidecars sit next to every entry
# bundle and webpack chunks share the flavour directory. Flagging any of those
# would train people to reach for the override, which is a slower way of having
# no gate at all — so each is a fixture the gate must NOT flag.
#
# Everything is scratch: no network, no registry, no real component. What is
# under test is the comparison logic, and the LIVE script is what runs — this
# file never re-implements a pattern. If it stopped finding the script, that is
# a failure, not a skip.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$ROOT/scripts/check-vendored-site-bundle.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; NC=''; }
fails=0; ran=0

bad() { printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$*"; fails=$((fails + 1)); }
ok()  { printf '  %sok%s    %s\n' "$GRN" "$NC" "$*"; }

[[ -x "$GATE" ]] || { echo "FATAL: $GATE missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
C="$WORK/greenautarky_site"

# --- the known-good fixture ----------------------------------------------
#
# Shaped like the real vendored component: a Python side that declares what is
# served, and a frontend_bundle whose HTML shell loads one hashed entry bundle
# per flavour. Both halves are correct here; every must-fail case below breaks
# exactly ONE of them, so a failure names the thing that broke.

mk_good() {
    rm -rf "$C"
    mkdir -p "$C/frontend_bundle/frontend_latest" "$C/frontend_bundle/frontend_es5"

    cat > "$C/__init__.py" <<'PY'
"""Scratch stand-in for the component's entry module."""
URL_BASE = "/greenautarky_site_static"
PANEL_URL_PATH = "greenautarky-setup-panel"
PY

    # Two namespaces on purpose: a component may serve more than one, and the
    # check must read the route declarations rather than derive them from the
    # domain.
    cat > "$C/views.py" <<'PY'
class GAStatusView:
    url = "/api/greenautarky_site/status"


class GARemoteLoginView:
    url = "/api/ga_remote_login/token"
PY

    printf '{"domain": "greenautarky_site", "name": "GreenAutarky Site"}\n' > "$C/manifest.json"

    cat > "$C/frontend_bundle/BUILD-INFO.txt" <<'TXT'
source_repo: https://example.invalid/frontend.git
source_ref: 0badc0de1
entry: greenautarky-setup
built_at: 2026-09-14T00:00:00Z
TXT

    cat > "$C/frontend_bundle/greenautarky-setup.html" <<'HTML'
<!DOCTYPE html><html><head><title>Setup</title>
<link rel="modulepreload" href="/greenautarky_site_static/frontend_latest/greenautarky-setup.aaaa1111.js" crossorigin="use-credentials">
</head><body><ha-panel-greenautarky-setup></ha-panel-greenautarky-setup>
<script>isModern&&import("/greenautarky_site_static/frontend_latest/greenautarky-setup.aaaa1111.js")</script>
<script>window.latestJS||_ls("/greenautarky_site_static/frontend_es5/greenautarky-setup.bbbb2222.js",!0)</script>
</body></html>
HTML

    # The entry bundles. They carry a real CalVer stamp, call the component's
    # own REST API in both its namespaces, AND call stock Home Assistant
    # endpoints — which the component does not serve and must not be flagged
    # for.
    _entry_js() {
        cat <<'JS'
var __webpack_public_path__ = "/greenautarky_site_static/frontend_latest/";
var VERSION = "20260914.0";
fetch("/api/greenautarky_site/status");
fetch("/api/greenautarky_site/verify_pin");
fetch("/api/ga_remote_login/token");
fetch("/api/image/serve/1");
fetch("/api/hassio/addons");
fetch("/api/media_source/browse");
new WebSocket("/api/websocket");
JS
    }
    _entry_js > "$C/frontend_bundle/frontend_latest/greenautarky-setup.aaaa1111.js"
    _entry_js > "$C/frontend_bundle/frontend_es5/greenautarky-setup.bbbb2222.js"

    # A LICENSE sidecar sits next to every real entry bundle, and webpack emits
    # numeric chunks into the same directory. Neither is a second entry bundle.
    for f in frontend_latest/greenautarky-setup.aaaa1111.js frontend_es5/greenautarky-setup.bbbb2222.js; do
        printf '/*! licence text */\n' > "$C/frontend_bundle/${f}.LICENSE.txt"
    done
    printf 'export const chunk=1;\n' > "$C/frontend_bundle/frontend_latest/4711.cafe0001.js"
    printf 'export const chunk=2;\n' > "$C/frontend_bundle/frontend_es5/4711.cafe0002.js"
    printf 'export const w=1;\n'     > "$C/frontend_bundle/frontend_es5/markdown-worker.dead0001.js"
}

# run <expect-rc> <label> <expect-regex-or-empty> <forbid-regex-or-empty>
run() {
    local want="$1" label="$2" expect="$3" forbid="$4" out rc
    ran=$((ran + 1))
    out="$("$GATE" --component-dir "$C" 2>&1)"
    rc=$?
    if [[ "$rc" -ne "$want" ]]; then
        bad "$label — expected rc=$want, got rc=$rc"
        sed 's/^/          /' <<<"$out" | head -12
        return
    fi
    if [[ -n "$expect" ]] && ! grep -qE "$expect" <<<"$out"; then
        bad "$label — expected /$expect/ in the output"
        sed 's/^/          /' <<<"$out" | head -12
        return
    fi
    if [[ -n "$forbid" ]] && grep -qE "$forbid" <<<"$out"; then
        bad "$label — output must NOT contain /$forbid/"
        sed 's/^/          /' <<<"$out" | head -12
        return
    fi
    ok "$label"
}

echo "== must-pass: a correct, current bundle is not flagged =="

# The baseline. Without it every must-fail case below would also be satisfied
# by a check that simply fails everything, and the suite would look rigorous
# while proving nothing.
mk_good
run 0 "correct bundle -> pass, all 3 checks ran" 'vendored site bundle: 3/3 checks ran' 'FAIL'

# Named individually, because "3/3 ran" would also hold if one check were
# inspecting the wrong thing.
mk_good
run 0 "stock HA endpoints (/api/image, /api/hassio, /api/websocket) are not flagged" \
      'ok  VSB-1' 'api/(image|hassio|websocket)'

mk_good
run 0 "a second namespace the component really serves is not flagged" \
      'served REST prefixes: /api/ga_remote_login /api/greenautarky_site' 'ga_remote_login/…'

mk_good
run 0 "a real CalVer version stamp is not a placeholder" 'ok  VSB-2' 'FAIL: VSB-2'

mk_good
run 0 "LICENSE sidecars and numeric chunks are not second entry bundles" \
      'ok  VSB-3: exactly one greenautarky-setup entry bundle in each of the 2 flavour' 'VSB-3:.*ships 2'

echo "== must-fail: the defect that shipped =="

# 1. The static mount. The bundle was built before the component was renamed,
#    so it asks for the retired mount and every asset 404s.
mk_good
sed -i 's#/greenautarky_site_static#/greenautarky_onboarding_static#g' \
    "$C/frontend_bundle/greenautarky-setup.html" \
    "$C/frontend_bundle/frontend_latest/greenautarky-setup.aaaa1111.js" \
    "$C/frontend_bundle/frontend_es5/greenautarky-setup.bbbb2222.js"
run 1 "retired static mount -> FAIL, both sides named" \
      "VSB-1: shipped assets request '/greenautarky_onboarding_static/….*serves '/greenautarky_site_static/…'" ''

# The same fixture proves the checks do not mask each other: a wrong prefix is
# VSB-1's finding and must leave VSB-3's entry-bundle count intact, or the two
# would be one check wearing two names.
run 1 "a wrong prefix does not also break the entry-bundle count" 'ok  VSB-3' 'FAIL: VSB-3'

# 2. The REST namespace, broken independently of the static mount.
mk_good
sed -i 's#/api/greenautarky_site#/api/greenautarky_onboarding#g' \
    "$C/frontend_bundle/frontend_latest/greenautarky-setup.aaaa1111.js"
run 1 "retired REST namespace -> FAIL, named with what IS served" \
      "VSB-1: shipped assets call '/api/greenautarky_onboarding/….*serves: /api/ga_remote_login /api/greenautarky_site" ''

# 3. The placeholder version stamp: a hand-run dev build vendored into a
#    release. This is SRC-13's intent, moved to the artifact.
mk_good
sed -i 's#var VERSION = "20260914.0";#var VERSION = "0.0.0.dev0";#' \
    "$C/frontend_bundle/frontend_latest/greenautarky-setup.aaaa1111.js"
run 1 "0.0.0.dev0 stamp -> FAIL, file named" \
      'VSB-2: the vendored bundle carries a placeholder version stamp' ''

# The family, not the single literal — a different dev suffix or the dashed
# spelling is the same defect.
mk_good
sed -i 's#var VERSION = "20260914.0";#var VERSION = "0.0.0-dev";#' \
    "$C/frontend_bundle/frontend_es5/greenautarky-setup.bbbb2222.js"
run 1 "0.0.0-dev (the dashed spelling) -> FAIL too" 'VSB-2:' ''

# 4. Two entry bundles in one flavour: a stale carry-over shipped next to the
#    live one. Never loaded, always shipped, and it makes every later grep over
#    the artifact answer about the wrong file.
mk_good
cp "$C/frontend_bundle/frontend_latest/greenautarky-setup.aaaa1111.js" \
   "$C/frontend_bundle/frontend_latest/greenautarky-setup.9999ffff.js"
run 1 "two entry bundles in one flavour -> FAIL, both listed" \
      'VSB-3: frontend_latest/ ships 2 entry bundles' ''

# The orphan in the OTHER flavour must fail just as loudly — a per-flavour loop
# that only ever looks at the first directory would pass this.
mk_good
cp "$C/frontend_bundle/frontend_es5/greenautarky-setup.bbbb2222.js" \
   "$C/frontend_bundle/frontend_es5/greenautarky-setup.8888eeee.js"
run 1 "the orphan in the second flavour is caught too" \
      'VSB-3: frontend_es5/ ships 2 entry bundles' ''

# 5. One entry bundle on disk, but the shell loads a hash that is not there.
#    Same 404 by another route.
mk_good
sed -i 's#greenautarky-setup.aaaa1111.js#greenautarky-setup.dddd4444.js#g' \
    "$C/frontend_bundle/greenautarky-setup.html"
run 1 "shell points at a file that is not shipped -> FAIL" \
      'VSB-3: greenautarky-setup.html loads frontend_latest/greenautarky-setup.dddd4444.js but frontend_latest/ holds greenautarky-setup.aaaa1111.js' ''

echo "== must-fail: inspecting nothing is a failure, never a pass =="

# This whole family is why the defect shipped. Each one is a way the check can
# end up with no evidence; every one of them has to be red.

mk_good
rm -rf "$C/frontend_bundle"
run 1 "no frontend_bundle at all -> FAIL, 0/3 ran" \
      'vendored site bundle: 0/3 checks ran' ''

mk_good
find "$C/frontend_bundle" -type f -delete
run 1 "an empty frontend_bundle -> FAIL, not a pass over zero files" \
      'the vendored frontend_bundle holds no web assets' ''

mk_good
sed -i '/^URL_BASE/d' "$C/__init__.py"
run 1 "URL_BASE gone -> FAIL (cannot resolve what is served)" \
      'expected exactly one URL_BASE definition .* found 0' ''

mk_good
printf 'URL_BASE = "/some_other_static"\n' >> "$C/__init__.py"
run 1 "two URL_BASE definitions -> FAIL, never pick one" \
      'expected exactly one URL_BASE definition .* found 2' ''

mk_good
sed -i 's#^URL_BASE = .*#URL_BASE = _compute_base()#' "$C/__init__.py"
run 1 "URL_BASE that is not a literal path -> FAIL rather than guess" \
      'URL_BASE did not parse to an absolute path' ''

mk_good
rm -f "$C/views.py"
run 1 "no route declarations left to read -> FAIL" \
      "found no 'url = \"/api/…\"' route declarations" ''

mk_good
printf '{"name": "GreenAutarky Site"}\n' > "$C/manifest.json"
run 1 "manifest with no domain -> FAIL (the API comparison cannot be scoped)" \
      'manifest.json declares no domain' ''

mk_good
sed -i 's#/greenautarky_site_static/#/#g' \
    "$C/frontend_bundle/greenautarky-setup.html" \
    "$C/frontend_bundle/frontend_latest/greenautarky-setup.aaaa1111.js" \
    "$C/frontend_bundle/frontend_es5/greenautarky-setup.bbbb2222.js"
run 1 "zero static references found -> FAIL, not a quiet pass" \
      "VSB-1: the shipped assets reference no '/<name>_static' path at all" ''

mk_good
sed -i 's#/api/greenautarky_site/[a-z_]*#/api/hassio/x#g' \
    "$C/frontend_bundle/frontend_latest/greenautarky-setup.aaaa1111.js" \
    "$C/frontend_bundle/frontend_es5/greenautarky-setup.bbbb2222.js"
run 1 "zero own-namespace API references found -> FAIL, not a quiet pass" \
      "VSB-1: the shipped assets reference no '/api/greenautarky\*' endpoint at all" ''

mk_good
rm -f "$C/frontend_bundle/BUILD-INFO.txt"
run 1 "BUILD-INFO.txt gone -> FAIL (the entry name is no longer readable)" \
      'BUILD-INFO.txt is missing' ''

mk_good
sed -i '/^entry:/d' "$C/frontend_bundle/BUILD-INFO.txt"
run 1 "BUILD-INFO.txt with no entry: -> FAIL, never skip" \
      "declares no 'entry:'" ''

mk_good
rm -f "$C/frontend_bundle/greenautarky-setup.html"
run 1 "HTML shell gone -> FAIL (nothing declares the live entry bundle)" \
      'the HTML shell greenautarky-setup.html is missing' ''

mk_good
rm -rf "$C/frontend_bundle/frontend_latest" "$C/frontend_bundle/frontend_es5"
run 1 "no flavour directories -> FAIL, zero flavours inspected" \
      'no frontend_\* flavour directories' ''

mk_good
rm -f "$C/frontend_bundle/frontend_es5/greenautarky-setup.bbbb2222.js"
run 1 "a flavour with no entry bundle -> FAIL" \
      'VSB-3: frontend_es5/ ships no greenautarky-setup\.\*\.js entry bundle' ''

echo "== must-fail: the gate itself must be reachable =="

ran=$((ran + 1))
out="$("$GATE" --component-dir "$WORK/does-not-exist" 2>&1)"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -qE 'component dir does not exist' <<<"$out"; then
    ok "an absent component dir -> FAIL, not a skip"
else
    bad "absent component dir gave rc=$rc"
    sed 's/^/          /' <<<"$out" | head -4
fi

echo
if (( ran == 0 )); then printf '%sFATAL%s nothing evaluated\n' "$RED" "$NC"; exit 1; fi
if (( fails == 0 )); then
    printf '%svendored site bundle selftest: %d/%d%s\n' "$GRN" "$ran" "$ran" "$NC"; exit 0
fi
printf '%svendored site bundle selftest: %d of %d FAILED%s\n' "$RED" "$fails" "$ran" "$NC"; exit 1
