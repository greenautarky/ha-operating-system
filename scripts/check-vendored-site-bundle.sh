#!/usr/bin/env bash
# =============================================================================
# check-vendored-site-bundle.sh — the vendored wizard must be able to load.
# =============================================================================
# WHY THIS EXISTS
# ---------------
# The setup wizard is not built in this repository. It is vendored: the
# greenautarky_site component is pulled from GHCR by scripts/sync-components.sh
# at OS build time and baked into the rootfs-overlay, JS bundle and all. Between
# the component's Python and the JS it ships there is a seam, and nothing in
# this repository was looking at it.
#
# A release shipped a bundle built from a pre-rename tree. The component serves
# its assets under its own URL_BASE and its REST routes under its own domain;
# the bundle asked for the retired name. Every asset and every API call 404'd
# and the wizard rendered a blank page on a freshly flashed device. The build
# was green, the component was present, its manifest declared the right domain
# — BLD-FE-02 asks all of that and it was all true. Presence is not wiring.
#
# The same artifact carried the frontend build's PLACEHOLDER version, which
# means it was a hand-run dev build rather than a CI release, and at one point
# two entry bundles per flavour — the live one plus a stale carry-over from an
# earlier vendor run. An orphan is never loaded, but it IS shipped, and it makes
# every later grep over the artifact answer about the wrong file.
#
# Three checks were removed when the frontend fork was retired (SRC-10/12/13);
# the removal was right, because they asserted against source files that no
# longer exist anywhere near this repository. This is their INTENT at the layer
# that does exist: the vendored artifact.
#
# WHY EACH CHECK IS A COMPARISON AND NOT A GUESS
# ----------------------------------------------
# Both halves of every comparison come out of the same vendored tree, so there
# is no expectation written down here that a wrong artifact could satisfy:
#
#   VSB-1  served static mount  = URL_BASE, read from the component's Python
#          served REST prefixes = the `url = "/api/…"` route declarations
#          referenced           = what the shipped JS/HTML actually asks for
#          -> every reference must be one of the served values.
#
#   VSB-2  no placeholder version stamp in a release artifact. The frontend
#          build substitutes its version into the bundle; the placeholder
#          surviving means nothing substituted it, i.e. this is not a CI build.
#
#   VSB-3  exactly one entry bundle per flavour, and it is the one the HTML
#          shell loads. Entry name and flavours are read from the artifact's
#          own BUILD-INFO.txt and directory layout, never assumed.
#
# SCOPE OF VSB-1, STATED RATHER THAN IMPLIED
# ------------------------------------------
# The bundle legitimately calls stock Home Assistant endpoints — /api/image,
# /api/hassio, /api/websocket and friends — which this component does not serve
# and must not be flagged for. So the REST comparison is scoped to the
# component's OWN namespace: references whose first path segment shares the
# domain's namespace root (the part before the first underscore, e.g. domain
# `greenautarky_site` -> root `greenautarky`). That is exactly the near-miss
# family the rename defect lives in. A stock HA endpoint disappearing upstream
# is a different question and not this check's to answer.
#
# The static comparison needs no such scoping: the only `/<name>_static` mount
# in play is the component's own, so every such reference must equal URL_BASE.
#
# COVERAGE, NOT EXIT CODE
# -----------------------
# A tool that runs successfully over nothing is how this shipped. Every input
# this check depends on is fail-closed: no component dir, no bundle dir, no
# resolvable URL_BASE, no route declarations, no scanned files, no references
# found — each is a FAIL, never a skip and never a quiet pass. The summary line
# reports how many of the declared checks actually ran, and a shortfall is
# itself a failure.
#
# If the wizard ever legitimately stops calling its own REST API or loading its
# own static mount, this check must be revisited DELIBERATELY. Losing the
# reference counts silently is the failure mode it was written against.
#
# Usage:
#   check-vendored-site-bundle.sh --component-dir DIR [--quiet]
#
# Exit: 0 all declared checks ran and passed; 1 otherwise.
set -uo pipefail

# The number of checks this script declares. The summary fails closed when
# fewer than this many actually ran, so deleting a check cannot quietly reduce
# coverage while the exit code stays 0. One declaration, two observers: the
# build suite requires the summary line to exist, the self-test asserts its
# count.
CHECKS_TOTAL=3

COMPONENT_DIR=""
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --component-dir) COMPONENT_DIR="${2:-}"; shift 2 ;;
        --quiet)         QUIET=1; shift ;;
        -h|--help)
            echo "usage: $0 --component-dir DIR [--quiet]"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

checks_ran=0
failed=0

_note() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
_fail() { printf 'FAIL: %s\n' "$*"; failed=$((failed + 1)); }

# A precondition failure is not a check result — nothing was inspected, so
# nothing can be reported as ran. Exit immediately and loudly.
_fatal() { printf 'FAIL: %s\n' "$*"; printf 'vendored site bundle: 0/%d checks ran\n' "$CHECKS_TOTAL"; exit 1; }

# --- preconditions -------------------------------------------------------

[ -n "$COMPONENT_DIR" ] || _fatal "no --component-dir given"
[ -d "$COMPONENT_DIR" ] || _fatal "component dir does not exist: $COMPONENT_DIR"

command -v jq >/dev/null 2>&1 || _fatal "jq is required to read the component manifest"

INIT_PY="${COMPONENT_DIR}/__init__.py"
MANIFEST="${COMPONENT_DIR}/manifest.json"
BUNDLE_DIR="${COMPONENT_DIR}/frontend_bundle"

[ -f "$INIT_PY" ]   || _fatal "component __init__.py missing: $INIT_PY"
[ -f "$MANIFEST" ]  || _fatal "component manifest.json missing: $MANIFEST"
[ -d "$BUNDLE_DIR" ] || _fatal "vendored frontend_bundle missing: $BUNDLE_DIR"

# --- the served side: read the component's own declarations --------------

# URL_BASE, the component's static mount. Exactly one definition, or the
# extraction has stopped finding the live one and must fail rather than guess.
url_base_defs="$(grep -cE '^URL_BASE[[:space:]]*=' "$INIT_PY" || true)"
if [ "$url_base_defs" -ne 1 ]; then
    _fatal "expected exactly one URL_BASE definition in $(basename "$INIT_PY"), found ${url_base_defs} — cannot resolve what the component serves"
fi
URL_BASE="$(grep -E '^URL_BASE[[:space:]]*=' "$INIT_PY" | head -1 | sed -E 's/^URL_BASE[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
case "$URL_BASE" in
    /*) : ;;
    *)  _fatal "URL_BASE did not parse to an absolute path (got '${URL_BASE}')" ;;
esac

DOMAIN="$(jq -r '.domain // empty' "$MANIFEST" 2>/dev/null)"
[ -n "$DOMAIN" ] || _fatal "manifest.json declares no domain — cannot scope the API comparison"
NS_ROOT="${DOMAIN%%_*}"
[ -n "$NS_ROOT" ] || _fatal "cannot derive a namespace root from domain '${DOMAIN}'"

# The REST prefixes the component actually registers, taken from the route
# declarations themselves rather than derived from the domain — a component may
# legitimately serve more than one namespace, and it does.
served_api="$(grep -rhoE '^[[:space:]]*url[[:space:]]*=[[:space:]]*"/api/[A-Za-z0-9_]+' \
                   --include='*.py' "$COMPONENT_DIR" 2>/dev/null \
              | grep -oE '/api/[A-Za-z0-9_]+' | sort -u)"
[ -n "$served_api" ] || _fatal "found no 'url = \"/api/…\"' route declarations under $COMPONENT_DIR — the extraction no longer reads the live routes"

_note "served static mount : ${URL_BASE}"
_note "served REST prefixes: $(printf '%s' "$served_api" | tr '\n' ' ')"
_note "domain / namespace  : ${DOMAIN} / ${NS_ROOT}_*"

# --- the referencing side: what the shipped assets ask for ---------------

# Web assets only. Python is the truth side of the comparison and must not be
# read as evidence about itself.
ASSET_INCLUDES=(--include='*.js' --include='*.html' --include='*.css' --include='*.json')

asset_count="$(find "$COMPONENT_DIR" -type f \
                 \( -name '*.js' -o -name '*.html' -o -name '*.css' -o -name '*.json' \) \
               | wc -l)"

# The coverage gate is counted over the BUNDLE, not over the component dir.
# Counting the whole component would always be >= 1 — manifest.json is itself a
# scanned .json and a precondition — so the gate could never fire, and a check
# that cannot fail proves nothing. An empty frontend_bundle is a real and
# reachable way to inspect nothing.
bundle_assets="$(find "$BUNDLE_DIR" -type f \
                   \( -name '*.js' -o -name '*.html' -o -name '*.css' -o -name '*.json' \) \
                 | wc -l)"
if [ "$bundle_assets" -eq 0 ]; then
    _fatal "the vendored frontend_bundle holds no web assets (.js/.html/.css/.json) — nothing was inspected"
fi

# --- VSB-1: every reference agrees with what the component serves --------

checks_ran=$((checks_ran + 1))
vsb1_bad=0

ref_static="$(grep -rhoaE '/[A-Za-z0-9_]+_static' "${ASSET_INCLUDES[@]}" "$COMPONENT_DIR" 2>/dev/null | sort -u)"
if [ -z "$ref_static" ]; then
    _fail "VSB-1: the shipped assets reference no '/<name>_static' path at all. The HTML shell has to load the entry bundle from the component's static mount, so zero references means the extraction broke or the bundle is empty — either way nothing was compared."
    vsb1_bad=1
else
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if [ "$ref" != "$URL_BASE" ]; then
            _fail "VSB-1: shipped assets request '${ref}/…' but the component serves '${URL_BASE}/…' (URL_BASE) — every one of those is a 404"
            printf '        referenced by:\n'
            grep -rlaE "${ref}" "${ASSET_INCLUDES[@]}" "$COMPONENT_DIR" 2>/dev/null \
              | sed "s|^${COMPONENT_DIR}/|          |" | head -10
            vsb1_bad=1
        fi
    done <<< "$ref_static"
fi

ref_api="$(grep -rhoaE "/api/${NS_ROOT}[A-Za-z0-9_]*" "${ASSET_INCLUDES[@]}" "$COMPONENT_DIR" 2>/dev/null | sort -u)"
if [ -z "$ref_api" ]; then
    _fail "VSB-1: the shipped assets reference no '/api/${NS_ROOT}*' endpoint at all — the wizard drives its own REST API, so zero references means the extraction broke. A deliberate move away from the component's REST API has to change this check, not silently empty it."
    vsb1_bad=1
else
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if ! printf '%s\n' "$served_api" | grep -qxF "$ref"; then
            _fail "VSB-1: shipped assets call '${ref}/…' but the component registers no such route (it serves: $(printf '%s' "$served_api" | tr '\n' ' '))"
            printf '        referenced by:\n'
            grep -rlaE "${ref}" "${ASSET_INCLUDES[@]}" "$COMPONENT_DIR" 2>/dev/null \
              | sed "s|^${COMPONENT_DIR}/|          |" | head -10
            vsb1_bad=1
        fi
    done <<< "$ref_api"
fi

if [ "$vsb1_bad" -eq 0 ]; then
    _note "ok  VSB-1: every shipped asset/API reference matches what the component serves ($(printf '%s\n' "$ref_static" | wc -l) static, $(printf '%s\n' "$ref_api" | wc -l) API prefix(es) checked over ${asset_count} files)"
fi

# --- VSB-2: no placeholder version stamp in a release artifact -----------

checks_ran=$((checks_ran + 1))

# The frontend build substitutes its version in; `0.0.0.dev0` (and the rest of
# that family) surviving into the artifact means nothing substituted it.
PLACEHOLDER_RX='0\.0\.0[.-]dev[0-9]*'
placeholder_files="$(grep -rlaE "$PLACEHOLDER_RX" "${ASSET_INCLUDES[@]}" "$COMPONENT_DIR" 2>/dev/null || true)"
if [ -n "$placeholder_files" ]; then
    _fail "VSB-2: the vendored bundle carries a placeholder version stamp (/${PLACEHOLDER_RX}/) — this is a hand-run dev build, not a CI release"
    printf '        stamped files:\n'
    printf '%s\n' "$placeholder_files" | sed "s|^${COMPONENT_DIR}/|          |" | head -10
else
    _note "ok  VSB-2: no placeholder version stamp in the vendored bundle (${asset_count} files scanned)"
fi

# --- VSB-3: exactly one entry bundle per flavour ------------------------

checks_ran=$((checks_ran + 1))
vsb3_bad=0

BUILD_INFO="${BUNDLE_DIR}/BUILD-INFO.txt"
if [ ! -f "$BUILD_INFO" ]; then
    _fail "VSB-3: ${BUNDLE_DIR#"${COMPONENT_DIR}"/}/BUILD-INFO.txt is missing — the entry name is read from it, so without it nothing can be counted"
    vsb3_bad=1
else
    ENTRY="$(grep -E '^entry:[[:space:]]*' "$BUILD_INFO" | head -1 | sed -E 's/^entry:[[:space:]]*//' | tr -d '[:space:]')"
    if [ -z "$ENTRY" ]; then
        _fail "VSB-3: BUILD-INFO.txt declares no 'entry:' — the live entry name can no longer be read, which is a failure, not a skip"
        vsb3_bad=1
    fi
fi

if [ "$vsb3_bad" -eq 0 ]; then
    SHELL_HTML="${BUNDLE_DIR}/${ENTRY}.html"
    if [ ! -f "$SHELL_HTML" ]; then
        _fail "VSB-3: the HTML shell ${ENTRY}.html is missing from the bundle — nothing declares which entry bundle is the live one"
        vsb3_bad=1
    fi
fi

if [ "$vsb3_bad" -eq 0 ]; then
    flavour_count=0
    for fdir in "${BUNDLE_DIR}"/frontend_*/; do
        [ -d "$fdir" ] || continue
        flavour_count=$((flavour_count + 1))
        flavour="$(basename "$fdir")"

        # Entry bundles on disk for this flavour. A LICENSE sidecar ends in
        # .txt and cannot match.
        entries=()
        for cand in "${fdir}${ENTRY}."*.js; do
            [ -f "$cand" ] || continue
            entries+=("$(basename "$cand")")
        done

        if [ "${#entries[@]}" -eq 0 ]; then
            _fail "VSB-3: ${flavour}/ ships no ${ENTRY}.*.js entry bundle at all"
            vsb3_bad=1
            continue
        fi
        if [ "${#entries[@]}" -gt 1 ]; then
            _fail "VSB-3: ${flavour}/ ships ${#entries[@]} entry bundles — a stale carry-over from an earlier vendor run is shipped alongside the live one, and it makes every grep over this artifact answer about the wrong file"
            printf '        %s\n' "${entries[@]}"
            vsb3_bad=1
            continue
        fi

        # One on disk. The HTML shell decides which file is actually loaded, so
        # the two have to be the same file — a shell pointing at a hash that is
        # no longer on disk is the same 404 by another route. Matched WITHOUT
        # the URL prefix on purpose: a wrong prefix is VSB-1's finding, and one
        # check must not mask the other.
        wanted="$(grep -oaE "${flavour}/${ENTRY}\.[A-Za-z0-9]+\.js" "$SHELL_HTML" 2>/dev/null | sort -u)"
        if [ -z "$wanted" ]; then
            _fail "VSB-3: ${ENTRY}.html loads no ${flavour}/${ENTRY}.*.js — the shipped shell does not reference this flavour's entry bundle"
            vsb3_bad=1
            continue
        fi
        if [ "$(printf '%s\n' "$wanted" | wc -l)" -ne 1 ]; then
            _fail "VSB-3: ${ENTRY}.html references more than one ${flavour} entry bundle: $(printf '%s' "$wanted" | tr '\n' ' ')"
            vsb3_bad=1
            continue
        fi
        if [ "$(basename "$wanted")" != "${entries[0]}" ]; then
            _fail "VSB-3: ${ENTRY}.html loads ${wanted} but ${flavour}/ holds ${entries[0]} — the shell points at a file that is not shipped"
            vsb3_bad=1
        fi
    done

    if [ "$flavour_count" -eq 0 ]; then
        _fail "VSB-3: no frontend_* flavour directories under ${BUNDLE_DIR} — zero flavours inspected"
        vsb3_bad=1
    elif [ "$vsb3_bad" -eq 0 ]; then
        _note "ok  VSB-3: exactly one ${ENTRY} entry bundle in each of the ${flavour_count} flavour(s), and it is the one ${ENTRY}.html loads"
    fi
fi

# --- summary -------------------------------------------------------------

printf 'vendored site bundle: %d/%d checks ran (%d file(s) inspected, %d of them in the bundle)\n' \
       "$checks_ran" "$CHECKS_TOTAL" "$asset_count" "$bundle_assets"

if [ "$checks_ran" -ne "$CHECKS_TOTAL" ]; then
    printf 'FAIL: only %d of %d declared checks ran — coverage gap\n' "$checks_ran" "$CHECKS_TOTAL"
    exit 1
fi

[ "$failed" -eq 0 ] || exit 1
exit 0
